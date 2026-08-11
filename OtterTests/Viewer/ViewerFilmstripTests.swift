import Testing
@testable import Otter

@MainActor
@Suite("Viewer filmstrip thumbnails")
struct ViewerFilmstripTests {
    @Test("Filmstrip demand is bounded to Current timeline thumbnails")
    func boundedDemand() {
        let item = viewerTestItems(count: 1)[0]
        for scale in [1.0, 2.0, 3.0, 4.0] {
            let request = ViewerFilmstripDemand.request(
                for: item,
                displayScale: scale,
                priority: .visible
            )
            #expect(request.variant == .current)
            #expect(request.purpose == .timeline)
            #expect(request.qualityPolicy == .balanced)
            #expect(request.requiredPixels >= Double(ViewerFilmstripDemand.minimumPixels))
            #expect(request.requiredPixels <= Double(ViewerFilmstripDemand.maximumPixels) + 0.001)
        }
    }

    @Test("Prefetch stays bounded and never requests fullscreen or Original media")
    func boundedPrefetchWindow() {
        let items = viewerTestItems(count: 100)
        let requests = ViewerFilmstripDemand.prefetchRequests(
            items: items,
            currentIndex: 50,
            displayScale: 3
        )

        #expect(requests.count == ViewerFilmstripDemand.maximumPrefetchCount)
        #expect(requests.allSatisfy { $0.variant == .current })
        #expect(requests.allSatisfy { $0.purpose == .timeline })
        #expect(requests.allSatisfy { $0.priority == .neighbor || $0.priority == .prefetch })
    }

    @Test("A distant thumbnail loads before it becomes the fullscreen selection")
    func distantThumbnailLoadsIndependently() async {
        let item = viewerTestItems(count: 20)[19]
        let pipeline = ViewerTestPipeline()
        let state = ViewerFilmstripThumbnailState()
        let request = ViewerFilmstripDemand.request(
            for: item,
            displayScale: 3,
            priority: .visible
        )

        let loading = Task {
            await state.load(existingFrame: nil, request: request, pipeline: pipeline)
        }
        await settleViewerTasks()
        pipeline.yield(
            viewerTestFrame(quality: .preview, isFinal: true),
            assetID: item.id,
            variant: .current
        )
        pipeline.finish(assetID: item.id, variant: .current)

        #expect(await waitForViewerCondition { state.frame?.quality == .preview })
        await loading.value
        #expect(pipeline.allRequests().count == 1)
        #expect(pipeline.allRequests().first?.asset.id == item.id)
    }

    @Test("Disappearing cells reject late frames and release their stream")
    func cancellationRejectsLateFrame() async {
        let item = viewerTestItems(count: 1)[0]
        let pipeline = ViewerTestPipeline()
        let state = ViewerFilmstripThumbnailState()
        let request = ViewerFilmstripDemand.request(
            for: item,
            displayScale: 3,
            priority: .visible
        )
        let loading = Task {
            await state.load(existingFrame: nil, request: request, pipeline: pipeline)
        }
        await settleViewerTasks()

        state.cancel()
        loading.cancel()
        pipeline.yield(
            viewerTestFrame(quality: .preview),
            assetID: item.id,
            variant: .current
        )
        pipeline.finish(assetID: item.id, variant: .current)
        await loading.value

        #expect(state.frame == nil)
        #expect(pipeline.cancellations() >= 1)
    }
}
