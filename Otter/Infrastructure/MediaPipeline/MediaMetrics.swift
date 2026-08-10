import Foundation
import OSLog

enum MediaMetricEvent: String, Sendable {
    case requestCreated = "request_created"
    case memoryLookup = "memory_lookup"
    case diskLookup = "disk_lookup"
    case queueWait = "queue_wait"
    case networkStart = "network_start"
    case networkEnd = "network_end"
    case diskCommit = "disk_commit"
    case decodeStart = "decode_start"
    case decodeEnd = "decode_end"
    case firstFrameDelivered = "first_frame_delivered"
    case finalFrameDelivered = "final_frame_delivered"
    case priorityPromoted = "priority_promoted"
    case requestCancelled = "request_cancelled"
    case eviction = "eviction"
}

struct MediaPipelineStats: Equatable, Sendable {
    let memoryHits: Int
    let diskHits: Int
    let networkFetches: Int
    let framesDelivered: Int
    let cancellations: Int
}

actor MediaMetrics {
    private let logger = Logger(subsystem: "com.tang617.otter", category: "MediaPipeline")
    private let signposter = OSSignposter(subsystem: "com.tang617.otter", category: "MediaPipeline")
    private var memoryHits = 0
    private var diskHits = 0
    private var networkFetches = 0
    private var framesDelivered = 0
    private var cancellations = 0

    func emit(
        _ event: MediaMetricEvent,
        key: ByteCacheKey? = nil,
        priority: MediaPriority? = nil,
        byteCount: Int64? = nil
    ) {
        let safeID = key.map { String($0.digest.prefix(12)) } ?? "none"
        let representation = key?.representation.rawValue ?? "none"
        let priorityValue = priority?.rawValue ?? 0
        let bytes = byteCount ?? 0
        logger.debug(
            "\(event.rawValue, privacy: .public) id=\(safeID, privacy: .public) representation=\(representation, privacy: .public) priority=\(priorityValue, privacy: .public) bytes=\(bytes, privacy: .public)"
        )
        emitSignpost(event, safeID: safeID, representation: representation, priority: priorityValue)
        switch event {
        case .memoryLookup: memoryHits += 1
        case .diskLookup: diskHits += 1
        case .networkStart: networkFetches += 1
        case .firstFrameDelivered, .finalFrameDelivered: framesDelivered += 1
        case .requestCancelled: cancellations += 1
        default: break
        }
    }

    func stats() -> MediaPipelineStats {
        .init(
            memoryHits: memoryHits,
            diskHits: diskHits,
            networkFetches: networkFetches,
            framesDelivered: framesDelivered,
            cancellations: cancellations
        )
    }

    private func emitSignpost(
        _ event: MediaMetricEvent,
        safeID: String,
        representation: String,
        priority: Int
    ) {
        switch event {
        case .requestCreated:
            signposter.emitEvent("request_created", "id=\(safeID, privacy: .public) representation=\(representation, privacy: .public) priority=\(priority, privacy: .public)")
        case .memoryLookup: signposter.emitEvent("memory_lookup")
        case .diskLookup: signposter.emitEvent("disk_lookup")
        case .queueWait: signposter.emitEvent("queue_wait")
        case .networkStart: signposter.emitEvent("network_start")
        case .networkEnd: signposter.emitEvent("network_end")
        case .diskCommit: signposter.emitEvent("disk_commit")
        case .decodeStart: signposter.emitEvent("decode_start")
        case .decodeEnd: signposter.emitEvent("decode_end")
        case .firstFrameDelivered: signposter.emitEvent("first_frame_delivered")
        case .finalFrameDelivered: signposter.emitEvent("final_frame_delivered")
        case .priorityPromoted: signposter.emitEvent("priority_promoted")
        case .requestCancelled: signposter.emitEvent("request_cancelled")
        case .eviction: signposter.emitEvent("eviction")
        }
    }
}
