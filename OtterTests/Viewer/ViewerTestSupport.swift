import CoreGraphics
import Foundation
@testable import Otter

final class ViewerTestPipeline: MediaPipelineProtocol, @unchecked Sendable {
    private struct StreamRecord {
        let request: MediaRequest
        let continuation: AsyncThrowingStream<MediaFrame, Error>.Continuation
    }

    private let lock = NSLock()
    private var nextID = 0
    private var streams: [Int: StreamRecord] = [:]
    private var requested: [MediaRequest] = []
    private var terminationCount = 0

    func peek(_ request: MediaRequest) -> MediaFrame? { nil }

    func frames(for request: MediaRequest) -> AsyncThrowingStream<MediaFrame, Error> {
        AsyncThrowingStream { continuation in
            let id = lock.withLock { () -> Int in
                defer { nextID += 1 }
                requested.append(request)
                streams[nextID] = StreamRecord(request: request, continuation: continuation)
                return nextID
            }
            continuation.onTermination = { @Sendable [weak self] _ in
                self?.terminate(id: id)
            }
        }
    }

    func prefetch(_ requests: [MediaRequest]) -> PrefetchToken {
        PrefetchToken(task: Task {})
    }

    func invalidate(accountNamespace: UUID, assetID: UUID) async {}
    func clearMemory() async {}
    func clearDisk(accountNamespace: UUID) async throws {}
    func clearAllDisk() async throws {}

    func allRequests() -> [MediaRequest] {
        lock.withLock { requested }
    }

    func activeRequests() -> [MediaRequest] {
        lock.withLock { streams.values.map(\.request) }
    }

    func cancellations() -> Int {
        lock.withLock { terminationCount }
    }

    func yield(_ frame: MediaFrame, assetID: UUID, variant: AssetVariant) {
        let continuations = lock.withLock {
            streams.values.compactMap { record in
                record.request.asset.id == assetID && record.request.variant == variant
                    ? record.continuation
                    : nil
            }
        }
        continuations.forEach { $0.yield(frame) }
    }

    private func terminate(id: Int) {
        lock.withLock {
            if streams.removeValue(forKey: id) != nil {
                terminationCount += 1
            }
        }
    }
}

func viewerTestItems(count: Int) -> [ViewerItem] {
    let account = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    return (0..<count).map { index in
        let suffix = String(format: "%012d", index + 1)
        let id = UUID(uuidString: "10000000-0000-0000-0000-\(suffix)")!
        return ViewerItem(
            descriptor: MediaAssetDescriptor(
                accountNamespace: account,
                id: id,
                hasEdits: true,
                revisions: MediaContentRevisions(
                    thumbnail: "thumb-\(index)",
                    preview: "preview-\(index)",
                    fullsize: "full-\(index)",
                    original: "original-\(index)"
                ),
                originalWidth: 4_000,
                originalHeight: 3_000,
                originalMimeType: "image/jpeg"
            ),
            accessibilityLabel: "Photo \(index + 1)",
            rating: index == 0 ? .four : nil
        )
    }
}

func viewerTestFrame(
    quality: MediaQuality,
    width: Int = 16,
    height: Int = 12,
    isFinal: Bool = false
) -> MediaFrame {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return MediaFrame(
        surface: RenderSurface(cgImage: context.makeImage()!),
        quality: quality,
        source: .network,
        isFinalForCurrentDemand: isFinal
    )
}

@MainActor
func settleViewerTasks(iterations: Int = 8) async {
    for _ in 0..<iterations {
        await Task.yield()
    }
}
