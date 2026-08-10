import Foundation

struct TimelineDataClient: Sendable {
    var localPage: @Sendable (TimelinePageRequest) async throws -> TimelineAssetPage
    var refresh: @Sendable (UUID, AssetRefreshMode) async throws -> AssetRefreshResult

    init(
        localPage: @escaping @Sendable (TimelinePageRequest) async throws -> TimelineAssetPage,
        refresh: @escaping @Sendable (UUID, AssetRefreshMode) async throws -> AssetRefreshResult
    ) {
        self.localPage = localPage
        self.refresh = refresh
    }

    init(store: any AssetStore) {
        localPage = { request in
            try await store.localPage(request)
        }
        refresh = { accountNamespace, mode in
            try await store.refresh(accountNamespace: accountNamespace, mode: mode)
        }
    }
}

final class TimelinePrefetchCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellation: (@Sendable () -> Void)?

    init(_ cancellation: @escaping @Sendable () -> Void) {
        self.cancellation = cancellation
    }

    func cancel() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { cancellation = nil }
            return cancellation
        }
        action?()
    }

    deinit {
        cancel()
    }
}

struct TimelineMediaClient: Sendable {
    var peek: @Sendable (MediaRequest) -> MediaFrame?
    var frames: @Sendable (MediaRequest) -> AsyncThrowingStream<MediaFrame, Error>
    var prefetch: @Sendable ([MediaRequest]) -> TimelinePrefetchCancellation

    init(
        peek: @escaping @Sendable (MediaRequest) -> MediaFrame?,
        frames: @escaping @Sendable (MediaRequest) -> AsyncThrowingStream<MediaFrame, Error>,
        prefetch: @escaping @Sendable ([MediaRequest]) -> TimelinePrefetchCancellation
    ) {
        self.peek = peek
        self.frames = frames
        self.prefetch = prefetch
    }

    init(pipeline: any MediaPipelineProtocol) {
        peek = { request in pipeline.peek(request) }
        frames = { request in pipeline.frames(for: request) }
        prefetch = { requests in
            let token = pipeline.prefetch(requests)
            return TimelinePrefetchCancellation { token.cancel() }
        }
    }
}

enum TimelineMediaDemand {
    static func descriptor(for asset: TimelineAsset) -> MediaAssetDescriptor {
        // Rating and generic metadata timestamps are deliberately excluded from all revisions.
        let originalRevision = asset.checksum ?? asset.id.uuidString.lowercased()
        let derivativeRevision = asset.thumbhash ?? originalRevision
        let currentRevision = asset.isEdited ? "edited:\(derivativeRevision)" : derivativeRevision
        return MediaAssetDescriptor(
            accountNamespace: asset.accountNamespace,
            id: asset.id,
            thumbhash: asset.thumbhash,
            hasEdits: asset.isEdited,
            revisions: MediaContentRevisions(
                thumbnail: currentRevision,
                preview: currentRevision,
                fullsize: currentRevision,
                original: originalRevision
            ),
            originalWidth: asset.width,
            originalHeight: asset.height,
            originalMimeType: asset.originalMimeType
        )
    }

    static func request(
        for asset: TimelineAsset,
        cellSide: Double,
        displayScale: Double,
        priority: MediaPriority
    ) -> MediaRequest {
        MediaRequest(
            asset: descriptor(for: asset),
            variant: .current,
            purpose: .timeline,
            viewport: PixelSize(width: max(cellSide, 1), height: max(cellSide, 1)),
            displayScale: max(displayScale, 1),
            qualityPolicy: .fast,
            dynamicRange: .standard,
            contentMode: .aspectFill,
            priority: priority
        )
    }
}
