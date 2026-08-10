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
        let entered = AsyncTestGate()
        let release = AsyncTestGate()
        let key = try mediaTestKey()
        let file = CachedByteFile(key: key, fileURL: URL(fileURLWithPath: "/tmp/test"), byteCount: 1, mimeType: nil, pixelWidth: nil, pixelHeight: nil)
        let operation: @Sendable (UUID) async throws -> CachedByteFile = { _ in
            await counter.increment()
            await entered.open()
            await release.wait()
            return file
        }

        let first = await coordinator.leaseBytes(for: key, priority: .prefetch, operation: operation)
        await entered.wait()
        let second = await coordinator.leaseBytes(for: key, priority: .interactive, operation: operation)
        first.release()
        await release.open()
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
        let entered = AsyncTestGate()
        let release = AsyncTestGate()
        let lease = await coordinator.leaseBytes(for: key, priority: .prefetch) { _ in
            await entered.open()
            await release.wait()
            try Task.checkCancellation()
            throw MediaError.cancelled
        }
        await entered.wait()
        lease.release()
        #expect(await waitForTestCondition {
            await coordinator.stats().byteRequests == 0
        })
        await release.open()
        await #expect(throws: CancellationError.self) {
            try await lease.value()
        }
    }

    @Test("Same render key shares one decode task")
    func sharedRenderLease() async throws {
        let scheduler = WorkScheduler()
        let coordinator = RequestCoordinator(scheduler: scheduler)
        let counter = InvocationCounter()
        let entered = AsyncTestGate()
        let release = AsyncTestGate()
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
            await entered.open()
            await release.wait()
            return surface
        }

        let first = await coordinator.leaseRender(for: renderKey, priority: .visible, operation: operation)
        await entered.wait()
        let second = await coordinator.leaseRender(for: renderKey, priority: .visible, operation: operation)
        await release.open()
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
        let firstEntered = AsyncTestGate()
        let release = AsyncTestGate()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    _ = try? await scheduler.run(lane: .thumbnail, priority: .visible) {
                        await tracker.enter()
                        await firstEntered.open()
                        await release.wait()
                        await tracker.leave()
                        return ()
                    }
                }
            }
            await firstEntered.wait()
            #expect(await waitForTestCondition {
                await scheduler.stats().queuedByLane[.thumbnail] == 7
            })
            #expect(await tracker.maximum == 1)
            await release.open()
        }
        #expect(await tracker.maximum == 1)
    }

    @Test("Higher priority queued work runs first")
    func priorityOrdering() async throws {
        let scheduler = WorkScheduler(limits: .init(values: [.preview: 1]))
        let order = CompletionOrder()
        let blockerEntered = AsyncTestGate()
        let releaseBlocker = AsyncTestGate()
        let blocker = Task {
            try await scheduler.run(lane: .preview, priority: .visible) {
                await blockerEntered.open()
                await releaseBlocker.wait()
                await order.append("blocker")
            }
        }
        await blockerEntered.wait()
        let low = Task {
            try await scheduler.run(lane: .preview, priority: .prefetch) { await order.append("low") }
        }
        #expect(await waitForTestCondition {
            await scheduler.stats().queuedByLane[.preview] == 1
        })
        let high = Task {
            try await scheduler.run(lane: .preview, priority: .interactive) { await order.append("high") }
        }
        #expect(await waitForTestCondition {
            await scheduler.stats().queuedByLane[.preview] == 2
        })
        await releaseBlocker.open()
        _ = try await (blocker.value, low.value, high.value)
        #expect(await order.values == ["blocker", "high", "low"])
    }

    @Test("Active interactive work suppresses new speculative dispatch")
    func interactiveSuppressesSpeculative() async throws {
        let scheduler = WorkScheduler(
            limits: .init(values: [.preview: 1, .thumbnail: 4])
        )
        let speculativeStarts = InvocationCounter()
        let interactiveEntered = AsyncTestGate()
        let releaseInteractive = AsyncTestGate()
        let interactive = Task {
            try await scheduler.run(lane: .preview, priority: .interactive) {
                await interactiveEntered.open()
                await releaseInteractive.wait()
            }
        }
        await interactiveEntered.wait()
        let speculative = Task {
            try await scheduler.run(lane: .thumbnail, priority: .prefetch) {
                await speculativeStarts.increment()
            }
        }
        #expect(await waitForTestCondition {
            await scheduler.stats().queuedByLane[.thumbnail] == 1
        })
        #expect(await speculativeStarts.value == 0)

        await releaseInteractive.open()
        _ = try await (interactive.value, speculative.value)
        #expect(await speculativeStarts.value == 1)
    }
}
