import Foundation

struct ViewerItem: Hashable, Identifiable, Sendable {
    let descriptor: MediaAssetDescriptor
    let accessibilityLabel: String
    let rating: AssetRating?

    var id: UUID { descriptor.id }

    init(
        descriptor: MediaAssetDescriptor,
        accessibilityLabel: String = "Photo",
        rating: AssetRating? = nil
    ) {
        self.descriptor = descriptor
        let trimmed = accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessibilityLabel = trimmed.isEmpty ? "Photo" : trimmed
        self.rating = rating
    }
}

struct ViewerActions: Sendable {
    let onDismiss: @MainActor @Sendable () -> Void
    let onRate: @MainActor @Sendable (ViewerItem, AssetRating?) async -> ViewerRatingMutationOutcome
    let onExport: @MainActor @Sendable (ViewerItem, AssetVariant) -> Void
    let onSettings: @MainActor @Sendable () -> Void

    init(
        onDismiss: @escaping @MainActor @Sendable () -> Void,
        onRate: @escaping @MainActor @Sendable (ViewerItem, AssetRating?) async -> ViewerRatingMutationOutcome,
        onExport: @escaping @MainActor @Sendable (ViewerItem, AssetVariant) -> Void,
        onSettings: @escaping @MainActor @Sendable () -> Void
    ) {
        self.onDismiss = onDismiss
        self.onRate = onRate
        self.onExport = onExport
        self.onSettings = onSettings
    }
}

enum ViewerRatingMutationOutcome: Equatable, Sendable {
    case verified(AssetRating?)
    case failed
}

enum ViewerInteractionState: Equatable, Sendable {
    case idle
    case paging
    case zooming
    case panning
}

struct ViewerFrameKey: Hashable, Sendable {
    let assetID: UUID
    let variant: AssetVariant
}

enum ViewerAccessibilityID {
    static let screen = "viewer.screen"
    static let close = "viewer.close"
    static let settings = "viewer.settings"
    static let variantPicker = "viewer.variant"
    static let fit = "viewer.fit"
    static let rate = "viewer.rate"
    static let download = "viewer.download"
    static let previous = "viewer.previous"
    static let next = "viewer.next"
    static let loading = "viewer.loading"
    static let error = "viewer.error"
    static let retry = "viewer.retry"

    static func media(assetID: UUID) -> String {
        "viewer.media.\(assetID.uuidString.lowercased())"
    }

    static func pageLabel(item: ViewerItem, index: Int, count: Int) -> String {
        "\(item.accessibilityLabel), \(index + 1) of \(count)"
    }
}

enum ViewerRatingLabel {
    static func text(for rating: AssetRating?) -> String {
        guard let rating else { return "Unrated" }
        if rating == .rejected { return "Reject" }
        return rating == .one ? "1 Star" : "\(rating.rawValue) Stars"
    }
}
