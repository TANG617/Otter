import Foundation
import Testing
@testable import Otter

private struct FallbackRequestBuilder: MediaRequestBuilding {
    func urlRequest(
        for asset: MediaAssetDescriptor,
        variant: AssetVariant,
        representation: RemoteRepresentation
    ) throws -> URLRequest {
        URLRequest(url: URL(string: "https://fixture.invalid/\(representation.rawValue)")!)
    }
}

private actor FallbackTransport: MediaTransporting {
    private let jpeg: URL
    private let directory: URL
    private var requestedRepresentations: [String] = []

    init(jpeg: URL, directory: URL) {
        self.jpeg = jpeg
        self.directory = directory
    }

    func download(_ request: URLRequest) throws -> TransportedMediaFile {
        let representation = request.url?.lastPathComponent ?? ""
        requestedRepresentations.append(representation)
        if representation == RemoteRepresentation.thumbnail.rawValue {
            throw MediaError.httpStatus(404, retryAfter: nil)
        }
        let destination = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        try FileManager.default.copyItem(at: jpeg, to: destination)
        return TransportedMediaFile(
            fileURL: destination,
            mimeType: "image/jpeg",
            byteCount: 1,
            statusCode: 200
        )
    }

    func requests() -> [String] { requestedRepresentations }
}

@Suite("Media representation fallback")
struct MediaPipelineFallbackTests {
    @Test("A missing thumbnail falls through to preview")
    func thumbnail404FallsBackToPreview() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let jpeg = root.appendingPathComponent("source.jpg")
        try makeTestJPEG(width: 320, height: 240, at: jpeg)
        let transport = FallbackTransport(jpeg: jpeg, directory: root)
        let scheduler = WorkScheduler()
        let pipeline = MediaPipeline(
            profileStore: InMemoryServerMediaProfileStore(),
            memoryCache: RenderMemoryCache(),
            diskCache: try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache")),
            coordinator: RequestCoordinator(scheduler: scheduler),
            scheduler: scheduler,
            requestBuilder: FallbackRequestBuilder(),
            transport: transport
        )
        let descriptor = MediaAssetDescriptor(
            accountNamespace: UUID(),
            id: UUID(),
            hasEdits: false,
            revisions: MediaContentRevisions(
                thumbnail: "thumb",
                preview: "preview",
                fullsize: "full",
                original: "original"
            ),
            originalWidth: 320,
            originalHeight: 240,
            originalMimeType: "image/jpeg"
        )
        let request = MediaRequest(
            asset: descriptor,
            purpose: .timeline,
            viewport: PixelSize(width: 300, height: 300),
            displayScale: 2,
            priority: .visible
        )

        var frames: [MediaFrame] = []
        for try await frame in pipeline.frames(for: request) {
            frames.append(frame)
        }

        #expect(await transport.requests() == ["thumbnail", "preview"])
        #expect(frames.last?.quality == .preview)
        #expect(frames.last?.isFinalForCurrentDemand == true)
    }
}
