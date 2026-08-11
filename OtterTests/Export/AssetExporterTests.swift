import Foundation
import Photos
import Testing
@testable import Otter

@Suite("Asset export")
struct AssetExporterTests {
    @Test("Runtime capability controls each explicit rendition")
    func renditionAvailability() {
        let availability = AssetExportAvailability(
            current: .unavailable(.renditionUnsupported),
            original: .unverified
        )
        #expect(!availability.supports(.current))
        #expect(availability.supports(.original))
    }

    @Test("Original bytes and extension are preserved outside media cache")
    func originalPreservesBytes() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let exporter = try fixture.exporter(currentAvailable: true)
        let asset = fixture.asset(filename: "summer photo.HEIC")

        let prepared = try await exporter.prepare(asset: asset, variant: .original)
        #expect(prepared.filename == "summer photo.heic")
        #expect(try Data(contentsOf: prepared.fileURL) == fixture.bytes)
        #expect(prepared.fileURL.path.contains("exports"))
        await exporter.cleanup(prepared)
        #expect(!FileManager.default.fileExists(atPath: prepared.fileURL.path))
    }

    @Test("Current unavailable never falls back to Original")
    func currentDoesNotFallback() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let builder = RecordingExportRequestBuilder()
        let exporter = try AssetExporter(
            requestBuilder: builder,
            transport: fixture.transport,
            exportDirectory: fixture.exports,
            availability: AssetExportAvailability(
                current: .unavailable(.renditionUnsupported),
                original: .available
            )
        )

        await #expect(throws: AssetExportError.currentUnavailable) {
            try await exporter.prepare(asset: fixture.asset(), variant: .current)
        }
        #expect(builder.requestCount == 0)
    }

    @Test("Current uses edited request and creates a distinct filename")
    func currentIdentity() async throws {
        let fixture = try ExportFixture()
        defer { fixture.remove() }
        let builder = RecordingExportRequestBuilder()
        let exporter = try AssetExporter(
            requestBuilder: builder,
            transport: fixture.transport,
            exportDirectory: fixture.exports,
            availability: .available
        )
        let prepared = try await exporter.prepare(asset: fixture.asset(filename: "image.png"), variant: .current)

        #expect(prepared.filename == "image-current.heic")
        #expect(builder.lastVariant == .current)
        #expect(builder.lastRepresentation == .original)
        await exporter.cleanup(prepared)
    }

    @Test("Photos add-only authorization distinguishes denied and restricted")
    func photosPermissionErrors() {
        #expect(PhotosExporter.permissionError(for: .authorized) == nil)
        #expect(PhotosExporter.permissionError(for: .limited) == nil)
        #expect(PhotosExporter.permissionError(for: .denied) == .photosAddPermissionDenied)
        #expect(PhotosExporter.permissionError(for: .restricted) == .photosAddPermissionRestricted)
    }

    @Test("Cancellation after preparation always cleans the temporary export")
    func cancellationCleansPreparedExport() async {
        let exporter = TrackingPreparedExporter()
        let photos = SuspendingPhotosExporter()
        let download = DirectPhotosDownload(
            availability: .available,
            exporter: exporter,
            photosExporter: photos
        )
        let task = Task {
            try await download.save(
                asset: ExportFixture.assetDescriptor(),
                variant: .current
            )
        }
        while await exporter.prepareCount == 0 { await Task.yield() }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await exporter.cleanupCount == 1)
    }
}

private struct ExportFixture {
    let root: URL
    let downloads: URL
    let exports: URL
    let bytes = Data([0x01, 0x02, 0x03, 0x04])

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OtterExportTests-\(UUID().uuidString)", isDirectory: true)
        downloads = root.appendingPathComponent("downloads", isDirectory: true)
        exports = root.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    var transport: FixtureExportTransport {
        FixtureExportTransport(directory: downloads, bytes: bytes)
    }

    func exporter(currentAvailable: Bool) throws -> AssetExporter {
        try AssetExporter(
            requestBuilder: RecordingExportRequestBuilder(),
            transport: transport,
            exportDirectory: exports,
            availability: AssetExportAvailability(
                current: currentAvailable ? .available : .unavailable(.renditionUnsupported),
                original: .available
            )
        )
    }

    func asset(filename: String = "photo.jpg") -> MediaAssetDescriptor {
        Self.assetDescriptor(filename: filename)
    }

    static func assetDescriptor(filename: String = "photo.jpg") -> MediaAssetDescriptor {
        MediaAssetDescriptor(
            accountNamespace: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            revisions: .init(thumbnail: "t", preview: "p", fullsize: "f", original: "o"),
            originalWidth: 100,
            originalHeight: 100,
            originalMimeType: "image/heic",
            originalFilename: filename
        )
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

private actor TrackingPreparedExporter: AssetExporting {
    private(set) var prepareCount = 0
    private(set) var cleanupCount = 0

    func prepare(asset: MediaAssetDescriptor, variant: ExportVariant) -> PreparedExport {
        prepareCount += 1
        return PreparedExport(
            id: UUID(),
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("prepared-photo"),
            filename: "prepared-photo.jpg",
            mimeType: "image/jpeg",
            variant: variant
        )
    }

    func cleanup(_ export: PreparedExport) {
        cleanupCount += 1
    }
}

private struct SuspendingPhotosExporter: PhotosExporting {
    func save(_ export: PreparedExport) async throws {
        try await Task.sleep(for: .seconds(30))
    }
}

private final class RecordingExportRequestBuilder: MediaRequestBuilding, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedRequestCount = 0
    private var recordedVariant: AssetVariant?
    private var recordedRepresentation: RemoteRepresentation?

    var requestCount: Int { lock.withLock { recordedRequestCount } }
    var lastVariant: AssetVariant? { lock.withLock { recordedVariant } }
    var lastRepresentation: RemoteRepresentation? { lock.withLock { recordedRepresentation } }

    func urlRequest(
        for asset: MediaAssetDescriptor,
        variant: AssetVariant,
        representation: RemoteRepresentation
    ) -> URLRequest {
        lock.withLock {
            recordedRequestCount += 1
            recordedVariant = variant
            recordedRepresentation = representation
        }
        return URLRequest(url: URL(string: "https://example.com/export")!)
    }
}

private struct FixtureExportTransport: MediaTransporting {
    let directory: URL
    let bytes: Data

    func download(_ request: URLRequest) async throws -> TransportedMediaFile {
        let url = directory.appendingPathComponent(UUID().uuidString)
        try bytes.write(to: url)
        return TransportedMediaFile(
            fileURL: url,
            mimeType: "image/heic",
            byteCount: Int64(bytes.count),
            statusCode: 200
        )
    }
}
