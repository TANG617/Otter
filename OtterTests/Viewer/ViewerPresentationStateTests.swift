import CoreGraphics
import Testing
@testable import Otter

@MainActor
@Suite("Viewer presentation state")
struct ViewerPresentationStateTests {
    @Test("Initial selection and rating are explicit")
    func initialSelectionAndRating() {
        let items = viewerTestItems(count: 3)
        let state = ViewerPresentationState(
            items: items,
            initialAssetID: items[1].id,
            pipeline: ViewerTestPipeline()
        )

        #expect(state.currentIndex == 1)
        #expect(state.currentItem?.id == items[1].id)
        #expect(state.selectedVariant == .current)
        #expect(state.rating(for: items[0].id) == .four)

        state.setRating(.rejected, for: items[1].id)
        #expect(state.rating(for: items[1].id) == .rejected)
        state.setRating(nil, for: items[1].id)
        #expect(state.rating(for: items[1].id) == nil)
    }

    @Test("Live request window is bounded to current and adjacent items")
    func boundedRequestWindowAndCancellation() async {
        let items = viewerTestItems(count: 5)
        let pipeline = ViewerTestPipeline()
        let state = ViewerPresentationState(
            items: items,
            initialAssetID: items[2].id,
            pipeline: pipeline
        )
        state.updateViewport(size: CGSize(width: 390, height: 844), displayScale: 3)
        state.start()

        #expect(state.activeRequests.count == 3)
        #expect(Set(state.activeRequests.keys.map(\.assetID)) == Set(items[1...3].map(\.id)))
        let current = state.activeRequests[ViewerFrameKey(assetID: items[2].id, variant: .current)]
        #expect(current?.priority == .interactive)
        #expect(current?.qualityPolicy == .maximum)
        #expect(state.activeRequests.values.filter { $0.priority == .neighbor }.count == 2)
        #expect(state.activeRequests.values.filter { $0.priority == .neighbor }.allSatisfy { $0.purpose == .timeline })

        for item in items[1...3] {
            pipeline.yield(viewerTestFrame(quality: .preview), assetID: item.id, variant: .current)
        }
        await settleViewerTasks()
        #expect(state.retainedFrameCount == 3)

        state.select(index: 4)
        await settleViewerTasks()

        #expect(state.activeRequests.count == 2)
        #expect(Set(state.activeRequests.keys.map(\.assetID)) == Set([items[3].id, items[4].id]))
        #expect(state.retainedFrameCount == 1)
        #expect(pipeline.cancellations() >= 2)
        state.stop()
        await settleViewerTasks()
        #expect(state.activeRequests.isEmpty)
        #expect(pipeline.activeRequests().isEmpty)
    }

    @Test("Viewport and zoom scale promote current demand")
    func viewportAndZoomDemand() {
        let item = viewerTestItems(count: 1)[0]
        let state = ViewerPresentationState(items: [item], pipeline: ViewerTestPipeline())
        state.updateViewport(size: CGSize(width: 1_024, height: 768), displayScale: 2)
        state.start()

        let initial = state.activeRequests.values.first
        #expect(initial?.purpose == .viewer)
        #expect(initial?.viewport == PixelSize(width: 1_024, height: 768))
        #expect(initial?.displayScale == 2)

        state.setInteractionState(.zooming)
        state.updateZoomScale(2.5)
        state.setInteractionState(.idle)

        let zoomed = state.activeRequests.values.first
        #expect(zoomed?.purpose == .zoom)
        #expect(zoomed?.zoomScale == 2.5)
        #expect(zoomed?.priority == .interactive)
        state.stop()
    }

    @Test("Progressive upgrade is staged while interacting")
    func progressiveFrameStaging() async {
        let item = viewerTestItems(count: 1)[0]
        let pipeline = ViewerTestPipeline()
        let state = ViewerPresentationState(items: [item], pipeline: pipeline)
        state.updateViewport(size: CGSize(width: 390, height: 844), displayScale: 3)
        state.start()

        pipeline.yield(viewerTestFrame(quality: .preview), assetID: item.id, variant: .current)
        await settleViewerTasks()
        #expect(state.currentFrame?.quality == .preview)

        state.setInteractionState(.zooming)
        pipeline.yield(viewerTestFrame(quality: .fullsize), assetID: item.id, variant: .current)
        await settleViewerTasks()
        #expect(state.currentFrame?.quality == .preview)

        state.setInteractionState(.idle)
        #expect(state.currentFrame?.quality == .fullsize)
        state.stop()
    }

    @Test("Original keeps Current visible until its own frame arrives")
    func originalUsesCurrentFallback() async {
        let item = viewerTestItems(count: 1)[0]
        let pipeline = ViewerTestPipeline()
        let state = ViewerPresentationState(items: [item], pipeline: pipeline)
        state.updateViewport(size: CGSize(width: 390, height: 844), displayScale: 3)
        state.start()
        pipeline.yield(viewerTestFrame(quality: .preview), assetID: item.id, variant: .current)
        await settleViewerTasks()

        state.selectVariant(.original)
        #expect(state.currentFrame?.quality == .preview)
        #expect(state.displayedVariant == .current)
        #expect(state.selectedVariant == .original)
        #expect(state.isLoadingSelectedVariant)
        #expect(Set(state.activeRequests.keys) == [ViewerFrameKey(assetID: item.id, variant: .original)])

        pipeline.yield(
            viewerTestFrame(quality: .originalDownsample, width: 32, height: 24, isFinal: true),
            assetID: item.id,
            variant: .original
        )
        await settleViewerTasks()

        #expect(state.currentFrame?.quality == .originalDownsample)
        #expect(state.displayedVariant == .original)
        #expect(!state.isLoadingSelectedVariant)
        state.stop()
    }
}
