import CoreGraphics
import Testing
@testable import Otter

@MainActor
@Suite("Viewer presentation state")
struct ViewerPresentationStateTests {
    @Test("Motion policy preserves springs normally and cross-fades for Reduced Motion")
    func motionPolicy() {
        let standard = ViewerMotionPolicy(reduceMotion: false)
        #expect(standard.transition(momentumDriven: false) == .spring(.standard))
        #expect(standard.transition(momentumDriven: true) == .spring(.momentum))
        #expect(standard.dismissalScale(progress: 1) == 0.9)

        let reduced = ViewerMotionPolicy(reduceMotion: true)
        #expect(reduced.transition(momentumDriven: true) == .crossFade(duration: 0.18))
        #expect(reduced.dismissalScale(progress: 1) == 1)
    }

    @Test("A reversed gesture resumes from the current presentation value")
    func reverseInterruption() {
        var translation = ViewerInteractiveTranslation()
        translation.begin(from: -180)
        translation.update(gestureTranslation: 35)
        #expect(translation.value == -145)

        translation.begin(from: translation.value)
        translation.update(gestureTranslation: 90)
        #expect(translation.value == -55)
        translation.settle(at: 0)
        #expect(translation.value == 0)
    }

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
        #expect(state.isFavorite(items[0].id))
        #expect(!state.isFavorite(items[1].id))

        state.setRating(.rejected, for: items[1].id)
        #expect(state.rating(for: items[1].id) == .rejected)
        state.setRating(nil, for: items[1].id)
        #expect(state.rating(for: items[1].id) == nil)
        state.setFavorite(true, for: items[1].id)
        #expect(state.isFavorite(items[1].id))
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

    @Test("Paging keeps a high-resolution replacement staged until settlement")
    func pagingStagesHighResolutionUntilCompletion() async {
        let items = viewerTestItems(count: 2)
        let pipeline = ViewerTestPipeline()
        let state = ViewerPresentationState(items: items, pipeline: pipeline)
        state.updateViewport(size: CGSize(width: 390, height: 844), displayScale: 3)
        state.start()
        pipeline.yield(viewerTestFrame(quality: .preview), assetID: items[0].id, variant: .current)
        await settleViewerTasks()

        state.setInteractionState(.paging)
        pipeline.yield(viewerTestFrame(quality: .fullsize), assetID: items[0].id, variant: .current)
        await settleViewerTasks()
        #expect(state.currentFrame?.quality == .preview)

        state.setInteractionState(.idle)
        #expect(state.currentFrame?.quality == .fullsize)
        state.stop()
    }

    @Test("A stale equal request cannot finish a newer viewport request")
    func requestABARace() async {
        let item = viewerTestItems(count: 1)[0]
        let pipeline = ViewerTestPipeline()
        let state = ViewerPresentationState(items: [item], pipeline: pipeline)
        let originalSize = CGSize(width: 390, height: 844)

        state.updateViewport(size: originalSize, displayScale: 3)
        state.start()
        state.updateViewport(size: CGSize(width: 390, height: 760), displayScale: 3)
        state.updateViewport(size: originalSize, displayScale: 3)
        await settleViewerTasks()

        #expect(state.currentErrorMessage == nil)
        #expect(state.activeRequests.count == 1)

        pipeline.yield(
            viewerTestFrame(quality: .fullsize, isFinal: true),
            assetID: item.id,
            variant: .current
        )
        await settleViewerTasks()

        #expect(state.currentFrame?.quality == .fullsize)
        #expect(state.currentErrorMessage == nil)
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

    @Test("A larger render replaces an equal-quality frame")
    func equalQualityPixelUpgrade() async {
        let item = viewerTestItems(count: 1)[0]
        let pipeline = ViewerTestPipeline()
        let state = ViewerPresentationState(items: [item], pipeline: pipeline)
        state.updateViewport(size: CGSize(width: 390, height: 844), displayScale: 3)
        state.start()

        pipeline.yield(
            viewerTestFrame(quality: .fullsize, width: 1_536, height: 1_024),
            assetID: item.id,
            variant: .current
        )
        await settleViewerTasks()
        pipeline.yield(
            viewerTestFrame(quality: .fullsize, width: 3_072, height: 2_048),
            assetID: item.id,
            variant: .current
        )
        await settleViewerTasks()

        #expect(state.currentFrame?.surface.pixelWidth == 3_072)
        state.stop()
    }

    @Test("Viewer window appends pages without duplicating existing assets")
    func appendWindow() {
        let initial = viewerTestItems(count: 2)
        let next = viewerTestItems(count: 4)
        let state = ViewerPresentationState(items: initial, pipeline: ViewerTestPipeline())

        state.append(next)

        #expect(state.items.map(\.id) == next.map(\.id))
        #expect(state.items.count == 4)
    }

    @Test("Placeholder remains visible on failure and Retry starts a fresh real request")
    func placeholderFailureAndRetry() async {
        let item = viewerTestItems(count: 1)[0]
        let pipeline = ViewerTestPipeline()
        let state = ViewerPresentationState(items: [item], pipeline: pipeline)
        state.updateViewport(size: CGSize(width: 390, height: 844), displayScale: 3)
        state.start()

        pipeline.yield(
            viewerTestFrame(quality: .placeholder),
            assetID: item.id,
            variant: .current
        )
        pipeline.fail(
            MediaError.httpStatus(404, retryAfter: nil),
            assetID: item.id,
            variant: .current
        )

        #expect(await waitForViewerCondition { state.currentErrorMessage != nil })
        #expect(state.currentFrame?.quality == .placeholder)
        #expect(!state.isLoadingSelectedVariant)

        state.retryCurrent()
        #expect(pipeline.retries() == 1)
        #expect(pipeline.allRequests().count == 2)
        #expect(state.isLoadingSelectedVariant)

        pipeline.yield(
            viewerTestFrame(quality: .preview, isFinal: true),
            assetID: item.id,
            variant: .current
        )
        pipeline.finish(assetID: item.id, variant: .current)

        #expect(await waitForViewerCondition {
            state.currentFrame?.quality == .preview && state.currentErrorMessage == nil
        })
        #expect(!state.isLoadingSelectedVariant)
        state.stop()
    }
}
