import Foundation
import Testing
@testable import Otter

private actor TimelinePageFixture {
    let first: TimelineAssetPage
    let subsequent: [TimelineCursor: TimelineAssetPage]
    private(set) var requests: [TimelinePageRequest] = []
    private(set) var refreshCount = 0
    private(set) var events: [String] = []

    init(first: TimelineAssetPage, subsequent: [TimelineCursor: TimelineAssetPage] = [:]) {
        self.first = first
        self.subsequent = subsequent
    }

    func page(_ request: TimelinePageRequest) throws -> TimelineAssetPage {
        requests.append(request)
        events.append("local")
        guard let cursor = request.after else { return first }
        guard let page = subsequent[cursor] else { throw FixtureError.missingPage }
        return page
    }

    func refresh() -> AssetRefreshResult {
        refreshCount += 1
        events.append("refresh")
        return AssetRefreshResult(
            receivedCount: 0,
            storedCount: 0,
            deletedCount: 0,
            highestObservedUpdatedAt: nil
        )
    }

    enum FixtureError: Error {
        case missingPage
    }
}

private final class TimelinePrefetchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requestBatches: [[MediaRequest]] = []
    private var cancellationCount = 0

    func record(_ requests: [MediaRequest]) -> TimelinePrefetchCancellation {
        lock.withLock { requestBatches.append(requests) }
        return TimelinePrefetchCancellation { [weak self] in
            self?.lock.withLock { self?.cancellationCount += 1 }
        }
    }

    var batches: [[MediaRequest]] {
        lock.withLock { requestBatches }
    }

    var cancellations: Int {
        lock.withLock { cancellationCount }
    }
}

@Suite("Library timeline state")
struct TimelineStateTests {
    @Test("Local page is presented before refresh and pagination deduplicates stable IDs")
    @MainActor
    func localFirstPaginationAndDedupe() async {
        let newest = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(1),
            localDateTime: Date(timeIntervalSince1970: 300)
        )
        let duplicate = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(2),
            localDateTime: Date(timeIntervalSince1970: 200)
        )
        let oldest = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(3),
            localDateTime: Date(timeIntervalSince1970: 100)
        )
        let cursor = TimelineCursor(date: duplicate.timelineDate, assetID: duplicate.id)
        let fixture = TimelinePageFixture(
            first: TimelineAssetPage(assets: [duplicate, newest], nextCursor: cursor),
            subsequent: [cursor: TimelineAssetPage(assets: [duplicate, oldest], nextCursor: nil)]
        )
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: client(fixture),
            pageSize: 2,
            calendar: utcCalendar
        )

        await state.loadIfNeeded()

        #expect(state.assets.map(\.id) == [newest.id, duplicate.id])
        #expect(state.canLoadMore)
        #expect(await fixture.refreshCount == 1)
        #expect(await fixture.requests.count == 2)
        #expect(await fixture.events == ["local", "refresh", "local"])

        await state.loadMore()

        #expect(state.assets.map(\.id) == [newest.id, duplicate.id, oldest.id])
        #expect(Set(state.assets.map(\.id)).count == 3)
        #expect(!state.canLoadMore)
    }

    @Test("Sections are deterministic and exclude ineligible or wrong-account records")
    @MainActor
    func groupingAndEligibility() async {
        let day = Date(timeIntervalSince1970: 1_700_000_000)
        let higherID = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(9),
            localDateTime: day
        )
        let lowerID = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(4),
            localDateTime: day
        )
        let priorDay = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(3),
            localDateTime: day.addingTimeInterval(-86_400)
        )
        let archived = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(2),
            localDateTime: day,
            isArchived: true
        )
        let wrongAccount = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(1),
            accountNamespace: UUID(uuidString: "cccccccc-cccc-cccc-cccc-cccccccccccc")!,
            localDateTime: day
        )
        let fixture = TimelinePageFixture(
            first: TimelineAssetPage(
                assets: [priorDay, lowerID, archived, higherID, wrongAccount],
                nextCursor: nil
            )
        )
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: client(fixture),
            calendar: utcCalendar
        )

        await state.loadIfNeeded()

        #expect(state.sections.count == 2)
        #expect(state.sections[0].assets.map(\.id) == [higherID.id, lowerID.id])
        #expect(state.sections[1].assets.map(\.id) == [priorDay.id])
        #expect(state.assetIndices[higherID.id] == 0)
    }

    @Test("Repeated continuation is stopped instead of creating an infinite sentinel")
    @MainActor
    func repeatedContinuationStopsPagination() async {
        let asset = TestAssetFactory.asset()
        let cursor = TimelineCursor(date: asset.timelineDate, assetID: asset.id)
        let fixture = TimelinePageFixture(
            first: TimelineAssetPage(assets: [asset], nextCursor: cursor),
            subsequent: [cursor: TimelineAssetPage(assets: [], nextCursor: cursor)]
        )
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: client(fixture),
            pageSize: 1
        )

        await state.loadIfNeeded()
        await state.loadMore()

        #expect(!state.canLoadMore)
        #expect(state.assets == [asset])
    }

    private func client(_ fixture: TimelinePageFixture) -> TimelineDataClient {
        TimelineDataClient(
            localPage: { request in try await fixture.page(request) },
            refresh: { _, _ in await fixture.refresh() }
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

@Suite("Library timeline prefetch")
struct TimelinePrefetchTests {
    @Test("Fast direction-aware plan stays bounded and favors the scroll direction")
    func planBoundsAndDirection() {
        let forward = TimelinePrefetchPlanner.plan(
            anchorIndex: 50,
            previousAnchorIndex: 10,
            elapsed: 0.1,
            assetCount: 1_000
        )
        let backward = TimelinePrefetchPlanner.plan(
            anchorIndex: 20,
            previousAnchorIndex: 60,
            elapsed: 0.1,
            assetCount: 1_000
        )

        #expect(forward.isFastScroll)
        #expect(forward.direction == .forward)
        #expect(forward.indices.count <= TimelinePrefetchPlanner.maximumRequestCount)
        #expect(forward.indices.filter { $0 > 50 }.count > forward.indices.filter { $0 < 50 }.count)
        #expect(backward.direction == .backward)
        #expect(backward.indices.filter { $0 < 20 }.count > backward.indices.filter { $0 > 20 }.count)
        #expect(Set(forward.indices).count == forward.indices.count)
        #expect(forward.indices.allSatisfy { (0..<1_000).contains($0) })
    }

    @Test("A new anchor and disappearance cancel prior prefetch work")
    @MainActor
    func cancellationAndLegalDemand() {
        let recorder = TimelinePrefetchRecorder()
        let client = TimelineMediaClient(
            peek: { _ in nil },
            frames: { _ in AsyncThrowingStream { $0.finish() } },
            prefetch: { recorder.record($0) }
        )
        let controller = TimelinePrefetchController(mediaClient: client)
        let assets = (0..<100).map {
            TestAssetFactory.asset(id: TestAssetFactory.deterministicID($0 + 1))
        }

        controller.update(
            assets: assets,
            anchorIndex: 5,
            timestamp: 1,
            cellSide: 100,
            displayScale: 3
        )
        controller.update(
            assets: assets,
            anchorIndex: 30,
            timestamp: 1.05,
            cellSide: 100,
            displayScale: 3
        )
        controller.cancel()

        #expect(recorder.batches.count == 2)
        #expect(recorder.cancellations == 2)
        let requests = recorder.batches.flatMap { $0 }
        #expect(requests.allSatisfy { $0.variant == AssetVariant.current })
        #expect(requests.allSatisfy { $0.purpose == MediaPurpose.timeline })
        #expect(requests.allSatisfy { $0.priority == MediaPriority.prefetch })
        #expect(requests.allSatisfy { $0.qualityPolicy == QualityPolicy.fast })
    }
}

@Suite("Library timeline identity")
struct TimelineIdentityTests {
    @Test("Asset and section accessibility identifiers are stable")
    func accessibilityIdentifiers() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = Date(timeIntervalSince1970: 1_704_067_200)

        #expect(TimelineAccessibilityID.asset(id) == "library.timeline.asset.aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
        #expect(TimelineAccessibilityID.section(day: day, calendar: calendar) == "library.timeline.section.2024-01-01")
    }

    @Test("Rating changes affect labels but never media content revisions")
    func ratingIsMetadataOnly() {
        let id = TestAssetFactory.deterministicID(42)
        let unrated = TestAssetFactory.asset(id: id, rating: nil)
        let rated = TestAssetFactory.asset(id: id, rating: .five)
        let unratedDescriptor = TimelineMediaDemand.descriptor(for: unrated)
        let ratedDescriptor = TimelineMediaDemand.descriptor(for: rated)

        #expect(unratedDescriptor.revisions == ratedDescriptor.revisions)
        #expect(TimelineAccessibilityLabel.asset(unrated).contains("Unrated"))
        #expect(TimelineAccessibilityLabel.asset(rated).contains("5 stars"))
    }

    @Test("Grid columns respond to phone and iPad widths with square-cell math")
    func responsiveGrid() {
        #expect(TimelineGridLayout.columnCount(for: 390) == 3)
        #expect(TimelineGridLayout.columnCount(for: 1_024) == 9)
        #expect(TimelineGridLayout.cellSide(for: 390) > 0)
        #expect(TimelineGridLayout.cellSide(for: 1_024) > TimelineGridLayout.cellSide(for: 390) * 0.8)
    }
}
