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

private struct ProfileRequestBuilder: MediaRequestBuilding {
    func urlRequest(
        for asset: MediaAssetDescriptor,
        variant: AssetVariant,
        representation: RemoteRepresentation
    ) throws -> URLRequest {
        let base = URL(string: "https://fixture.invalid/api/assets/\(asset.id.uuidString.lowercased())")!
        if representation == .original {
            return URLRequest(url: base.appendingPathComponent("original"))
        }
        var components = URLComponents(
            url: base.appendingPathComponent("thumbnail"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "size", value: representation.rawValue),
            URLQueryItem(name: "edited", value: variant == .current ? "true" : "false"),
        ]
        return URLRequest(url: components.url!)
    }
}

private enum ScriptedMediaOutcome: Sendable {
    case success(URL)
    case httpStatus(Int)
    case offline
    case redirectedOriginalSuccess(URL)
    case redirectedOriginalHTTPStatus(Int)
}

private actor ScriptedMediaTransport: MediaTransporting {
    private var outcomes: [RemoteRepresentation: [ScriptedMediaOutcome]]
    private var requestedRepresentations: [RemoteRepresentation] = []
    private let directory: URL

    init(
        directory: URL,
        outcomes: [RemoteRepresentation: [ScriptedMediaOutcome]]
    ) {
        self.directory = directory
        self.outcomes = outcomes
    }

    func download(_ request: URLRequest) throws -> TransportedMediaFile {
        let representation = try representation(from: request)
        requestedRepresentations.append(representation)
        guard var available = outcomes[representation], !available.isEmpty else {
            throw MediaError.httpStatus(404, retryAfter: nil)
        }
        let outcome = available.removeFirst()
        outcomes[representation] = available
        switch outcome {
        case let .success(source):
            return try copiedFile(from: source, request: request, responseMetadata: nil)
        case let .httpStatus(statusCode):
            throw MediaError.httpStatus(statusCode, retryAfter: nil)
        case .offline:
            throw URLError(.notConnectedToInternet)
        case let .redirectedOriginalSuccess(source):
            return try copiedFile(
                from: source,
                request: request,
                responseMetadata: redirectedOriginalMetadata(for: request)
            )
        case let .redirectedOriginalHTTPStatus(statusCode):
            throw MediaTransportHTTPError(
                statusCode: statusCode,
                retryAfter: nil,
                responseMetadata: try redirectedOriginalMetadata(for: request)
            )
        }
    }

    func requests() -> [RemoteRepresentation] { requestedRepresentations }

    private func representation(from request: URLRequest) throws -> RemoteRepresentation {
        guard let url = request.url else { throw MediaError.invalidHTTPResponse }
        if url.lastPathComponent == "original" { return .original }
        let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == "size" })?
            .value
        guard let value, let representation = RemoteRepresentation(rawValue: value) else {
            throw MediaError.invalidHTTPResponse
        }
        return representation
    }

    private func copiedFile(
        from source: URL,
        request: URLRequest,
        responseMetadata: MediaResponseMetadata?
    ) throws -> TransportedMediaFile {
        let destination = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        try FileManager.default.copyItem(at: source, to: destination)
        let size = try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
            .flatMap { ($0 as? NSNumber)?.int64Value }
        return TransportedMediaFile(
            fileURL: destination,
            mimeType: "image/jpeg",
            byteCount: size,
            statusCode: 200,
            responseMetadata: responseMetadata ?? request.url.map {
                MediaResponseMetadata(initialURL: $0, finalURL: $0, redirects: [])
            }
        )
    }

    private func redirectedOriginalMetadata(for request: URLRequest) throws -> MediaResponseMetadata {
        guard let initialURL = request.url,
              var components = URLComponents(url: initialURL, resolvingAgainstBaseURL: false) else {
            throw MediaError.invalidHTTPResponse
        }
        components.path = (components.path as NSString).deletingLastPathComponent + "/original"
        components.queryItems = [URLQueryItem(name: "edited", value: "true")]
        guard let originalURL = components.url else { throw MediaError.invalidHTTPResponse }
        return MediaResponseMetadata(
            initialURL: initialURL,
            finalURL: originalURL,
            redirects: [
                MediaRedirectHop(
                    sourceURL: initialURL,
                    destinationURL: originalURL,
                    statusCode: 302,
                    disposition: .followed
                ),
            ]
        )
    }
}

private func fallbackDescriptor(
    account: UUID = UUID(),
    id: UUID = UUID(),
    thumbhash: String? = nil
) -> MediaAssetDescriptor {
    MediaAssetDescriptor(
        accountNamespace: account,
        id: id,
        thumbhash: thumbhash,
        hasEdits: false,
        revisions: MediaContentRevisions(
            thumbnail: "thumb-\(id)",
            preview: "preview-\(id)",
            fullsize: "full-\(id)",
            original: "original-\(id)"
        ),
        originalWidth: 4_000,
        originalHeight: 3_000,
        originalMimeType: "image/jpeg"
    )
}

private func viewerRequest(for descriptor: MediaAssetDescriptor) -> MediaRequest {
    MediaRequest(
        asset: descriptor,
        purpose: .viewer,
        viewport: PixelSize(width: 390, height: 844),
        displayScale: 3,
        priority: .interactive
    )
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

    @Test("ThumbHash does not hide failure when every real representation is missing")
    func placeholderAllRepresentationsMissing() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ScriptedMediaTransport(
            directory: root,
            outcomes: [
                .preview: [.httpStatus(404)],
                .fullsize: [.httpStatus(404)],
            ]
        )
        let scheduler = WorkScheduler()
        let pipeline = MediaPipeline(
            profileStore: InMemoryServerMediaProfileStore(),
            memoryCache: RenderMemoryCache(),
            diskCache: try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache")),
            coordinator: RequestCoordinator(scheduler: scheduler),
            scheduler: scheduler,
            requestBuilder: ProfileRequestBuilder(),
            transport: transport
        )
        let descriptor = fallbackDescriptor(
            thumbhash: Data(repeating: 0, count: 40).base64EncodedString()
        )

        var frames: [MediaFrame] = []
        var caught: MediaError?
        do {
            for try await frame in pipeline.frames(for: viewerRequest(for: descriptor)) {
                frames.append(frame)
            }
        } catch let error as MediaError {
            caught = error
        }

        #expect(frames.count == 1)
        #expect(frames.first?.quality == .placeholder)
        #expect(frames.first?.containsRealMedia == false)
        #expect(frames.first?.isFinalForCurrentDemand == false)
        #expect(caught == .httpStatus(404, retryAfter: nil))
        #expect(await transport.requests() == [.preview, .fullsize])
    }

    @Test("ThumbHash remains non-final when real media is offline")
    func placeholderOfflineFailure() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = ScriptedMediaTransport(
            directory: root,
            outcomes: [.preview: [.offline]]
        )
        let scheduler = WorkScheduler()
        let pipeline = MediaPipeline(
            profileStore: InMemoryServerMediaProfileStore(),
            memoryCache: RenderMemoryCache(),
            diskCache: try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache")),
            coordinator: RequestCoordinator(scheduler: scheduler),
            scheduler: scheduler,
            requestBuilder: ProfileRequestBuilder(),
            transport: transport
        )
        let descriptor = fallbackDescriptor(
            thumbhash: Data(repeating: 0, count: 40).base64EncodedString()
        )

        var frames: [MediaFrame] = []
        var offlineCode: URLError.Code?
        do {
            for try await frame in pipeline.frames(for: viewerRequest(for: descriptor)) {
                frames.append(frame)
            }
        } catch let error as URLError {
            offlineCode = error.code
        }

        #expect(frames.map(\.quality) == [.placeholder])
        #expect(frames.first?.isFinalForCurrentDemand == false)
        #expect(offlineCode == .notConnectedToInternet)
        #expect(await transport.requests() == [.preview])
    }

    @Test("A failed optional fullsize upgrade preserves successful preview")
    func previewSurvivesFullsizeFailure() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = root.appendingPathComponent("preview.jpg")
        try makeTestJPEG(width: 320, height: 240, at: preview)
        let transport = ScriptedMediaTransport(
            directory: root,
            outcomes: [
                .preview: [.success(preview)],
                .fullsize: [.offline],
            ]
        )
        let scheduler = WorkScheduler()
        let pipeline = MediaPipeline(
            profileStore: InMemoryServerMediaProfileStore(),
            memoryCache: RenderMemoryCache(),
            diskCache: try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache")),
            coordinator: RequestCoordinator(scheduler: scheduler),
            scheduler: scheduler,
            requestBuilder: ProfileRequestBuilder(),
            transport: transport
        )

        var frames: [MediaFrame] = []
        for try await frame in pipeline.frames(for: viewerRequest(for: fallbackDescriptor())) {
            frames.append(frame)
        }

        #expect(frames.last?.quality == .preview)
        #expect(frames.last?.containsRealMedia == true)
        #expect(frames.last?.isFinalForCurrentDemand == true)
        #expect(await transport.requests() == [.preview, .fullsize])
    }

    @Test("Explicit retry clears derivative negative cache and performs real requests")
    func explicitRetryRefetchesAfterPlaceholderFailure() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = root.appendingPathComponent("retry-preview.jpg")
        try makeTestJPEG(width: 320, height: 240, at: preview)
        let transport = ScriptedMediaTransport(
            directory: root,
            outcomes: [
                .preview: [.httpStatus(404), .success(preview)],
                .fullsize: [.httpStatus(404), .httpStatus(404)],
            ]
        )
        let scheduler = WorkScheduler()
        let pipeline = MediaPipeline(
            profileStore: InMemoryServerMediaProfileStore(),
            memoryCache: RenderMemoryCache(),
            diskCache: try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache")),
            coordinator: RequestCoordinator(scheduler: scheduler),
            scheduler: scheduler,
            requestBuilder: ProfileRequestBuilder(),
            transport: transport
        )
        let request = viewerRequest(for: fallbackDescriptor(
            thumbhash: Data(repeating: 0, count: 40).base64EncodedString()
        ))

        do {
            for try await _ in pipeline.frames(for: request) { }
            Issue.record("The first request should fail after placeholder delivery")
        } catch { }

        var retriedFrames: [MediaFrame] = []
        for try await frame in pipeline.retryFrames(for: request) {
            retriedFrames.append(frame)
        }

        #expect(retriedFrames.contains(where: { $0.quality == .preview }))
        #expect(retriedFrames.last?.quality == .preview)
        #expect(retriedFrames.last?.isFinalForCurrentDemand == true)
        #expect(await transport.requests() == [.preview, .fullsize, .preview, .fullsize])
    }

    @Test("Generated fullsize is observed and cached under its nominal identity")
    func generatedFullsizeCachesNormally() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = root.appendingPathComponent("generated-preview.jpg")
        let fullsize = root.appendingPathComponent("generated-fullsize.jpg")
        try makeTestJPEG(width: 320, height: 240, at: preview)
        try makeTestJPEG(width: 1_600, height: 1_200, at: fullsize)
        let transport = ScriptedMediaTransport(
            directory: root,
            outcomes: [
                .preview: [.success(preview)],
                .fullsize: [.success(fullsize)],
            ]
        )
        let profileStore = InMemoryServerMediaProfileStore()
        let diskCache = try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache"))
        let scheduler = WorkScheduler()
        let pipeline = MediaPipeline(
            profileStore: profileStore,
            memoryCache: RenderMemoryCache(),
            diskCache: diskCache,
            coordinator: RequestCoordinator(scheduler: scheduler),
            scheduler: scheduler,
            requestBuilder: ProfileRequestBuilder(),
            transport: transport
        )
        let descriptor = fallbackDescriptor()

        var frames: [MediaFrame] = []
        for try await frame in pipeline.frames(for: viewerRequest(for: descriptor)) {
            frames.append(frame)
        }
        let fullsizeKey = try ByteCacheKey(
            asset: descriptor,
            variant: .current,
            representation: .fullsize
        )

        #expect(frames.last?.quality == .fullsize)
        #expect(try await diskCache.file(for: fullsizeKey) != nil)
        #expect(await profileStore.profile(accountNamespace: descriptor.accountNamespace).fullsizeSupport == .supported)
    }

    @Test("Fullsize redirected to Original is discarded and disables future probes")
    func redirectedOriginalIsNotCachedAndLearnsUnsupported() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = root.appendingPathComponent("redirect-preview.jpg")
        let original = root.appendingPathComponent("redirect-original.jpg")
        try makeTestJPEG(width: 320, height: 240, at: preview)
        try makeTestJPEG(width: 1_600, height: 1_200, at: original)
        let transport = ScriptedMediaTransport(
            directory: root,
            outcomes: [
                .preview: [.success(preview), .success(preview)],
                .fullsize: [.redirectedOriginalSuccess(original)],
            ]
        )
        let profileStore = InMemoryServerMediaProfileStore()
        let diskCache = try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache"))
        let scheduler = WorkScheduler()
        let pipeline = MediaPipeline(
            profileStore: profileStore,
            memoryCache: RenderMemoryCache(),
            diskCache: diskCache,
            coordinator: RequestCoordinator(scheduler: scheduler),
            scheduler: scheduler,
            requestBuilder: ProfileRequestBuilder(),
            transport: transport
        )
        let account = UUID()
        let first = fallbackDescriptor(account: account)
        let second = fallbackDescriptor(account: account)

        var firstFrames: [MediaFrame] = []
        for try await frame in pipeline.frames(for: viewerRequest(for: first)) {
            firstFrames.append(frame)
        }
        let firstFullsizeKey = try ByteCacheKey(
            asset: first,
            variant: .current,
            representation: .fullsize
        )

        #expect(firstFrames.last?.quality == .preview)
        #expect(try await diskCache.file(for: firstFullsizeKey) == nil)
        #expect(await profileStore.profile(accountNamespace: account).fullsizeSupport == .unsupported)

        for try await _ in pipeline.frames(for: viewerRequest(for: second)) { }
        #expect(await transport.requests() == [.preview, .fullsize, .preview])
    }

    @Test("View-only redirect permission failure preserves preview")
    func redirectedOriginal403PreservesPreview() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let preview = root.appendingPathComponent("view-only-preview.jpg")
        try makeTestJPEG(width: 320, height: 240, at: preview)
        let transport = ScriptedMediaTransport(
            directory: root,
            outcomes: [
                .preview: [.success(preview)],
                .fullsize: [.redirectedOriginalHTTPStatus(403)],
            ]
        )
        let profileStore = InMemoryServerMediaProfileStore()
        let scheduler = WorkScheduler()
        let pipeline = MediaPipeline(
            profileStore: profileStore,
            memoryCache: RenderMemoryCache(),
            diskCache: try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache")),
            coordinator: RequestCoordinator(scheduler: scheduler),
            scheduler: scheduler,
            requestBuilder: ProfileRequestBuilder(),
            transport: transport
        )
        let descriptor = fallbackDescriptor()

        var frames: [MediaFrame] = []
        for try await frame in pipeline.frames(for: viewerRequest(for: descriptor)) {
            frames.append(frame)
        }

        #expect(frames.last?.quality == .preview)
        #expect(frames.last?.isFinalForCurrentDemand == true)
        #expect(await profileStore.profile(accountNamespace: descriptor.accountNamespace).fullsizeSupport == .unsupported)
    }
}
