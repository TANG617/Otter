import Foundation
import Testing
@testable import Otter

@Suite("Asset export")
struct AssetExporterTests {
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
            currentExportAvailable: false
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
            currentExportAvailable: true
        )
        let prepared = try await exporter.prepare(asset: fixture.asset(filename: "image.png"), variant: .current)

        #expect(prepared.filename == "image-current.heic")
        #expect(builder.lastVariant == .current)
        #expect(builder.lastRepresentation == .original)
        await exporter.cleanup(prepared)
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
            currentExportAvailable: currentAvailable
        )
    }

    func asset(filename: String = "photo.jpg") -> MediaAssetDescriptor {
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
