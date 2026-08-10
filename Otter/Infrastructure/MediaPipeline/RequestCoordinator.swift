import Foundation

final class ConsumerLease<Value: Sendable>: @unchecked Sendable {
    let id: UUID
    private let task: Task<Value, Error>
    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?
    private let promotionAction: @Sendable (MediaPriority) -> Void

    init(
        id: UUID,
        task: Task<Value, Error>,
        release: @escaping @Sendable () -> Void,
        promote: @escaping @Sendable (MediaPriority) -> Void
    ) {
        self.id = id
        self.task = task
        releaseAction = release
        promotionAction = promote
    }

    func value() async throws -> Value {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            self.release()
        }
    }

    func promote(to priority: MediaPriority) { promotionAction(priority) }

    func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { releaseAction = nil }
            return releaseAction
        }
        action?()
    }

    deinit { release() }
}

actor RequestCoordinator {
    private struct Shared<Value: Sendable> {
        let workID: UUID
        let task: Task<Value, Error>
        var consumers: Set<UUID>
        var priority: MediaPriority
    }

    private var byteRequests: [ByteCacheKey: Shared<CachedByteFile>] = [:]
    private var renderRequests: [RenderCacheKey: Shared<RenderSurface>] = [:]
    private let scheduler: WorkScheduler

    init(scheduler: WorkScheduler) {
        self.scheduler = scheduler
    }

    func leaseBytes(
        for key: ByteCacheKey,
        priority: MediaPriority,
        operation: @escaping @Sendable (UUID) async throws -> CachedByteFile
    ) -> ConsumerLease<CachedByteFile> {
        let consumerID = UUID()
        if var shared = byteRequests[key] {
            shared.consumers.insert(consumerID)
            if shared.priority < priority {
                shared.priority = priority
                Task { await scheduler.promote(id: shared.workID, to: priority) }
            }
            byteRequests[key] = shared
            return byteLease(key: key, consumerID: consumerID, shared: shared)
        }

        let workID = UUID()
        let task = Task { try await operation(workID) }
        let shared = Shared(workID: workID, task: task, consumers: [consumerID], priority: priority)
        byteRequests[key] = shared
        return byteLease(key: key, consumerID: consumerID, shared: shared)
    }

    func leaseRender(
        for key: RenderCacheKey,
        priority: MediaPriority,
        operation: @escaping @Sendable (UUID) async throws -> RenderSurface
    ) -> ConsumerLease<RenderSurface> {
        let consumerID = UUID()
        if var shared = renderRequests[key] {
            shared.consumers.insert(consumerID)
            if shared.priority < priority {
                shared.priority = priority
                Task { await scheduler.promote(id: shared.workID, to: priority) }
            }
            renderRequests[key] = shared
            return renderLease(key: key, consumerID: consumerID, shared: shared)
        }

        let workID = UUID()
        let task = Task { try await operation(workID) }
        let shared = Shared(workID: workID, task: task, consumers: [consumerID], priority: priority)
        renderRequests[key] = shared
        return renderLease(key: key, consumerID: consumerID, shared: shared)
    }

    func invalidate(accountNamespace: UUID, assetID: UUID) {
        for (key, shared) in byteRequests
        where key.accountNamespace == accountNamespace && key.assetID == assetID {
            shared.task.cancel()
            byteRequests.removeValue(forKey: key)
        }
        for (key, shared) in renderRequests
        where key.byteKey.accountNamespace == accountNamespace && key.byteKey.assetID == assetID {
            shared.task.cancel()
            renderRequests.removeValue(forKey: key)
        }
    }

    func invalidate(accountNamespace: UUID) {
        let byteKeys = byteRequests.keys.filter { $0.accountNamespace == accountNamespace }
        for key in byteKeys {
            byteRequests.removeValue(forKey: key)?.task.cancel()
        }
        let renderKeys = renderRequests.keys.filter { $0.byteKey.accountNamespace == accountNamespace }
        for key in renderKeys {
            renderRequests.removeValue(forKey: key)?.task.cancel()
        }
    }

    func stats() -> (byteRequests: Int, renderRequests: Int) {
        (byteRequests.count, renderRequests.count)
    }

    func effectiveBytePriority(for key: ByteCacheKey) -> MediaPriority? {
        byteRequests[key]?.priority
    }

    private func byteLease(
        key: ByteCacheKey,
        consumerID: UUID,
        shared: Shared<CachedByteFile>
    ) -> ConsumerLease<CachedByteFile> {
        ConsumerLease(
            id: consumerID,
            task: shared.task,
            release: { [weak self] in Task { await self?.releaseByte(key: key, consumerID: consumerID) } },
            promote: { [weak self] priority in Task { await self?.promoteByte(key: key, priority: priority) } }
        )
    }

    private func renderLease(
        key: RenderCacheKey,
        consumerID: UUID,
        shared: Shared<RenderSurface>
    ) -> ConsumerLease<RenderSurface> {
        ConsumerLease(
            id: consumerID,
            task: shared.task,
            release: { [weak self] in Task { await self?.releaseRender(key: key, consumerID: consumerID) } },
            promote: { [weak self] priority in Task { await self?.promoteRender(key: key, priority: priority) } }
        )
    }

    private func releaseByte(key: ByteCacheKey, consumerID: UUID) {
        guard var shared = byteRequests[key] else { return }
        shared.consumers.remove(consumerID)
        if shared.consumers.isEmpty {
            shared.task.cancel()
            byteRequests.removeValue(forKey: key)
        } else {
            byteRequests[key] = shared
        }
    }

    private func releaseRender(key: RenderCacheKey, consumerID: UUID) {
        guard var shared = renderRequests[key] else { return }
        shared.consumers.remove(consumerID)
        if shared.consumers.isEmpty {
            shared.task.cancel()
            renderRequests.removeValue(forKey: key)
        } else {
            renderRequests[key] = shared
        }
    }

    private func promoteByte(key: ByteCacheKey, priority: MediaPriority) async {
        guard var shared = byteRequests[key], shared.priority < priority else { return }
        shared.priority = priority
        byteRequests[key] = shared
        await scheduler.promote(id: shared.workID, to: priority)
    }

    private func promoteRender(key: RenderCacheKey, priority: MediaPriority) async {
        guard var shared = renderRequests[key], shared.priority < priority else { return }
        shared.priority = priority
        renderRequests[key] = shared
        await scheduler.promote(id: shared.workID, to: priority)
    }
}
