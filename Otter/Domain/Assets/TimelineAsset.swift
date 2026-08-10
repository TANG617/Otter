import Foundation

enum TimelineAssetMediaType: String, Codable, Hashable, Sendable {
    case image = "IMAGE"
}

struct TimelineAsset: Codable, Hashable, Sendable, Identifiable {
    let accountNamespace: UUID
    let id: UUID
    let ownerID: UUID?
    let mediaType: TimelineAssetMediaType
    let localDateTime: Date?
    let fileCreatedAt: Date?
    let createdAt: Date
    let updatedAt: Date
    let width: Int?
    let height: Int?
    let thumbhash: String?
    let checksum: String?
    let originalFileName: String?
    let originalMimeType: String?
    let isFavorite: Bool
    let isEdited: Bool
    let isArchived: Bool
    let isTrashed: Bool
    let visibility: String?
    let rating: AssetRating?

    var timelineDate: Date {
        localDateTime ?? fileCreatedAt ?? createdAt
    }

    var isTimelineEligible: Bool {
        mediaType == .image
            && !isArchived
            && !isTrashed
            && (visibility == nil || visibility == "timeline")
    }
}

struct TimelineCursor: Codable, Hashable, Sendable {
    let date: Date
    let assetID: UUID
}

struct TimelinePageRequest: Hashable, Sendable {
    let accountNamespace: UUID
    let after: TimelineCursor?
    let limit: Int

    init(accountNamespace: UUID, after: TimelineCursor? = nil, limit: Int = 200) {
        self.accountNamespace = accountNamespace
        self.after = after
        self.limit = max(1, min(limit, 500))
    }
}

struct TimelineAssetPage: Equatable, Sendable {
    let assets: [TimelineAsset]
    let nextCursor: TimelineCursor?
}

struct TimelineSection: Equatable, Sendable, Identifiable {
    let day: Date
    let assets: [TimelineAsset]

    var id: Date { day }
}

enum TimelineGrouping {
    static func sections(
        from assets: [TimelineAsset],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TimelineSection] {
        let ordered = assets.sorted {
            if $0.timelineDate != $1.timelineDate {
                return $0.timelineDate > $1.timelineDate
            }
            return $0.id.uuidString.lowercased() > $1.id.uuidString.lowercased()
        }
        return sectionsFromOrdered(ordered, calendar: calendar)
    }

    static func sectionsFromOrdered(
        _ ordered: [TimelineAsset],
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TimelineSection] {
        var sections: [TimelineSection] = []
        var currentDay: Date?
        var currentAssets: [TimelineAsset] = []
        for asset in ordered {
            let day = calendar.startOfDay(for: asset.timelineDate)
            if let currentDay, currentDay != day {
                sections.append(TimelineSection(day: currentDay, assets: currentAssets))
                currentAssets.removeAll(keepingCapacity: true)
            }
            currentDay = day
            currentAssets.append(asset)
        }
        if let currentDay {
            sections.append(TimelineSection(day: currentDay, assets: currentAssets))
        }
        return sections
    }
}
