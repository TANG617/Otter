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

private actor MutableTimelinePageFixture {
    private var assets: [TimelineAsset]

    init(assets: [TimelineAsset] = []) {
        self.assets = assets
    }

    func page(_ request: TimelinePageRequest) -> TimelineAssetPage {
        TimelineAssetPage(assets: Array(assets.prefix(request.limit)), nextCursor: nil)
    }

    func replace(with assets: [TimelineAsset]) {
        self.assets = assets
    }
}

private actor GeneratedTimelinePageFixture {
    private let assets: [TimelineAsset]
    private let indices: [UUID: Int]
    private(set) var requests: [TimelinePageRequest] = []

    init(assets: [TimelineAsset]) {
        self.assets = assets
        indices = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
    }

    func page(_ request: TimelinePageRequest) -> TimelineAssetPage {
        requests.append(request)
        let start = request.after.flatMap { indices[$0.assetID] }.map { $0 + 1 } ?? 0
        guard start < assets.count else { return TimelineAssetPage(assets: [], nextCursor: nil) }
        let end = min(start + request.limit, assets.count)
        let page = Array(assets[start..<end])
        let cursor = end < assets.count ? page.last.map {
            TimelineCursor(date: $0.timelineDate, assetID: $0.id)
        } : nil
        return TimelineAssetPage(assets: page, nextCursor: cursor)
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
    @Test("Cached assets are published while refresh is still pending")
    @MainActor
    func cachedContentPrecedesRefreshCompletion() async {
        let cached = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1))
        let fixture = MutableTimelinePageFixture(assets: [cached])
        let refresh = AssetRefreshEventStream.makeStream(bufferingPolicy: .unbounded)
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: TimelineDataClient(
                localPage: { request in await fixture.page(request) },
                refreshEvents: { _, _ in refresh.stream }
            )
        )

        let loading = Task { await state.loadIfNeeded() }
        for _ in 0..<100 {
            if state.isRefreshing { break }
            await Task.yield()
        }

        #expect(state.contentState == .loaded)
        #expect(state.assets == [cached])
        #expect(state.isRefreshing)

        let result = AssetRefreshResult(
            receivedCount: 0,
            storedCount: 0,
            deletedCount: 0,
            highestObservedUpdatedAt: nil
        )
        refresh.continuation.yield(.completed(result))
        refresh.continuation.finish()
        await loading.value
        #expect(!state.isRefreshing)
    }

    @Test("A first committed refresh batch becomes browsable before a later failure")
    @MainActor
    func progressiveBatchSurvivesRefreshFailure() async {
        let first = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1))
        let fixture = MutableTimelinePageFixture()
        let refresh = AssetRefreshEventStream.makeStream(bufferingPolicy: .unbounded)
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: TimelineDataClient(
                localPage: { request in await fixture.page(request) },
                refreshEvents: { _, _ in refresh.stream }
            )
        )

        let loading = Task { await state.loadIfNeeded() }
        for _ in 0..<100 {
            if state.isRefreshing { break }
            await Task.yield()
        }
        await fixture.replace(with: [first])
        refresh.continuation.yield(
            .progress(
                AssetRefreshProgress(
                    stage: .showingLatest,
                    processedCount: 1,
                    storedCount: 1,
                    totalCount: nil
                )
            )
        )
        for _ in 0..<100 {
            if state.assets == [first] { break }
            await Task.yield()
        }

        #expect(state.assets == [first])
        #expect(state.contentState == .loaded)
        #expect(state.isRefreshing)
        #expect(state.refreshProgress?.processedCount == 1)

        refresh.continuation.finish(throwing: TimelineProgressFailure.laterPage)
        await loading.value
        #expect(state.assets == [first])
        #expect(state.refreshFailure != nil)
        #expect(!state.isRefreshing)
    }

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

    @Test("A verified rating update replaces only the matching loaded asset")
    @MainActor
    func verifiedRatingUpdateIsNarrow() async {
        let asset = TestAssetFactory.asset(rating: nil)
        let fixture = TimelinePageFixture(
            first: TimelineAssetPage(assets: [asset], nextCursor: nil)
        )
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: client(fixture),
            calendar: utcCalendar
        )
        await state.loadIfNeeded()

        let verified = TestAssetFactory.asset(
            id: asset.id,
            localDateTime: asset.localDateTime,
            createdAt: asset.createdAt,
            updatedAt: asset.updatedAt,
            rating: .five
        )
        state.applyVerifiedUpdate(verified)

        #expect(state.assets.count == 1)
        #expect(state.assets.first?.rating == .five)
        #expect(state.sections.first?.assets.first?.rating == .five)
        #expect(state.assetIndices[asset.id] == 0)
    }

    @Test("A 10k metadata update is incremental for day month and year sections")
    @MainActor
    func tenThousandMetadataUpdateStaysIncremental() async {
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let assets = (0..<10_000).map { index in
            TestAssetFactory.asset(
                id: TestAssetFactory.deterministicID(index + 1),
                localDateTime: base.addingTimeInterval(Double(-index * 60))
            )
        }
        let fixture = GeneratedTimelinePageFixture(assets: assets)
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: TimelineDataClient(
                localPage: { request in await fixture.page(request) },
                refresh: { _, _ in
                    AssetRefreshResult(
                        receivedCount: 0,
                        storedCount: assets.count,
                        deletedCount: 0,
                        highestObservedUpdatedAt: nil
                    )
                }
            ),
            pageSize: 500,
            calendar: utcCalendar
        )
        await state.loadIfNeeded()
        while state.canLoadMore { await state.loadMore() }
        #expect(state.assets.count == 10_000)

        let anchor = state.assets[5_000].id
        let initialRevision = state.windowRevision
        for (offset, scope) in TimelineBrowseScope.allCases.enumerated() {
            state.setBrowseScope(scope)
            let before = state.mutationDiagnostics
            let existing = state.assets[5_000]
            state.applyVerifiedUpdate(
                replacing(existing, rating: AssetRating(rawValue: offset + 1))
            )

            #expect(
                state.mutationDiagnostics.incrementalMetadataUpdateCount
                    == before.incrementalMetadataUpdateCount + 1
            )
            #expect(
                state.mutationDiagnostics.fullSectionRebuildCount
                    == before.fullSectionRebuildCount
            )
            #expect(state.windowRevision == initialRevision)
            #expect(state.assetIndices[anchor] == 5_000)
            #expect(state.sections.flatMap(\.assets).first(where: { $0.id == anchor })?.rating?.rawValue == offset + 1)
        }
    }

    @Test("One hundred ordered pages append without full section rebuilds")
    @MainActor
    func oneHundredPagesStayIncremental() async {
        let base = Date(timeIntervalSince1970: 2_000_000_000)
        let assets = (0..<10_000).map { index in
            TestAssetFactory.asset(
                id: TestAssetFactory.deterministicID(index + 1),
                localDateTime: base.addingTimeInterval(Double(-index * 90))
            )
        }
        let fixture = GeneratedTimelinePageFixture(assets: assets)
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: TimelineDataClient(
                localPage: { request in await fixture.page(request) },
                refresh: { _, _ in
                    AssetRefreshResult(
                        receivedCount: 0,
                        storedCount: assets.count,
                        deletedCount: 0,
                        highestObservedUpdatedAt: nil
                    )
                }
            ),
            pageSize: 100,
            calendar: utcCalendar
        )
        await state.loadIfNeeded()
        let rebuildsAfterInitialWindow = state.mutationDiagnostics.fullSectionRebuildCount
        while state.canLoadMore { await state.loadMore() }

        #expect(state.assets.count == 10_000)
        #expect(state.mutationDiagnostics.incrementalPageAppendCount == 99)
        #expect(state.mutationDiagnostics.fullSectionRebuildCount == rebuildsAfterInitialWindow)
        #expect(state.mutationDiagnostics.appendFallbackRebuildCount == 0)
        #expect(await fixture.requests.count == 101)
    }

    @Test("Date movement and invalid append order use the explicit rebuild fallback")
    @MainActor
    func orderingFallbacksAreCounted() async {
        let first = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(1),
            localDateTime: Date(timeIntervalSince1970: 300)
        )
        let second = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(2),
            localDateTime: Date(timeIntervalSince1970: 200)
        )
        let unexpectedlyNew = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(3),
            localDateTime: Date(timeIntervalSince1970: 400)
        )
        let cursor = TimelineCursor(date: second.timelineDate, assetID: second.id)
        let fixture = TimelinePageFixture(
            first: TimelineAssetPage(assets: [first, second], nextCursor: cursor),
            subsequent: [cursor: TimelineAssetPage(assets: [unexpectedlyNew], nextCursor: nil)]
        )
        let state = TimelineState(
            accountNamespace: TestAssetFactory.accountNamespace,
            dataClient: client(fixture),
            pageSize: 2,
            calendar: utcCalendar
        )
        await state.loadIfNeeded()
        await state.loadMore()

        #expect(state.assets.map(\.id) == [unexpectedlyNew.id, first.id, second.id])
        #expect(state.mutationDiagnostics.appendFallbackRebuildCount == 1)
        let rebuilds = state.mutationDiagnostics.fullSectionRebuildCount

        state.applyVerifiedUpdate(
            replacing(second, timelineDate: Date(timeIntervalSince1970: 500))
        )
        #expect(state.assets.first?.id == second.id)
        #expect(state.mutationDiagnostics.fullSectionRebuildCount == rebuilds + 1)
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

private func replacing(
    _ asset: TimelineAsset,
    timelineDate: Date? = nil,
    rating: AssetRating? = nil
) -> TimelineAsset {
    TimelineAsset(
        accountNamespace: asset.accountNamespace,
        id: asset.id,
        ownerID: asset.ownerID,
        mediaType: asset.mediaType,
        localDateTime: timelineDate ?? asset.localDateTime,
        fileCreatedAt: asset.fileCreatedAt,
        createdAt: asset.createdAt,
        updatedAt: asset.updatedAt,
        width: asset.width,
        height: asset.height,
        thumbhash: asset.thumbhash,
        checksum: asset.checksum,
        originalFileName: asset.originalFileName,
        originalMimeType: asset.originalMimeType,
        isFavorite: asset.isFavorite,
        isEdited: asset.isEdited,
        isArchived: asset.isArchived,
        isTrashed: asset.isTrashed,
        visibility: asset.visibility,
        rating: rating ?? asset.rating
    )
}

private enum TimelineProgressFailure: Error, Sendable {
    case laterPage
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

    @Test("Favourite changes never alter media content revisions")
    func favoriteIsMetadataOnly() {
        let id = TestAssetFactory.deterministicID(43)
        let standard = TestAssetFactory.asset(id: id, isFavorite: false)
        let favorite = TestAssetFactory.asset(id: id, isFavorite: true)

        #expect(
            TimelineMediaDemand.descriptor(for: standard).revisions
                == TimelineMediaDemand.descriptor(for: favorite).revisions
        )
    }

    @Test("Grid columns respond to phone and iPad widths with square-cell math")
    func responsiveGrid() {
        #expect(TimelineGridLayout.columnCount(for: 390) == 3)
        #expect(TimelineGridLayout.columnCount(for: 1_024) == 6)
        #expect(TimelineGridLayout.cellSide(for: 390) > 0)
        #expect(TimelineGridLayout.cellSide(for: 1_024) > TimelineGridLayout.cellSide(for: 390) * 0.8)
    }

    @Test("Refresh insertions preserve the visible asset anchor with a nearby deletion fallback")
    func refreshAnchorPolicy() {
        let first = TestAssetFactory.deterministicID(1)
        let anchor = TestAssetFactory.deterministicID(2)
        let third = TestAssetFactory.deterministicID(3)
        let inserted = TestAssetFactory.deterministicID(4)

        #expect(
            TimelineScrollAnchorPolicy.preservedAnchor(
                current: anchor,
                previousIDs: [first, anchor, third],
                refreshedIDs: [inserted, first, anchor, third]
            ) == anchor
        )
        #expect(
            TimelineScrollAnchorPolicy.preservedAnchor(
                current: anchor,
                previousIDs: [first, anchor, third],
                refreshedIDs: [inserted, first, third]
            ) == third
        )
    }
}
