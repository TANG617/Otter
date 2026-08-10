import Foundation
import Testing
@testable import Otter

private actor InvocationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private actor CompletionOrder {
    private(set) var values: [String] = []
    func append(_ value: String) { values.append(value) }
}

private actor ConcurrencyTracker {
    private var active = 0
    private(set) var maximum = 0

    func enter() {
        active += 1
        maximum = max(maximum, active)
    }

    func leave() { active -= 1 }
}

@Suite("Request coordinator")
struct RequestCoordinatorTests {
    @Test("Two byte consumers share work and one release does not cancel the other")
    func sharedByteLease() async throws {
        let scheduler = WorkScheduler()
        let coordinator = RequestCoordinator(scheduler: scheduler)
        let counter = InvocationCounter()
        let key = try mediaTestKey()
        let file = CachedByteFile(key: key, fileURL: URL(fileURLWithPath: "/tmp/test"), byteCount: 1, mimeType: nil, pixelWidth: nil, pixelHeight: nil)
        let operation: @Sendable (UUID) async throws -> CachedByteFile = { _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(50))
            return file
        }

        let first = await coordinator.leaseBytes(for: key, priority: .prefetch, operation: operation)
        let second = await coordinator.leaseBytes(for: key, priority: .interactive, operation: operation)
        first.release()
        let result = try await second.value()
        #expect(result.key == key)
        #expect(await counter.value == 1)
        second.release()
    }

    @Test("Final consumer release cancels underlying work")
    func finalReleaseCancels() async throws {
        let scheduler = WorkScheduler()
        let coordinator = RequestCoordinator(scheduler: scheduler)
        let key = try mediaTestKey()
        let lease = await coordinator.leaseBytes(for: key, priority: .prefetch) { _ in
            try await Task.sleep(for: .seconds(30))
            throw MediaError.cancelled
        }
        lease.release()
        try await Task.sleep(for: .milliseconds(50))
        let stats = await coordinator.stats()
        #expect(stats.byteRequests == 0)
    }

    @Test("Same render key shares one decode task")
    func sharedRenderLease() async throws {
        let scheduler = WorkScheduler()
        let coordinator = RequestCoordinator(scheduler: scheduler)
        let counter = InvocationCounter()
        let byteKey = try mediaTestKey()
        let renderKey = RenderCacheKey(
            byteKey: byteKey,
            specification: .init(pixelBucket: 384, dynamicRange: .standard, contentMode: .aspectFill),
            transformVersion: 1
        )
        let base64 = Data(repeating: 0, count: 40).base64EncodedString()
        let surface = try ThumbHashDecoder().decode(base64: base64)
        let operation: @Sendable (UUID) async throws -> RenderSurface = { _ in
            await counter.increment()
            try await Task.sleep(for: .milliseconds(30))
            return surface
        }

        let first = await coordinator.leaseRender(for: renderKey, priority: .visible, operation: operation)
        let second = await coordinator.leaseRender(for: renderKey, priority: .visible, operation: operation)
        _ = try await (first.value(), second.value())
        #expect(await counter.value == 1)
        first.release()
        second.release()
    }
}

@Suite("Work scheduler")
struct WorkSchedulerTests {
    @Test("Lane bound is enforced")
    func laneBound() async throws {
        let scheduler = WorkScheduler(limits: .init(values: [.thumbnail: 1]))
        let tracker = ConcurrencyTracker()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await scheduler.run(lane: .thumbnail, priority: .visible) {
                        await tracker.enter()
                        try await Task.sleep(for: .milliseconds(5))
                        await tracker.leave()
                        return ()
                    }
                }
            }
        }
        #expect(await tracker.maximum == 1)
    }

    @Test("Higher priority queued work runs first")
    func priorityOrdering() async throws {
        let scheduler = WorkScheduler(limits: .init(values: [.preview: 1]))
        let order = CompletionOrder()
        let blocker = Task {
            try await scheduler.run(lane: .preview, priority: .visible) {
                try await Task.sleep(for: .milliseconds(80))
                await order.append("blocker")
            }
        }
        try await Task.sleep(for: .milliseconds(10))
        let low = Task {
            try await scheduler.run(lane: .preview, priority: .prefetch) { await order.append("low") }
        }
        let high = Task {
            try await scheduler.run(lane: .preview, priority: .interactive) { await order.append("high") }
        }
        _ = try await (blocker.value, low.value, high.value)
        #expect(await order.values == ["blocker", "high", "low"])
    }
}
