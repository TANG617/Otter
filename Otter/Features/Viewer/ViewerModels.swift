import Foundation
import Observation

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

struct ViewerDownloadRequest: Equatable, Sendable {
    let assetID: UUID
    let variant: AssetVariant
    let token: UUID
}

enum ViewerDownloadState: Equatable, Sendable {
    case idle
    case working(ViewerDownloadRequest)
    case completed(ViewerDownloadRequest)
    case failed(ViewerDownloadRequest, PresentationFailure)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

@MainActor
@Observable
final class ViewerDownloadCoordinator {
    typealias Perform = @MainActor @Sendable (ViewerItem, AssetVariant) async -> ActionOutcome
    typealias CurrentAssetID = @MainActor @Sendable () -> UUID?

    private(set) var state: ViewerDownloadState = .idle
    private(set) var successGeneration = 0

    private var task: Task<Void, Never>?
    private var retryItem: ViewerItem?

    func start(
        item: ViewerItem,
        variant: AssetVariant,
        perform: @escaping Perform,
        currentAssetID: @escaping CurrentAssetID
    ) {
        guard !state.isWorking else { return }
        let request = ViewerDownloadRequest(
            assetID: item.id,
            variant: variant,
            token: UUID()
        )
        retryItem = nil
        state = .working(request)
        task = Task { [weak self] in
            let outcome = await perform(item, request.variant)
            guard !Task.isCancelled else { return }
            self?.finish(
                outcome,
                request: request,
                item: item,
                isCurrent: currentAssetID() == request.assetID
            )
        }
    }

    func retry(
        perform: @escaping Perform,
        currentAssetID: @escaping CurrentAssetID
    ) {
        guard case let .failed(request, _) = state,
              let retryItem,
              retryItem.id == request.assetID,
              currentAssetID() == request.assetID else { return }
        state = .idle
        start(
            item: retryItem,
            variant: request.variant,
            perform: perform,
            currentAssetID: currentAssetID
        )
    }

    func resetAfterVariantChange() {
        guard !state.isWorking else { return }
        retryItem = nil
        state = .idle
    }

    func cancel() {
        task?.cancel()
        task = nil
        retryItem = nil
        state = .idle
    }

    private func finish(
        _ outcome: ActionOutcome,
        request: ViewerDownloadRequest,
        item: ViewerItem,
        isCurrent: Bool
    ) {
        guard case let .working(activeRequest) = state,
              activeRequest == request else { return }
        task = nil
        guard isCurrent else {
            retryItem = nil
            state = .idle
            return
        }
        switch outcome {
        case .success:
            retryItem = nil
            state = .completed(request)
            successGeneration &+= 1
        case let .failure(failure):
            retryItem = item
            state = .failed(request, failure)
        }
    }
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
        if rating == .rejected { return "Rejected" }
        return rating == .one ? "1 Star" : "\(rating.rawValue) Stars"
    }
}
