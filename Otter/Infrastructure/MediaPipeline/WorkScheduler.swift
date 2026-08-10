import Foundation

enum WorkLane: String, CaseIterable, Hashable, Sendable {
    case metadata
    case thumbnail
    case preview
    case fullsize
    case export
    case diskIO
    case decode
    case thumbHash
}

struct WorkSchedulerStats: Equatable, Sendable {
    let activeByLane: [WorkLane: Int]
    let queuedByLane: [WorkLane: Int]
}

actor WorkScheduler {
    struct Limits: Sendable {
        var values: [WorkLane: Int]

        static let conservative = Limits(values: [
            .metadata: 4,
            .thumbnail: 4,
            .preview: 2,
            .fullsize: 1,
            .export: 1,
            .diskIO: 2,
            .decode: 1,
            .thumbHash: 1,
        ])

        func limit(for lane: WorkLane) -> Int { max(values[lane, default: 1], 1) }
    }

    private struct Waiter {
        let id: UUID
        let priority: MediaPriority
        let order: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limits: Limits
    private var active: [WorkLane: Int] = [:]
    private var queued: [WorkLane: [Waiter]] = [:]
    private var nextOrder: UInt64 = 0

    init(limits: Limits = .conservative) {
        self.limits = limits
    }

    func run<Value: Sendable>(
        id: UUID = UUID(),
        lane: WorkLane,
        priority: MediaPriority,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire(id: id, lane: lane, priority: priority)
        defer { release(lane: lane) }
        try Task.checkCancellation()
        return try await operation()
    }

    func promote(id: UUID, to priority: MediaPriority) {
        for lane in WorkLane.allCases {
            guard let index = queued[lane]?.firstIndex(where: { $0.id == id }),
                  let old = queued[lane]?[index], old.priority < priority else { continue }
            queued[lane]?[index] = Waiter(
                id: old.id,
                priority: priority,
                order: old.order,
                continuation: old.continuation
            )
            sortQueue(lane)
            return
        }
    }

    func cancelQueued(id: UUID) {
        for lane in WorkLane.allCases {
            guard let index = queued[lane]?.firstIndex(where: { $0.id == id }) else { continue }
            let waiter = queued[lane]!.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
    }

    func cancelQueuedPrefetch() {
        for lane in WorkLane.allCases {
            let cancelled = queued[lane, default: []].filter { $0.priority <= .prefetch }
            queued[lane]?.removeAll { $0.priority <= .prefetch }
            cancelled.forEach { $0.continuation.resume(throwing: CancellationError()) }
        }
    }

    func stats() -> WorkSchedulerStats {
        .init(
            activeByLane: active,
            queuedByLane: queued.mapValues(\.count)
        )
    }

    private func acquire(id: UUID, lane: WorkLane, priority: MediaPriority) async throws {
        if active[lane, default: 0] < limits.limit(for: lane), queued[lane, default: []].isEmpty {
            active[lane, default: 0] += 1
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                nextOrder &+= 1
                queued[lane, default: []].append(
                    Waiter(id: id, priority: priority, order: nextOrder, continuation: continuation)
                )
                sortQueue(lane)
            }
        } onCancel: {
            Task { await self.cancelQueued(id: id) }
        }
    }

    private func release(lane: WorkLane) {
        active[lane, default: 0] = max(active[lane, default: 0] - 1, 0)
        guard active[lane, default: 0] < limits.limit(for: lane),
              !queued[lane, default: []].isEmpty else { return }
        let waiter = queued[lane]!.removeFirst()
        active[lane, default: 0] += 1
        waiter.continuation.resume()
    }

    private func sortQueue(_ lane: WorkLane) {
        queued[lane]?.sort {
            if $0.priority == $1.priority { return $0.order < $1.order }
            return $0.priority > $1.priority
        }
    }
}
