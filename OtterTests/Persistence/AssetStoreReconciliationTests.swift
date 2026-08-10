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
}

@Suite("Local-first search reconciliation")
struct AssetStoreReconciliationTests {
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

    private func makeDatabase() throws -> AssetDatabase {
        let database = try AssetDatabase.inMemory()
        try database.saveAccount(TestAssetFactory.account())
        return database
    }
}
