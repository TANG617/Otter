import Foundation

enum TimelineScrollDirection: Equatable, Sendable {
    case forward
    case backward
}

struct TimelinePrefetchPlan: Equatable, Sendable {
    let indices: [Int]
    let direction: TimelineScrollDirection
    let isFastScroll: Bool
}

enum TimelinePrefetchPlanner {
    static let maximumRequestCount = 40

    static func plan(
        anchorIndex: Int,
        previousAnchorIndex: Int?,
        elapsed: TimeInterval,
        assetCount: Int
    ) -> TimelinePrefetchPlan {
        guard assetCount > 1 else {
            return TimelinePrefetchPlan(indices: [], direction: .forward, isFastScroll: false)
        }

        let previous = previousAnchorIndex ?? anchorIndex
        let delta = anchorIndex - previous
        let direction: TimelineScrollDirection = delta < 0 ? .backward : .forward
        let safeElapsed = max(elapsed, 1.0 / 120.0)
        let isFast = previousAnchorIndex != nil && Double(abs(delta)) / safeElapsed >= 20
        let primaryCount = isFast ? 32 : 12
        let secondaryCount = isFast ? 4 : 4

        let primary: [Int]
        let secondary: [Int]
        switch direction {
        case .forward:
            primary = ascending(from: anchorIndex + 1, count: primaryCount, assetCount: assetCount)
            secondary = descending(from: anchorIndex - 1, count: secondaryCount, assetCount: assetCount)
        case .backward:
            primary = descending(from: anchorIndex - 1, count: primaryCount, assetCount: assetCount)
            secondary = ascending(from: anchorIndex + 1, count: secondaryCount, assetCount: assetCount)
        }

        return TimelinePrefetchPlan(
            indices: Array((primary + secondary).prefix(maximumRequestCount)),
            direction: direction,
            isFastScroll: isFast
        )
    }

    private static func ascending(from start: Int, count: Int, assetCount: Int) -> [Int] {
        guard start < assetCount, count > 0 else { return [] }
        return Array(max(start, 0)..<min(start + count, assetCount))
    }

    private static func descending(from start: Int, count: Int, assetCount: Int) -> [Int] {
        guard start >= 0, count > 0, assetCount > 0 else { return [] }
        let lower = max(start - count + 1, 0)
        return Array((lower...min(start, assetCount - 1)).reversed())
    }
}

@MainActor
final class TimelinePrefetchController {
    private let mediaClient: TimelineMediaClient
    private var cancellation: TimelinePrefetchCancellation?
    private var lastAnchorIndex: Int?
    private var lastUpdateTime: TimeInterval?

    init(mediaClient: TimelineMediaClient) {
        self.mediaClient = mediaClient
    }

    @discardableResult
    func update(
        assets: [TimelineAsset],
        anchorIndex: Int,
        timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime,
        cellSide: Double,
        displayScale: Double
    ) -> TimelinePrefetchPlan {
        guard assets.indices.contains(anchorIndex) else {
            return TimelinePrefetchPlan(indices: [], direction: .forward, isFastScroll: false)
        }
        if let lastAnchorIndex, abs(anchorIndex - lastAnchorIndex) < 3 {
            return TimelinePrefetchPlan(indices: [], direction: .forward, isFastScroll: false)
        }

        let elapsed = lastUpdateTime.map { max(timestamp - $0, 0) } ?? 1
        let plan = TimelinePrefetchPlanner.plan(
            anchorIndex: anchorIndex,
            previousAnchorIndex: lastAnchorIndex,
            elapsed: elapsed,
            assetCount: assets.count
        )
        lastAnchorIndex = anchorIndex
        lastUpdateTime = timestamp

        cancellation?.cancel()
        cancellation = nil
        guard !plan.indices.isEmpty else { return plan }

        let requests = plan.indices.map { index in
            TimelineMediaDemand.request(
                for: assets[index],
                cellSide: cellSide,
                displayScale: displayScale,
                priority: .prefetch
            )
        }
        cancellation = mediaClient.prefetch(requests)
        return plan
    }

    func cancel() {
        cancellation?.cancel()
        cancellation = nil
        lastAnchorIndex = nil
        lastUpdateTime = nil
    }

    deinit {
        cancellation?.cancel()
    }
}
