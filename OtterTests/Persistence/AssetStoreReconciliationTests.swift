import Foundation
import Testing
@testable import Otter

private actor QueuedAssetRemote: AssetRemoteDataSource {
    enum WriteBehavior: Sendable {
        case succeeds
        case permissionDenied
    }

    private var pages: [AssetSearchPage]
    private var details: [UUID: TimelineAsset]
    private let writeBehavior: WriteBehavior
    private var requests: [AssetSearchRequest] = []

    init(
        pages: [AssetSearchPage] = [],
        details: [UUID: TimelineAsset] = [:],
        writeBehavior: WriteBehavior = .succeeds
    ) {
        self.pages = pages
        self.details = details
        self.writeBehavior = writeBehavior
    }

    func enqueue(_ pages: [AssetSearchPage]) {
        self.pages.append(contentsOf: pages)
    }

    func capturedRequests() -> [AssetSearchRequest] {
        requests
    }

    func searchAssets(_ request: AssetSearchRequest, accountNamespace: UUID) async throws -> AssetSearchPage {
        requests.append(request)
        return pages.removeFirst()
    }

    func asset(id: UUID, accountNamespace: UUID) async throws -> TimelineAsset {
        guard let asset = details[id] else {
            throw ImmichClientError.notFound
        }
        return asset
    }

    func writeRating(_ rating: AssetRating?, assetID: UUID, accountNamespace: UUID) async throws {
        if writeBehavior == .permissionDenied {
            throw ImmichClientError.permissionDenied
        }
    }

    func writeFavorite(_ isFavorite: Bool, assetID: UUID, accountNamespace: UUID) async throws {
        if writeBehavior == .permissionDenied {
            throw ImmichClientError.permissionDenied
        }
    }
}

private actor PausingAssetRemote: AssetRemoteDataSource {
    private let firstPage: AssetSearchPage
    private let secondPage: AssetSearchPage
    private let failsOnSecondPage: Bool
    private let secondPageGate: AsyncStream<Void>
    private let secondPageGateContinuation: AsyncStream<Void>.Continuation
    private var requestCount = 0
    private var observedCancellation = false

    init(
        firstPage: AssetSearchPage,
        secondPage: AssetSearchPage,
        failsOnSecondPage: Bool = false
    ) {
        self.firstPage = firstPage
        self.secondPage = secondPage
        self.failsOnSecondPage = failsOnSecondPage
        let gate = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        secondPageGate = gate.stream
        secondPageGateContinuation = gate.continuation
    }

    func searchAssets(_ request: AssetSearchRequest, accountNamespace: UUID) async throws -> AssetSearchPage {
        requestCount += 1
        guard requestCount > 1 else { return firstPage }

        for await _ in secondPageGate { break }
        if Task.isCancelled {
            observedCancellation = true
            throw CancellationError()
        }
        if failsOnSecondPage {
            throw TestFailure.secondPage
        }
        return secondPage
    }

    func asset(id: UUID, accountNamespace: UUID) async throws -> TimelineAsset {
        throw ImmichClientError.notFound
    }

    func writeRating(_ rating: AssetRating?, assetID: UUID, accountNamespace: UUID) async throws {}

    func resumeSecondPage() {
        secondPageGateContinuation.yield(())
        secondPageGateContinuation.finish()
    }

    func cancellationWasObserved() -> Bool {
        observedCancellation
    }

    enum TestFailure: Error, Sendable {
        case secondPage
    }
}

private actor SerializedMetadataRemote: AssetRemoteDataSource {
    enum Failure: Error {
        case rating
    }

    private var storedAsset: TimelineAsset
    private let ratingFails: Bool
    private var activeWrites = 0
    private var maximumActiveWrites = 0

    init(asset: TimelineAsset, ratingFails: Bool = false) {
        storedAsset = asset
        self.ratingFails = ratingFails
    }

    func searchAssets(_ request: AssetSearchRequest, accountNamespace: UUID) async throws -> AssetSearchPage {
        AssetSearchPage(assets: [storedAsset], nextContinuation: nil)
    }

    func asset(id: UUID, accountNamespace: UUID) async throws -> TimelineAsset {
        storedAsset
    }

    func writeRating(_ rating: AssetRating?, assetID: UUID, accountNamespace: UUID) async throws {
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        defer { activeWrites -= 1 }
        await Task.yield()
        if ratingFails { throw Failure.rating }
        storedAsset = replacing(storedAsset, rating: rating)
    }

    func writeFavorite(_ isFavorite: Bool, assetID: UUID, accountNamespace: UUID) async throws {
        activeWrites += 1
        maximumActiveWrites = max(maximumActiveWrites, activeWrites)
        defer { activeWrites -= 1 }
        await Task.yield()
        storedAsset = replacing(storedAsset, isFavorite: isFavorite)
    }

    func maximumConcurrency() -> Int { maximumActiveWrites }

    private func replacing(
        _ asset: TimelineAsset,
        rating: AssetRating? = nil,
        isFavorite: Bool? = nil
    ) -> TimelineAsset {
        TimelineAsset(
            accountNamespace: asset.accountNamespace,
            id: asset.id,
            ownerID: asset.ownerID,
            mediaType: asset.mediaType,
            localDateTime: asset.localDateTime,
            fileCreatedAt: asset.fileCreatedAt,
            createdAt: asset.createdAt,
            updatedAt: asset.updatedAt,
            width: asset.width,
            height: asset.height,
            thumbhash: asset.thumbhash,
            checksum: asset.checksum,
            originalFileName: asset.originalFileName,
            originalMimeType: asset.originalMimeType,
            isFavorite: isFavorite ?? asset.isFavorite,
            isEdited: asset.isEdited,
            isArchived: asset.isArchived,
            isTrashed: asset.isTrashed,
            visibility: asset.visibility,
            rating: rating ?? asset.rating
        )
    }
}

@Suite("Local-first search reconciliation")
struct AssetStoreReconciliationTests {
    @Test("Refresh stream exposes the first committed batch before the final page")
    func progressiveFirstBatch() async throws {
        let database = try makeDatabase()
        let first = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1))
        let second = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(2))
        let remote = PausingAssetRemote(
            firstPage: AssetSearchPage(assets: [first], nextContinuation: "2"),
            secondPage: AssetSearchPage(assets: [second], nextContinuation: nil)
        )
        let store = LocalFirstAssetStore(database: database, remote: remote)
        var iterator = store.refreshEvents(
            accountNamespace: TestAssetFactory.accountNamespace,
            mode: .bootstrap
        ).makeAsyncIterator()

        let connecting = try #require(await iterator.next())
        let firstBatch = try #require(await iterator.next())
        #expect(connecting == .progress(progress(.connecting, processed: 0, stored: 0)))
        #expect(firstBatch == .progress(progress(.showingLatest, processed: 1, stored: 1)))
        #expect(try database.count(accountNamespace: TestAssetFactory.accountNamespace) == 1)

        await remote.resumeSecondPage()
        var remaining: [AssetRefreshEvent] = []
        while let event = try await iterator.next() {
            remaining.append(event)
        }

        let progressValues = ([connecting, firstBatch] + remaining).compactMap { event -> AssetRefreshProgress? in
            guard case let .progress(progress) = event else { return nil }
            return progress
        }
        #expect(progressValues.map(\.stage) == [.connecting, .showingLatest, .organizing, .completed])
        #expect(progressValues.map(\.processedCount) == [0, 1, 2, 2])
        #expect(
            zip(progressValues, progressValues.dropFirst()).allSatisfy { pair in
                pair.0.processedCount <= pair.1.processedCount
            }
        )
        #expect(progressValues.dropLast().allSatisfy { $0.totalCount == nil })
        #expect(try database.count(accountNamespace: TestAssetFactory.accountNamespace) == 2)
        #expect(remaining.contains(.completed(AssetRefreshResult(
            receivedCount: 2,
            storedCount: 2,
            deletedCount: 0,
            highestObservedUpdatedAt: max(first.updatedAt, second.updatedAt)
        ))))
    }

    @Test("Ending the only refresh consumer cancels pending remote work")
    func refreshConsumerRelease() async throws {
        let database = try makeDatabase()
        let first = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1))
        let remote = PausingAssetRemote(
            firstPage: AssetSearchPage(assets: [first], nextContinuation: "2"),
            secondPage: AssetSearchPage(assets: [], nextContinuation: nil)
        )
        let store = LocalFirstAssetStore(database: database, remote: remote)

        let consumer = Task {
            for try await _ in store.refreshEvents(
                accountNamespace: TestAssetFactory.accountNamespace,
                mode: .bootstrap
            ) {}
        }
        for _ in 0..<100 {
            if try database.count(accountNamespace: TestAssetFactory.accountNamespace) == 1 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        consumer.cancel()
        _ = try? await consumer.value

        for _ in 0..<100 {
            if await remote.cancellationWasObserved() { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(await remote.cancellationWasObserved())
        #expect(try database.count(accountNamespace: TestAssetFactory.accountNamespace) == 1)
    }

    @Test("A later refresh failure keeps the first committed batch and never reports completion")
    func progressiveFailurePreservesContent() async throws {
        let database = try makeDatabase()
        let first = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1))
        let remote = PausingAssetRemote(
            firstPage: AssetSearchPage(assets: [first], nextContinuation: "2"),
            secondPage: AssetSearchPage(assets: [], nextContinuation: nil),
            failsOnSecondPage: true
        )
        await remote.resumeSecondPage()
        let store = LocalFirstAssetStore(database: database, remote: remote)
        var events: [AssetRefreshEvent] = []
        var failed = false

        do {
            for try await event in store.refreshEvents(
                accountNamespace: TestAssetFactory.accountNamespace,
                mode: .bootstrap
            ) {
                events.append(event)
            }
        } catch is PausingAssetRemote.TestFailure {
            failed = true
        }

        #expect(failed)
        #expect(events.contains(.progress(progress(.showingLatest, processed: 1, stored: 1))))
        #expect(!events.contains { if case .completed = $0 { true } else { false } })
        #expect(try database.count(accountNamespace: TestAssetFactory.accountNamespace) == 1)
    }

    @Test("Bootstrap deduplicates overlapping pages and keeps newest metadata")
    func bootstrapMerge() async throws {
        let database = try makeDatabase()
        let id = TestAssetFactory.deterministicID(1)
        let older = TestAssetFactory.asset(id: id, updatedAt: Date(timeIntervalSince1970: 100), rating: .one)
        let newer = TestAssetFactory.asset(id: id, updatedAt: Date(timeIntervalSince1970: 200), rating: .five)
        let second = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(2))
        let remote = QueuedAssetRemote(pages: [
            AssetSearchPage(assets: [older], nextContinuation: "2"),
            AssetSearchPage(assets: [newer, second], nextContinuation: nil),
        ])
        let store = LocalFirstAssetStore(database: database, remote: remote)

        let result = try await store.refresh(accountNamespace: TestAssetFactory.accountNamespace, mode: .bootstrap)

        #expect(result.receivedCount == 3)
        #expect(result.storedCount == 2)
        #expect(try database.asset(id: id, accountNamespace: TestAssetFactory.accountNamespace)?.rating == .five)
    }

    @Test("Incremental refresh overlaps the high-water mark without deleting")
    func overlapRefresh() async throws {
        let database = try makeDatabase()
        let old = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(1),
            updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        try database.upsertAssets([old], accountNamespace: TestAssetFactory.accountNamespace)
        try database.updateSyncState(
            accountNamespace: TestAssetFactory.accountNamespace,
            reconciliationAt: Date(timeIntervalSince1970: 1_000),
            highestObservedUpdatedAt: old.updatedAt
        )
        let remote = QueuedAssetRemote(pages: [
            AssetSearchPage(assets: [], nextContinuation: nil),
        ])
        let store = LocalFirstAssetStore(
            database: database,
            remote: remote,
            now: { Date(timeIntervalSince1970: 1_100) }
        )

        let result = try await store.refresh(
            accountNamespace: TestAssetFactory.accountNamespace,
            mode: .incremental(overlap: 120)
        )

        #expect(result.deletedCount == 0)
        #expect(try database.count(accountNamespace: TestAssetFactory.accountNamespace) == 1)
        let request = try #require(await remote.capturedRequests().last)
        #expect(request.updatedAfter == Date(timeIntervalSince1970: 880))
    }

    @Test("Incremental refresh becomes a daily full reconciliation")
    func scheduledReconciliation() async throws {
        let database = try makeDatabase()
        let retained = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1))
        let removed = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(2))
        try database.upsertAssets([retained, removed], accountNamespace: TestAssetFactory.accountNamespace)
        try database.updateSyncState(
            accountNamespace: TestAssetFactory.accountNamespace,
            reconciliationAt: Date(timeIntervalSince1970: 1_000),
            highestObservedUpdatedAt: retained.updatedAt
        )
        let remote = QueuedAssetRemote(pages: [
            AssetSearchPage(assets: [retained], nextContinuation: nil),
        ])
        let store = LocalFirstAssetStore(
            database: database,
            remote: remote,
            now: { Date(timeIntervalSince1970: 1_000 + LocalFirstAssetStore.fullReconciliationInterval + 1) }
        )

        let result = try await store.refresh(
            accountNamespace: TestAssetFactory.accountNamespace,
            mode: .incremental(overlap: 300)
        )

        #expect(result.deletedCount == 1)
        #expect(try database.asset(id: retained.id, accountNamespace: retained.accountNamespace) != nil)
        #expect(try database.asset(id: removed.id, accountNamespace: removed.accountNamespace) == nil)
        #expect(try #require(await remote.capturedRequests().first).updatedAfter == nil)
    }

    @Test("Full reconciliation removes assets missing from stable search")
    func reconciliationDelete() async throws {
        let database = try makeDatabase()
        let retained = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1))
        let deleted = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(2))
        try database.upsertAssets([retained, deleted], accountNamespace: TestAssetFactory.accountNamespace)
        let remote = QueuedAssetRemote(pages: [
            AssetSearchPage(assets: [retained], nextContinuation: nil),
        ])
        let store = LocalFirstAssetStore(database: database, remote: remote)

        let result = try await store.refresh(
            accountNamespace: TestAssetFactory.accountNamespace,
            mode: .fullReconciliation
        )

        #expect(result.deletedCount == 1)
        #expect(try database.asset(id: retained.id, accountNamespace: retained.accountNamespace) != nil)
        #expect(try database.asset(id: deleted.id, accountNamespace: deleted.accountNamespace) == nil)
    }

    @Test("Repeated continuation is rejected before an infinite polling loop")
    func continuationCycle() async throws {
        let database = try makeDatabase()
        let remote = QueuedAssetRemote(pages: [
            AssetSearchPage(assets: [], nextContinuation: "2"),
            AssetSearchPage(assets: [], nextContinuation: "2"),
        ])
        let store = LocalFirstAssetStore(database: database, remote: remote)

        await #expect(throws: AssetStoreError.paginationCycle) {
            try await store.refresh(accountNamespace: TestAssetFactory.accountNamespace, mode: .bootstrap)
        }
    }

    @Test("Verified rating write commits server state")
    func ratingVerified() async throws {
        let database = try makeDatabase()
        let local = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1), rating: .one)
        let verified = TestAssetFactory.asset(id: local.id, rating: .five)
        try database.upsertAssets([local], accountNamespace: local.accountNamespace)
        let remote = QueuedAssetRemote(details: [local.id: verified])
        let repository = RatingRepository(database: database, remote: remote)

        let result = try await repository.setRating(.five, assetID: local.id, accountNamespace: local.accountNamespace)

        #expect(result.previousRating == .one)
        #expect(result.asset.rating == .five)
        #expect(try database.asset(id: local.id, accountNamespace: local.accountNamespace)?.rating == .five)
    }

    @Test("Rating permission failure rolls back and disables writes for the session")
    func ratingRollback() async throws {
        let database = try makeDatabase()
        let local = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1), rating: .one)
        try database.upsertAssets([local], accountNamespace: local.accountNamespace)
        let remote = QueuedAssetRemote(writeBehavior: .permissionDenied)
        let repository = RatingRepository(database: database, remote: remote)

        await #expect(throws: ImmichClientError.permissionDenied) {
            try await repository.setRating(.five, assetID: local.id, accountNamespace: local.accountNamespace)
        }
        #expect(try database.asset(id: local.id, accountNamespace: local.accountNamespace)?.rating == .one)
        #expect(await repository.writeAvailability == .unavailable)
        await #expect(throws: RatingRepositoryError.unavailable) {
            try await repository.setRating(.four, assetID: local.id, accountNamespace: local.accountNamespace)
        }
    }

    @Test("Rating read-back mismatch rolls back and disables the deprecated write")
    func ratingMismatch() async throws {
        let database = try makeDatabase()
        let local = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(1), rating: .one)
        let staleServer = TestAssetFactory.asset(id: local.id, rating: .two)
        try database.upsertAssets([local], accountNamespace: local.accountNamespace)
        let remote = QueuedAssetRemote(details: [local.id: staleServer])
        let repository = RatingRepository(database: database, remote: remote)

        await #expect(throws: RatingRepositoryError.verificationMismatch) {
            try await repository.setRating(.five, assetID: local.id, accountNamespace: local.accountNamespace)
        }
        #expect(try database.asset(id: local.id, accountNamespace: local.accountNamespace)?.rating == .one)
        #expect(await repository.writeAvailability == .unavailable)
    }

    @Test("Verified Favourite write commits server state")
    func favoriteVerified() async throws {
        let database = try makeDatabase()
        let local = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(11))
        let verified = TestAssetFactory.asset(id: local.id, isFavorite: true)
        try database.upsertAssets([local], accountNamespace: local.accountNamespace)
        let remote = QueuedAssetRemote(details: [local.id: verified])
        let repository = RatingRepository(database: database, remote: remote)

        let result = try await repository.setFavorite(
            true,
            assetID: local.id,
            accountNamespace: local.accountNamespace
        )

        #expect(result.previousValue == false)
        #expect(result.asset.isFavorite)
        #expect(try database.asset(id: local.id, accountNamespace: local.accountNamespace)?.isFavorite == true)
    }

    @Test("Favourite permission failure rolls back and disables metadata writes")
    func favoriteRollback() async throws {
        let database = try makeDatabase()
        let local = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(12))
        try database.upsertAssets([local], accountNamespace: local.accountNamespace)
        let remote = QueuedAssetRemote(writeBehavior: .permissionDenied)
        let repository = RatingRepository(database: database, remote: remote)

        await #expect(throws: ImmichClientError.permissionDenied) {
            try await repository.setFavorite(
                true,
                assetID: local.id,
                accountNamespace: local.accountNamespace
            )
        }
        #expect(try database.asset(id: local.id, accountNamespace: local.accountNamespace)?.isFavorite == false)
        #expect(await repository.writeAvailability == .unavailable)
    }

    @Test("Rating and Favourite writes for one asset are serialized and both verify")
    func interleavedMetadataWritesSerialize() async throws {
        let database = try makeDatabase()
        let local = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(21), rating: .one)
        try database.upsertAssets([local], accountNamespace: local.accountNamespace)
        let remote = SerializedMetadataRemote(asset: local)
        let repository = RatingRepository(database: database, remote: remote)

        let ratingTask = Task {
            try await repository.setRating(
                .five,
                assetID: local.id,
                accountNamespace: local.accountNamespace
            )
        }
        let favoriteTask = Task {
            try await repository.setFavorite(
                true,
                assetID: local.id,
                accountNamespace: local.accountNamespace
            )
        }
        _ = try await (ratingTask.value, favoriteTask.value)

        let stored = try #require(try database.asset(id: local.id, accountNamespace: local.accountNamespace))
        #expect(stored.rating == .five)
        #expect(stored.isFavorite)
        #expect(await remote.maximumConcurrency() == 1)
    }

    @Test("A Rating failure rolls back only Rating while queued Favourite succeeds")
    func ratingFailureDoesNotRollbackFavorite() async throws {
        let database = try makeDatabase()
        let local = TestAssetFactory.asset(id: TestAssetFactory.deterministicID(22), rating: .one)
        try database.upsertAssets([local], accountNamespace: local.accountNamespace)
        let remote = SerializedMetadataRemote(asset: local, ratingFails: true)
        let repository = RatingRepository(database: database, remote: remote)

        let ratingTask = Task {
            try await repository.setRating(
                .five,
                assetID: local.id,
                accountNamespace: local.accountNamespace
            )
        }
        let favoriteTask = Task {
            try await repository.setFavorite(
                true,
                assetID: local.id,
                accountNamespace: local.accountNamespace
            )
        }
        _ = try? await ratingTask.value
        _ = try await favoriteTask.value

        let stored = try #require(try database.asset(id: local.id, accountNamespace: local.accountNamespace))
        #expect(stored.rating == .one)
        #expect(stored.isFavorite)
        #expect(await remote.maximumConcurrency() == 1)
    }

    private func makeDatabase() throws -> AssetDatabase {
        let database = try AssetDatabase.inMemory()
        try database.saveAccount(TestAssetFactory.account())
        return database
    }

    private func progress(
        _ stage: AssetRefreshProgress.Stage,
        processed: Int,
        stored: Int
    ) -> AssetRefreshProgress {
        AssetRefreshProgress(
            stage: stage,
            processedCount: processed,
            storedCount: stored,
            totalCount: nil
        )
    }
}
