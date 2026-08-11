import Testing
@testable import Otter

@MainActor
@Suite("Viewer direct download coordination")
struct ViewerDownloadCoordinatorTests {
    @Test("Duplicate taps share one active asset and rendition request")
    func duplicateTapIsIgnoredAndCancellationIsStaleSafe() async {
        let item = viewerTestItems(count: 1)[0]
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let coordinator = ViewerDownloadCoordinator()
        var callCount = 0
        let perform: ViewerDownloadCoordinator.Perform = { _, _ in
            callCount += 1
            for await _ in gate.stream { break }
            return .success(message: "Saved to Photos")
        }

        coordinator.start(
            item: item,
            variant: .current,
            perform: perform,
            currentAssetID: { item.id }
        )
        coordinator.start(
            item: item,
            variant: .current,
            perform: perform,
            currentAssetID: { item.id }
        )
        await settleViewerTasks()

        #expect(callCount == 1)
        #expect(coordinator.state.isWorking)

        coordinator.cancel()
        gate.continuation.yield(())
        gate.continuation.finish()
        await settleViewerTasks()

        #expect(coordinator.state == .idle)
        #expect(coordinator.successGeneration == 0)
    }

    @Test("A completed stale asset cannot update the newly selected photo")
    func photoSwitchRejectsStaleCompletion() async {
        let items = viewerTestItems(count: 2)
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let coordinator = ViewerDownloadCoordinator()
        var currentAssetID = items[0].id

        coordinator.start(
            item: items[0],
            variant: .original,
            perform: { _, _ in
                for await _ in gate.stream { break }
                return .success(message: "Saved to Photos")
            },
            currentAssetID: { currentAssetID }
        )
        await settleViewerTasks()
        currentAssetID = items[1].id
        gate.continuation.yield(())
        gate.continuation.finish()

        #expect(await waitForViewerCondition { coordinator.state == .idle })
        #expect(coordinator.successGeneration == 0)
    }

    @Test("Retry preserves the failed asset and rendition")
    func retryPreservesRequestIdentity() async {
        let item = viewerTestItems(count: 1)[0]
        let coordinator = ViewerDownloadCoordinator()
        let failure = PresentationFailure(title: "Download Failed", message: "Try again")
        var variants: [AssetVariant] = []
        let perform: ViewerDownloadCoordinator.Perform = { _, variant in
            variants.append(variant)
            return variants.count == 1
                ? .failure(failure)
                : .success(message: "Saved to Photos")
        }

        coordinator.start(
            item: item,
            variant: .original,
            perform: perform,
            currentAssetID: { item.id }
        )
        #expect(await waitForViewerCondition {
            if case .failed = coordinator.state { return true }
            return false
        })

        coordinator.retry(perform: perform, currentAssetID: { item.id })
        #expect(await waitForViewerCondition {
            if case .completed = coordinator.state { return true }
            return false
        })

        #expect(variants == [.original, .original])
        #expect(coordinator.successGeneration == 1)
    }
}
