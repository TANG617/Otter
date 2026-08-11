import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
final class ViewerPresentationState {
    private(set) var items: [ViewerItem]

    private let pipeline: any MediaPipelineProtocol
    private var frameTasks: [ViewerFrameKey: Task<Void, Never>] = [:]
    private var requestTokens: [ViewerFrameKey: UUID] = [:]
    private var edgePrefetch: PrefetchToken?
    private var frames: [ViewerFrameKey: MediaFrame] = [:]
    private var displayedFrames: [UUID: MediaFrame] = [:]
    private var displayedVariants: [UUID: AssetVariant] = [:]
    private var pendingFrames: [ViewerFrameKey: MediaFrame] = [:]
    private var errors: [ViewerFrameKey: String] = [:]
    private var ratings: [UUID: AssetRating]
    private var favorites: [UUID: Bool]
    private var explicitRetries: Set<ViewerFrameKey> = []
    private var isStarted = false
    private var viewport = PixelSize(width: 0, height: 0)
    private var displayScale = 1.0

    private(set) var currentIndex: Int
    private(set) var selectedVariant: AssetVariant = .current
    private(set) var interactionState: ViewerInteractionState = .idle
    private(set) var zoomScale = 1.0
    private(set) var resetGeneration = 0
    private(set) var activeRequests: [ViewerFrameKey: MediaRequest] = [:]

    init(
        items: [ViewerItem],
        initialAssetID: UUID? = nil,
        initialFrame: MediaFrame? = nil,
        pipeline: any MediaPipelineProtocol
    ) {
        self.items = items
        self.pipeline = pipeline
        ratings = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.rating.map { (item.id, $0) }
        })
        favorites = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0.isFavorite) })
        currentIndex = initialAssetID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        if let initialFrame, items.indices.contains(currentIndex) {
            let item = items[currentIndex]
            let key = ViewerFrameKey(assetID: item.id, variant: .current)
            frames[key] = initialFrame
            displayedFrames[item.id] = initialFrame
            displayedVariants[item.id] = .current
        }
    }

    var currentItem: ViewerItem? {
        items.indices.contains(currentIndex) ? items[currentIndex] : nil
    }

    var currentFrame: MediaFrame? {
        currentItem.flatMap { displayedFrames[$0.id] }
    }

    var displayedVariant: AssetVariant? {
        currentItem.flatMap { displayedVariants[$0.id] }
    }

    var currentErrorMessage: String? {
        guard let currentItem else { return nil }
        return errors[ViewerFrameKey(assetID: currentItem.id, variant: selectedVariant)]
    }

    var isLoadingCurrent: Bool {
        guard let item = currentItem else { return false }
        let key = ViewerFrameKey(assetID: item.id, variant: selectedVariant)
        return frames[key]?.containsRealMedia != true && errors[key] == nil
    }

    var isLoadingSelectedVariant: Bool {
        guard let item = currentItem else { return false }
        let key = ViewerFrameKey(assetID: item.id, variant: selectedVariant)
        return frames[key]?.containsRealMedia != true && errors[key] == nil
    }

    var retainedFrameCount: Int { frames.count }

    func frame(for assetID: UUID) -> MediaFrame? {
        displayedFrames[assetID]
    }

    func rating(for assetID: UUID) -> AssetRating? {
        ratings[assetID]
    }

    func isFavorite(_ assetID: UUID) -> Bool {
        favorites[assetID] ?? false
    }

    func setRating(_ rating: AssetRating?, for assetID: UUID) {
        guard items.contains(where: { $0.id == assetID }) else { return }
        ratings[assetID] = rating
    }

    func setFavorite(_ isFavorite: Bool, for assetID: UUID) {
        guard items.contains(where: { $0.id == assetID }) else { return }
        favorites[assetID] = isFavorite
    }

    func append(_ incoming: [ViewerItem]) {
        var known = Set(items.map(\.id))
        let additions = incoming.filter { known.insert($0.id).inserted }
        guard !additions.isEmpty else { return }
        items.append(contentsOf: additions)
        for item in additions {
            if let rating = item.rating { ratings[item.id] = rating }
            favorites[item.id] = item.isFavorite
        }
        reconcileRequests()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        reconcileRequests()
    }

    func stop() {
        isStarted = false
        frameTasks.values.forEach { $0.cancel() }
        edgePrefetch?.cancel()
        edgePrefetch = nil
        frameTasks.removeAll()
        requestTokens.removeAll()
        activeRequests.removeAll()
    }

    func updateViewport(size: CGSize, displayScale: CGFloat) {
        let next = PixelSize(width: max(size.width, 0), height: max(size.height, 0))
        let nextScale = max(Double(displayScale), 1)
        guard viewport != next || self.displayScale != nextScale else { return }
        viewport = next
        self.displayScale = nextScale
        reconcileRequests()
    }

    func select(index: Int, settlesInteractionAutomatically: Bool = true) {
        guard items.indices.contains(index), index != currentIndex else { return }
        interactionState = .paging
        currentIndex = index
        zoomScale = 1
        resetGeneration &+= 1
        showCachedSelectedVariantIfAvailable()
        reconcileRequests()
        guard settlesInteractionAutomatically else { return }
        Task { [weak self] in
            await Task.yield()
            guard let self, self.interactionState == .paging else { return }
            self.setInteractionState(.idle)
        }
    }

    func selectVariant(_ variant: AssetVariant) {
        guard selectedVariant != variant else { return }
        selectedVariant = variant
        showCachedSelectedVariantIfAvailable()
        reconcileRequests()
    }

    func updateZoomScale(_ scale: CGFloat) {
        zoomScale = Double(ZoomGeometry.clampedZoomScale(scale))
    }

    func setInteractionState(_ state: ViewerInteractionState) {
        guard interactionState != state else { return }
        interactionState = state
        if state == .idle {
            applyPendingCurrentFrame()
            reconcileRequests()
        }
    }

    func requestFit() {
        zoomScale = 1
        resetGeneration &+= 1
        reconcileRequests()
    }

    func retryCurrent() {
        guard let currentItem else { return }
        let key = ViewerFrameKey(assetID: currentItem.id, variant: selectedVariant)
        errors.removeValue(forKey: key)
        frameTasks.removeValue(forKey: key)?.cancel()
        requestTokens.removeValue(forKey: key)
        activeRequests.removeValue(forKey: key)
        explicitRetries.insert(key)
        reconcileRequests()
    }

    private func reconcileRequests() {
        guard isStarted,
              viewport.width > 0,
              viewport.height > 0,
              items.indices.contains(currentIndex) else {
            return
        }

        let lower = max(0, currentIndex - 1)
        let upper = min(items.count - 1, currentIndex + 1)
        var desired: [ViewerFrameKey: MediaRequest] = [:]
        for index in lower...upper {
            let isCurrent = index == currentIndex
            let variant = isCurrent ? selectedVariant : AssetVariant.current
            let key = ViewerFrameKey(assetID: items[index].id, variant: variant)
            desired[key] = makeRequest(for: items[index], isCurrent: isCurrent, variant: variant)
        }
        pruneFrames(retaining: desired.keys)

        for (key, request) in desired where activeRequests[key] != request {
            let oldTask = frameTasks[key]
            let stream = explicitRetries.remove(key) != nil
                ? pipeline.retryFrames(for: request)
                : pipeline.frames(for: request)
            let requestToken = UUID()
            activeRequests[key] = request
            requestTokens[key] = requestToken
            frameTasks[key] = Task { [weak self] in
                do {
                    for try await frame in stream {
                        guard !Task.isCancelled else { return }
                        self?.receive(frame, key: key)
                    }
                    self?.finishRequest(
                        key: key,
                        request: request,
                        token: requestToken,
                        error: nil
                    )
                } catch is CancellationError {
                    self?.finishRequest(
                        key: key,
                        request: request,
                        token: requestToken,
                        error: nil
                    )
                } catch {
                    self?.finishRequest(
                        key: key,
                        request: request,
                        token: requestToken,
                        error: "This photo is unavailable."
                    )
                }
            }
            oldTask?.cancel()
        }

        let obsolete = Set(activeRequests.keys).subtracting(desired.keys)
        for key in obsolete {
            activeRequests.removeValue(forKey: key)
            requestTokens.removeValue(forKey: key)
            frameTasks.removeValue(forKey: key)?.cancel()
        }
        prefetchTwoAway()
    }

    private func makeRequest(
        for item: ViewerItem,
        isCurrent: Bool,
        variant: AssetVariant,
        priority: MediaPriority? = nil
    ) -> MediaRequest {
        let isZoomed = isCurrent && zoomScale > 1.05
        let purpose: MediaPurpose = isCurrent ? (isZoomed ? .zoom : .viewer) : .timeline
        return MediaRequest(
            asset: item.descriptor,
            variant: variant,
            purpose: purpose,
            viewport: viewport,
            displayScale: displayScale,
            zoomScale: isZoomed ? zoomScale : 1,
            qualityPolicy: isCurrent ? .maximum : .balanced,
            dynamicRange: .standard,
            contentMode: .aspectFit,
            priority: priority ?? (isCurrent ? .interactive : .neighbor)
        )
    }

    private func prefetchTwoAway() {
        edgePrefetch?.cancel()
        let indices = [currentIndex - 2, currentIndex + 2].filter(items.indices.contains)
        let requests = indices.map { index in
            makeRequest(
                for: items[index],
                isCurrent: false,
                variant: .current,
                priority: .prefetch
            )
        }
        edgePrefetch = requests.isEmpty ? nil : pipeline.prefetch(requests)
    }

    private func receive(_ frame: MediaFrame, key: ViewerFrameKey) {
        if let existing = frames[key] {
            if existing.quality > frame.quality { return }
            if existing.quality == frame.quality,
               max(existing.surface.pixelWidth, existing.surface.pixelHeight)
                >= max(frame.surface.pixelWidth, frame.surface.pixelHeight) {
                return
            }
        }
        frames[key] = frame
        if frame.containsRealMedia {
            errors.removeValue(forKey: key)
        }

        let isSelectedCurrent = currentItem?.id == key.assetID && selectedVariant == key.variant
        if isSelectedCurrent,
           interactionState != .idle,
           displayedFrames[key.assetID] != nil {
            pendingFrames[key] = frame
            return
        }

        if isSelectedCurrent || displayedFrames[key.assetID] == nil || key.variant == .current {
            displayedFrames[key.assetID] = frame
            displayedVariants[key.assetID] = key.variant
        }
    }

    private func finishRequest(
        key: ViewerFrameKey,
        request: MediaRequest,
        token: UUID,
        error: String?
    ) {
        guard activeRequests[key] == request,
              requestTokens[key] == token else { return }
        activeRequests.removeValue(forKey: key)
        requestTokens.removeValue(forKey: key)
        frameTasks.removeValue(forKey: key)
        if frames[key]?.containsRealMedia != true {
            errors[key] = error ?? "This photo is unavailable."
        }
    }

    private func showCachedSelectedVariantIfAvailable() {
        guard let item = currentItem else { return }
        let key = ViewerFrameKey(assetID: item.id, variant: selectedVariant)
        if let frame = frames[key] {
            displayedFrames[item.id] = frame
            displayedVariants[item.id] = selectedVariant
        }
    }

    private func applyPendingCurrentFrame() {
        guard let item = currentItem else { return }
        let key = ViewerFrameKey(assetID: item.id, variant: selectedVariant)
        guard let frame = pendingFrames.removeValue(forKey: key) else { return }
        displayedFrames[item.id] = frame
        displayedVariants[item.id] = selectedVariant
    }

    private func pruneFrames(retaining desiredKeys: Dictionary<ViewerFrameKey, MediaRequest>.Keys) {
        var retainedKeys = Set(desiredKeys)
        if selectedVariant == .original, let currentItem {
            retainedKeys.insert(ViewerFrameKey(assetID: currentItem.id, variant: .current))
        }
        let retainedAssetIDs = Set(retainedKeys.map(\.assetID))
        frames = frames.filter { retainedKeys.contains($0.key) }
        pendingFrames = pendingFrames.filter { retainedKeys.contains($0.key) }
        errors = errors.filter { retainedKeys.contains($0.key) }
        displayedFrames = displayedFrames.filter { retainedAssetIDs.contains($0.key) }
        displayedVariants = displayedVariants.filter { retainedAssetIDs.contains($0.key) }
    }
}
