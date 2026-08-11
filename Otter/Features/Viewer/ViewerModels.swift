import Foundation

struct ViewerItem: Hashable, Identifiable, Sendable {
    let descriptor: MediaAssetDescriptor
    let accessibilityLabel: String
    let rating: AssetRating?
    let isFavorite: Bool
    let captureDate: Date?

    var id: UUID { descriptor.id }

    init(
        descriptor: MediaAssetDescriptor,
        accessibilityLabel: String = "Photo",
        rating: AssetRating? = nil,
        isFavorite: Bool = false,
        captureDate: Date? = nil
    ) {
        self.descriptor = descriptor
        let trimmed = accessibilityLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        self.accessibilityLabel = trimmed.isEmpty ? "Photo" : trimmed
        self.rating = rating
        self.isFavorite = isFavorite
        self.captureDate = captureDate
    }
}

struct ViewerActions: Sendable {
    let onDismiss: @MainActor @Sendable () -> Void
    let onRate: @MainActor @Sendable (ViewerItem, AssetRating?) async -> ViewerRatingMutationOutcome
    let onFavorite: @MainActor @Sendable (ViewerItem, Bool) async -> ViewerFavoriteMutationOutcome
    let onDownload: @MainActor @Sendable (ViewerItem, AssetVariant) async -> ActionOutcome
    let onCurrentItemChanged: @MainActor @Sendable (UUID) -> Void

    init(
        onDismiss: @escaping @MainActor @Sendable () -> Void,
        onRate: @escaping @MainActor @Sendable (ViewerItem, AssetRating?) async -> ViewerRatingMutationOutcome,
        onFavorite: @escaping @MainActor @Sendable (ViewerItem, Bool) async -> ViewerFavoriteMutationOutcome = { _, value in .verified(value) },
        onDownload: @escaping @MainActor @Sendable (ViewerItem, AssetVariant) async -> ActionOutcome,
        onCurrentItemChanged: @escaping @MainActor @Sendable (UUID) -> Void = { _ in }
    ) {
        self.onDismiss = onDismiss
        self.onRate = onRate
        self.onFavorite = onFavorite
        self.onDownload = onDownload
        self.onCurrentItemChanged = onCurrentItemChanged
    }
}

enum ViewerRatingMutationOutcome: Equatable, Sendable {
    case verified(AssetRating?)
    case failed
}

enum ViewerFavoriteMutationOutcome: Equatable, Sendable {
    case verified(Bool)
    case failed
}

enum ViewerDownloadState: Equatable, Sendable {
    case idle
    case working
    case completed
    case failed(PresentationFailure)

    var isWorking: Bool { self == .working }
}

enum ViewerInteractionState: Equatable, Sendable {
    case idle
    case paging
    case zooming
    case panning
    case dismissing
}

enum ViewerGestureAxis: Equatable, Sendable {
    case horizontal
    case vertical
}

enum ViewerDragPhase: Equatable, Sendable {
    case began
    case changed
    case ended
    case cancelled
}

struct ViewerDragEvent: Equatable, Sendable {
    let axis: ViewerGestureAxis
    let phase: ViewerDragPhase
    let translation: CGFloat
    let velocity: CGFloat
}

enum ViewerPageDirection: Int, Equatable, Sendable {
    case previous = -1
    case next = 1
}

struct ViewerPageResolution: Equatable, Sendable {
    let direction: ViewerPageDirection?
    let projectedTranslation: CGFloat
}

struct ViewerSpringParameters: Equatable, Sendable {
    let response: Double
    let dampingRatio: Double

    static let standard = ViewerSpringParameters(response: 0.35, dampingRatio: 1)
    static let momentum = ViewerSpringParameters(response: 0.3, dampingRatio: 0.8)
}

enum ViewerMotionTransition: Equatable, Sendable {
    case spring(ViewerSpringParameters)
    case crossFade(duration: Double)
}

struct ViewerMotionPolicy: Equatable, Sendable {
    let reduceMotion: Bool

    func transition(momentumDriven: Bool) -> ViewerMotionTransition {
        if reduceMotion { return .crossFade(duration: 0.18) }
        return .spring(momentumDriven ? .momentum : .standard)
    }

    func dismissalScale(progress: CGFloat) -> CGFloat {
        reduceMotion ? 1 : 1 - min(max(progress, 0), 1) * 0.1
    }
}

struct ViewerInteractiveTranslation: Equatable, Sendable {
    private(set) var value: CGFloat = 0
    private var gestureOrigin: CGFloat = 0

    mutating func begin(from presentationValue: CGFloat) {
        gestureOrigin = presentationValue
        value = presentationValue
    }

    mutating func update(gestureTranslation: CGFloat) {
        value = gestureOrigin + gestureTranslation
    }

    mutating func settle(at target: CGFloat) {
        value = target
        gestureOrigin = target
    }
}

struct ViewerFrameKey: Hashable, Sendable {
    let assetID: UUID
    let variant: AssetVariant
}

enum ViewerAccessibilityID {
    static let screen = "viewer.screen"
    static let close = "viewer.close"
    static let variantPicker = "viewer.variant"
    static let rate = "viewer.rate"
    static let download = "viewer.download"
    static let info = "viewer.info"
    static let loading = "viewer.loading"
    static let error = "viewer.error"
    static let retry = "viewer.retry"
    static let filmstrip = "viewer.filmstrip"
    static let downloadStatus = "viewer.download.status"
    static let favorite = "viewer.favorite"

    static func media(assetID: UUID) -> String {
        "viewer.media.\(assetID.uuidString.lowercased())"
    }

    static func pageLabel(
        item: ViewerItem,
        rating: AssetRating?,
        index: Int,
        count: Int
    ) -> String {
        "Photo, \(index + 1) of \(count), \(ViewerRatingLabel.text(for: rating))"
    }
}

enum ViewerRatingLabel {
    static func text(for rating: AssetRating?) -> String {
        guard let rating else { return "Unrated" }
        if rating == .rejected { return "Reject" }
        return rating == .one ? "1 Star" : "\(rating.rawValue) Stars"
    }
}
