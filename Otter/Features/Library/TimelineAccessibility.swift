import Foundation

enum TimelineAccessibilityID {
    static let screen = "library.timeline"
    static let more = "library.timeline.more"
    static let settings = "library.timeline.settings"
    static let loading = "library.timeline.loading"
    static let empty = "library.timeline.empty"
    static let failure = "library.timeline.failure"
    static let retry = "library.timeline.retry"
    static let refreshFailure = "library.timeline.refreshFailure"
    static let refreshStatus = "library.timeline.refreshStatus"
    static let loadMore = "library.timeline.loadMore"
    static let scope = "library.timeline.scope"

    static func section(day: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        return String(
            format: "library.timeline.section.%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    static func asset(_ id: UUID) -> String {
        "library.timeline.asset.\(id.uuidString.lowercased())"
    }
}

enum TimelineAccessibilityLabel {
    static func asset(_ asset: TimelineAsset, calendar: Calendar = .autoupdatingCurrent) -> String {
        let date = asset.timelineDate.formatted(
            Date.FormatStyle(date: .long, time: .shortened, calendar: calendar)
        )
        let rating: String
        switch asset.rating?.rawValue {
        case -1:
            rating = "Rejected"
        case let value?:
            rating = value == 1 ? "1 star" : "\(value) stars"
        case nil:
            rating = "Unrated"
        }
        let favorite = asset.isFavorite ? ", Favorite" : ""
        return "Photo, \(date), \(rating)\(favorite)"
    }
}
