import Foundation
import Testing
@testable import Otter

@Suite("Fixture app runtime")
struct FixtureAppRuntimeTests {
    @Test("Standard runtime exposes deterministic paged assets")
    func pages() async throws {
        let runtime = FixtureAppRuntime.make(configuration: .init(scale: .standard))
        let first = await runtime.assetStore.localPage(
            TimelinePageRequest(accountNamespace: runtime.accountNamespace, limit: 200)
        )
        let second = await runtime.assetStore.localPage(
            TimelinePageRequest(
                accountNamespace: runtime.accountNamespace,
                after: first.nextCursor,
                limit: 200
            )
        )

        #expect(first.assets.count == 200)
        #expect(second.assets.count == 200)
        #expect(Set(first.assets.map(\.id)).isDisjoint(with: Set(second.assets.map(\.id))))
    }

    @Test("Rating changes metadata without changing media revisions")
    func rating() async throws {
        let runtime = FixtureAppRuntime.make(configuration: .init(scale: .standard))
        let page = await runtime.assetStore.localPage(
            TimelinePageRequest(accountNamespace: runtime.accountNamespace, limit: 1)
        )
        let asset = try #require(page.assets.first)
        let before = TimelineMediaDemand.descriptor(for: asset).revisions
        let changed = try #require(await runtime.assetStore.setRating(.five, assetID: asset.id))

        #expect(changed.rating == .five)
        #expect(TimelineMediaDemand.descriptor(for: changed).revisions == before)
    }
}
