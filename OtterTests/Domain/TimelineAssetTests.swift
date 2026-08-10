import Foundation
import Testing
@testable import Otter

@Suite("Timeline asset domain")
struct TimelineAssetTests {
    @Test("Rating accepts only Immich's supported values")
    func ratingValidation() {
        #expect(AssetRating(rawValue: -1) == .rejected)
        #expect(AssetRating(rawValue: 1) == .one)
        #expect(AssetRating(rawValue: 5) == .five)
        #expect(AssetRating(rawValue: 0) == nil)
        #expect(AssetRating(rawValue: 6) == nil)
        #expect(AssetRating(rawValue: -2) == nil)
    }

    @Test("Timeline date falls back in the required order")
    func dateFallback() {
        let local = Date(timeIntervalSince1970: 300)
        let file = Date(timeIntervalSince1970: 200)
        let created = Date(timeIntervalSince1970: 100)

        #expect(TestAssetFactory.asset(localDateTime: local, fileCreatedAt: file, createdAt: created).timelineDate == local)
        #expect(TestAssetFactory.asset(fileCreatedAt: file, createdAt: created).timelineDate == file)
        #expect(TestAssetFactory.asset(createdAt: created).timelineDate == created)
    }

    @Test("Grouping uses the supplied calendar and deterministic UUID tie break")
    func grouping() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let sameDate = Date(timeIntervalSince1970: 1_700_000_000)
        let lower = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(1),
            localDateTime: sameDate
        )
        let higher = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(2),
            localDateTime: sameDate
        )
        let priorDay = TestAssetFactory.asset(
            id: TestAssetFactory.deterministicID(3),
            localDateTime: sameDate.addingTimeInterval(-86_400)
        )

        let sections = TimelineGrouping.sections(from: [lower, priorDay, higher], calendar: calendar)

        #expect(sections.count == 2)
        #expect(sections[0].assets.map(\.id) == [higher.id, lower.id])
        #expect(sections[1].assets == [priorDay])
        #expect(sections[0].day == calendar.startOfDay(for: sameDate))
    }
}
