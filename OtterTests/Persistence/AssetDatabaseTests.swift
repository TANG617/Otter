import Foundation
import Testing
@testable import Otter

@Suite("GRDB asset database")
struct AssetDatabaseTests {
    @Test("Migrations create account-scoped metadata tables and indexes")
    func migrations() throws {
        let database = try AssetDatabase.inMemory()
        let objects = try database.schemaObjects()

        #expect(objects.contains("accounts"))
        #expect(objects.contains("assets"))
        #expect(objects.contains("syncStates"))
        #expect(objects.contains("serverMediaProfiles"))
        #expect(objects.contains("assets_timeline_window"))
        #expect(objects.contains("assets_updated"))
    }

    @Test("Account, sync, and media profile records round trip and cascade")
    func accountRecords() throws {
        let database = try AssetDatabase.inMemory()
        let account = TestAssetFactory.account()
        try database.saveAccount(account)
        let asset = TestAssetFactory.asset()
        try database.upsertAssets([asset], accountNamespace: account.namespace)
        let observation = RepresentationObservation(
            mimeType: "image/webp",
            maximumObservedDimension: 1_440,
            byteCount: 123_456
        )
        let profile = ServerMediaProfile(
            accountNamespace: account.namespace,
            thumbnail: nil,
            preview: observation,
            fullsize: nil
        )
        try database.saveServerMediaProfile(profile)

        #expect(try database.account(namespace: account.namespace) == account)
        #expect(try database.serverMediaProfile(accountNamespace: account.namespace) == profile)
        try database.deleteAccount(namespace: account.namespace)
        #expect(try database.count(accountNamespace: account.namespace) == 0)
        #expect(try database.serverMediaProfile(accountNamespace: account.namespace) == nil)
    }

    @Test("Batch merge updates metadata without duplicating identity")
    func batchMerge() throws {
        let database = try makeDatabase()
        let id = TestAssetFactory.deterministicID(1)
        let old = TestAssetFactory.asset(id: id, rating: .one)
        let updated = TestAssetFactory.asset(
            id: id,
            updatedAt: old.updatedAt.addingTimeInterval(1),
            rating: .five
        )

        try database.upsertAssets([old], accountNamespace: old.accountNamespace)
        try database.upsertAssets([updated], accountNamespace: updated.accountNamespace)

        #expect(try database.count(accountNamespace: updated.accountNamespace) == 1)
        #expect(try database.asset(id: id, accountNamespace: updated.accountNamespace)?.rating == .five)
    }

    @Test("Ordering uses local, file, created fallback then UUID descending")
    func orderingAndWindowing() throws {
        let database = try makeDatabase()
        let base = Date(timeIntervalSince1970: 10_000)
        let highID = TestAssetFactory.deterministicID(9)
        let lowID = TestAssetFactory.deterministicID(1)
        let assets = [
            TestAssetFactory.asset(id: lowID, localDateTime: base),
            TestAssetFactory.asset(id: highID, localDateTime: base),
            TestAssetFactory.asset(id: TestAssetFactory.deterministicID(8), fileCreatedAt: base.addingTimeInterval(-1)),
            TestAssetFactory.asset(id: TestAssetFactory.deterministicID(7), createdAt: base.addingTimeInterval(-2)),
            TestAssetFactory.asset(id: TestAssetFactory.deterministicID(6), localDateTime: base, isArchived: true),
            TestAssetFactory.asset(id: TestAssetFactory.deterministicID(5), localDateTime: base, isTrashed: true),
            TestAssetFactory.asset(id: TestAssetFactory.deterministicID(4), localDateTime: base, visibility: "hidden"),
        ]
        try database.upsertAssets(assets, accountNamespace: TestAssetFactory.accountNamespace)

        let first = try database.timelinePage(
            TimelinePageRequest(accountNamespace: TestAssetFactory.accountNamespace, limit: 2)
        )
        let second = try database.timelinePage(
            TimelinePageRequest(accountNamespace: TestAssetFactory.accountNamespace, after: first.nextCursor, limit: 2)
        )

        #expect(first.assets.map(\.id) == [highID, lowID])
        #expect(second.assets.map(\.id) == [TestAssetFactory.deterministicID(8), TestAssetFactory.deterministicID(7)])
        #expect(second.nextCursor == nil)
    }

    @Test("Timeline window remains bounded with one hundred thousand records")
    func hundredThousandQuery() throws {
        let database = try makeDatabase()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let assets = (0..<100_000).map { index in
            TestAssetFactory.asset(
                id: TestAssetFactory.deterministicID(index),
                localDateTime: base.addingTimeInterval(TimeInterval(index / 100)),
                updatedAt: base.addingTimeInterval(TimeInterval(index))
            )
        }
        try database.upsertAssets(assets, accountNamespace: TestAssetFactory.accountNamespace)

        let first = try database.timelinePage(
            TimelinePageRequest(accountNamespace: TestAssetFactory.accountNamespace, limit: 200)
        )
        let second = try database.timelinePage(
            TimelinePageRequest(
                accountNamespace: TestAssetFactory.accountNamespace,
                after: first.nextCursor,
                limit: 200
            )
        )

        #expect(try database.count(accountNamespace: TestAssetFactory.accountNamespace) == 100_000)
        #expect(first.assets.count == 200)
        #expect(second.assets.count == 200)
        #expect(Set(first.assets.map(\.id)).isDisjoint(with: Set(second.assets.map(\.id))))
    }

    private func makeDatabase() throws -> AssetDatabase {
        let database = try AssetDatabase.inMemory()
        try database.saveAccount(TestAssetFactory.account())
        return database
    }
}
