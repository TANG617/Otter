import SwiftUI

struct FullscreenViewer: View {
    @Environment(\.displayScale) private var displayScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @AccessibilityFocusState private var focusedControl: FocusedControl?

    @State private var state: ViewerPresentationState
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var infoItem: ViewerItem?
    @State private var ratingTasks: [UUID: Task<Void, Never>] = [:]
    @State private var verifiedRatings: [UUID: VerifiedRating] = [:]
    @State private var favoriteTasks: [UUID: Task<Void, Never>] = [:]
    @State private var verifiedFavorites: [UUID: Bool] = [:]
    @State private var downloadCoordinator = ViewerDownloadCoordinator()
    @State private var isChromeVisible = true
    @State private var ratingFailure: PresentationFailure?
    @State private var favoriteFailure: PresentationFailure?
    @State private var viewportSize: CGSize = .zero
    @State private var pageTranslation: CGFloat = 0
    @State private var presentationValues = ViewerPresentationValues()
    @State private var pageGesture = ViewerInteractiveTranslation()
    @State private var dismissalTranslation: CGFloat = 0
    @State private var dismissalGesture = ViewerInteractiveTranslation()
    @State private var dismissalScale: CGFloat = 1
    @State private var backgroundOpacity: CGFloat = 1
    @State private var contentOpacity: CGFloat = 1

    private let actions: ViewerActions
    private let isObscured: Bool
    private let pipeline: any MediaPipelineProtocol
    private let loadMore: @MainActor @Sendable () async -> [ViewerItem]

    init(
        items: [ViewerItem],
        initialAssetID: UUID? = nil,
        initialFrame: MediaFrame? = nil,
        pipeline: any MediaPipelineProtocol,
        isObscured: Bool = false,
        loadMore: @escaping @MainActor @Sendable () async -> [ViewerItem] = { [] },
        actions: ViewerActions
    ) {
        _state = State(
            initialValue: ViewerPresentationState(
                items: items,
                initialAssetID: initialAssetID,
                initialFrame: initialFrame,
                pipeline: pipeline
            )
        )
        self.isObscured = isObscured
        self.pipeline = pipeline
        self.loadMore = loadMore
        self.actions = actions
    }

    var body: some View {
        GeometryReader { proxy in
            viewerContent(size: proxy.size)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .onAppear { start(size: proxy.size) }
                .onChange(of: proxy.size) { _, size in updateViewport(size: size) }
                .onChange(of: displayScale) { _, _ in updateViewport(size: proxy.size) }
                .onChange(of: state.currentIndex) { _, _ in currentItemChanged() }
                .onDisappear(perform: stop)
        }
        .background(viewerBackdrop.ignoresSafeArea())
        .statusBarHidden(!isChromeVisible)
        .presentationBackground(.clear)
        .accessibilityAddTraits(.isModal)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(isObscured)
        .accessibilityIdentifier(ViewerAccessibilityID.screen)
        .accessibilityValue(viewerAccessibilityValue)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            viewerToolbar
        }
        .toolbar(isChromeVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar(isChromeVisible ? .visible : .hidden, for: .bottomBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            filmstripBar
        }
        .sensoryFeedback(.success, trigger: downloadCoordinator.successGeneration)
        .sheet(item: $infoItem) { item in
            ViewerInfoView(item: item, rating: state.rating(for: item.id))
                .accessibilityAddTraits(.isModal)
        }
    }

    private func viewerContent(size: CGSize) -> some View {
        ZStack {
            viewerBackdrop.opacity(backgroundOpacity).ignoresSafeArea()

            if state.items.isEmpty {
                ContentUnavailableView(
                    "No Photos",
                    systemImage: "photo",
                    description: Text("There are no photos to display.")
                )
                .foregroundStyle(.white)
            } else {
                pageStack(size: size)
                    .accessibilityHidden(isObscured || infoItem != nil)
                currentStatus
                    .accessibilityHidden(isObscured || infoItem != nil)
                mutationStatus
                    .accessibilityHidden(isObscured || infoItem != nil)
            }
        }
        .overlay(alignment: .topLeading) {
            if state.items.isEmpty {
                closeButton.padding()
            }
        }
    }

    private var viewerBackdrop: Color {
        isChromeVisible ? Color(uiColor: .systemBackground) : .black
    }

    private func pageStack(size: CGSize) -> some View {
        ZStack {
            ForEach(visiblePageIndices, id: \.self) { index in
                let item = state.items[index]
                ViewerMediaPage(
                    item: item,
                    pageIndex: index,
                    pageCount: state.items.count,
                    rating: state.rating(for: item.id),
                    frame: state.frame(for: item.id),
                    resetGeneration: state.resetGeneration,
                    isCurrent: index == state.currentIndex,
                    isAccessibilityActive: !isObscured
                        && infoItem == nil
                        && index == state.currentIndex,
                    onZoomScaleChanged: { scale in
                        guard state.currentItem?.id == item.id else { return }
                        state.updateZoomScale(scale)
                    },
                    onInteractionChanged: { interaction in
                        guard state.currentItem?.id == item.id else { return }
                        handleInteraction(interaction)
                    },
                    reduceMotion: reduceMotion,
                    onSingleTap: toggleChrome,
                    onDrag: handleDrag
                )
                .offset(x: CGFloat(index - state.currentIndex) * size.width)
                .accessibilityHidden(index != state.currentIndex)
            }
        }
        .offset(x: pageTranslation, y: dismissalTranslation)
        .scaleEffect(dismissalScale)
        .opacity(contentOpacity)
        .modifier(
            ViewerPresentationValueObserver(
                pageTranslation: pageTranslation,
                dismissalTranslation: dismissalTranslation
            ) { page, dismissal in
                presentationValues.pageTranslation = page
                presentationValues.dismissalTranslation = dismissal
            }
        )
        .clipped()
        .ignoresSafeArea()
        .accessibilityAction(named: "Previous Photo") { selectAccessiblePage(-1) }
        .accessibilityAction(named: "Next Photo") { selectAccessiblePage(1) }
    }

    @ToolbarContentBuilder
    private var viewerToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            closeButton
        }

        ToolbarItem(placement: .principal) {
            captureDate
        }

        if let item = state.currentItem {
            ToolbarItem(placement: .topBarTrailing) {
                ViewerTopMoreMenu(
                    selectedVariant: variantSelection,
                    isLoadingVariant: state.isLoadingSelectedVariant,
                    isSelectionDisabled: downloadCoordinator.state.isWorking,
                    onInfo: { infoItem = item }
                )
            }

            ViewerBottomToolbar(
                selectedVariant: variantSelection,
                rating: ratingSelection(for: item),
                isFavorite: favoriteSelection(for: item),
                isLoadingVariant: state.isLoadingSelectedVariant,
                isVariantSelectionDisabled: downloadCoordinator.state.isWorking,
                downloadState: downloadCoordinator.state,
                onInfo: { infoItem = item },
                onDownload: { startDownload(for: item) }
            )
        }
    }

    @ViewBuilder
    private var filmstripBar: some View {
        if isChromeVisible, !state.items.isEmpty {
            ViewerFilmstrip(
                items: state.items,
                currentIndex: state.currentIndex,
                frame: state.frame(for:),
                pipeline: pipeline,
                onSelect: { state.select(index: $0) }
            )
            .frame(height: 60)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(Color(uiColor: .systemBackground))
            .accessibilityHidden(isObscured || infoItem != nil)
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var captureDate: some View {
        if let date = state.currentItem?.captureDate {
            Button {
                infoItem = state.currentItem
            } label: {
                Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
                .accessibilityLabel(date.formatted(date: .long, time: .shortened))
        }
    }

    @ViewBuilder
    private var currentStatus: some View {
        if state.currentFrame == nil, state.isLoadingCurrent {
            ProgressView("Loading Photo")
                .tint(isChromeVisible ? Color.primary : Color.white)
                .foregroundStyle(isChromeVisible ? Color.primary : Color.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background { viewerStatusBackground }
                .overlay { viewerStatusBorder }
                .accessibilityIdentifier(ViewerAccessibilityID.loading)
        } else if let message = state.currentErrorMessage {
            HStack(spacing: 12) {
                Text(message).lineLimit(2)
                Button("Retry") { state.retryCurrent() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(ViewerAccessibilityID.retry)
            }
            .font(.callout)
            .foregroundStyle(isChromeVisible ? Color.primary : Color.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background { viewerStatusBackground }
            .overlay { viewerStatusBorder }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ViewerAccessibilityID.error)
        }
    }

    @ViewBuilder
    private var mutationStatus: some View {
        VStack {
            Spacer()
            if let failure = downloadFailure ?? favoriteFailure ?? ratingFailure {
                HStack(spacing: 10) {
                    Label(failure.title, systemImage: failure.systemImage)
                        .font(.footnote.weight(.semibold))
                    Text(failure.message)
                        .font(.footnote)
                        .lineLimit(2)
                    if downloadFailure != nil {
                        Button("Retry") { retryDownload() }
                            .buttonStyle(.bordered)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 122)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier(ViewerAccessibilityID.downloadStatus)
            }
        }
    }

    private var downloadFailure: PresentationFailure? {
        guard case let .failed(_, failure) = downloadCoordinator.state else { return nil }
        return failure
    }

    @ViewBuilder
    private var viewerStatusBackground: some View {
        if reduceTransparency {
            Capsule().fill(Color(uiColor: .secondarySystemBackground))
        } else {
            Capsule().fill(.ultraThinMaterial)
        }
    }

    @ViewBuilder
    private var viewerStatusBorder: some View {
        if colorSchemeContrast == .increased {
            Capsule().stroke(.primary.opacity(0.75), lineWidth: 1)
        }
    }

    private var closeButton: some View {
        Button(action: actions.onDismiss) {
            Image(systemName: "chevron.left")
        }
        .accessibilityLabel("Close Viewer")
        .accessibilityIdentifier(ViewerAccessibilityID.close)
        .accessibilityFocused($focusedControl, equals: .close)
    }

    private var visiblePageIndices: [Int] {
        guard !state.items.isEmpty else { return [] }
        return Array(max(0, state.currentIndex - 1)...min(state.items.count - 1, state.currentIndex + 1))
    }

    private var pageAccessibilityValue: String {
        "Photo \(min(state.currentIndex + 1, state.items.count)) of \(state.items.count)"
    }

    private var viewerAccessibilityValue: String {
        "\(pageAccessibilityValue), Controls \(isChromeVisible ? "visible" : "hidden")"
    }

    private var variantSelection: Binding<AssetVariant> {
        Binding(
            get: { state.selectedVariant },
            set: {
                guard !downloadCoordinator.state.isWorking else { return }
                downloadCoordinator.resetAfterVariantChange()
                state.selectVariant($0)
            }
        )
    }

    private var motionPolicy: ViewerMotionPolicy {
        ViewerMotionPolicy(reduceMotion: reduceMotion)
    }

    private func start(size: CGSize) {
        updateViewport(size: size)
        state.start()
        notifyCurrentItemChanged()
        loadMoreIfNeeded()
        Task {
            await Task.yield()
            focusedControl = .close
        }
    }

    private func stop() {
        loadMoreTask?.cancel()
        ratingTasks.values.forEach { $0.cancel() }
        ratingTasks.removeAll()
        favoriteTasks.values.forEach { $0.cancel() }
        favoriteTasks.removeAll()
        downloadCoordinator.cancel()
        state.stop()
    }

    private func updateViewport(size: CGSize) {
        viewportSize = size
        state.updateViewport(size: size, displayScale: displayScale)
    }

    private func currentItemChanged() {
        downloadCoordinator.cancel()
        ratingFailure = nil
        favoriteFailure = nil
        notifyCurrentItemChanged()
        loadMoreIfNeeded()
    }

    private func notifyCurrentItemChanged() {
        guard let id = state.currentItem?.id else { return }
        actions.onCurrentItemChanged(id)
    }

    private func handleInteraction(_ interaction: ViewerInteractionState) {
        state.setInteractionState(interaction)
    }

    private func handleDrag(_ event: ViewerDragEvent) {
        switch event.axis {
        case .horizontal: handlePageDrag(event)
        case .vertical: handleDismissDrag(event)
        }
    }

    private func handlePageDrag(_ event: ViewerDragEvent) {
        let width = max(viewportSize.width, 1)
        switch event.phase {
        case .began:
            pageGesture.begin(from: presentationValues.pageTranslation)
            fallthrough
        case .changed:
            pageGesture.update(gestureTranslation: event.translation)
            pageTranslation = reduceMotion ? 0 : ZoomGeometry.pageTranslation(
                pageGesture.value,
                pageWidth: width,
                canGoPrevious: state.currentIndex > 0,
                canGoNext: state.currentIndex + 1 < state.items.count
            )
            if reduceMotion {
                contentOpacity = max(0.65, 1 - abs(event.translation) / width * 0.35)
            }
        case .ended:
            settlePageDrag(event, width: width)
        case .cancelled:
            settlePage(at: 0, velocity: event.velocity)
        }
    }

    private func settlePageDrag(_ event: ViewerDragEvent, width: CGFloat) {
        let resolution = ZoomGeometry.resolvePage(
            translation: pageGesture.value,
            velocity: event.velocity,
            pageWidth: width,
            canGoPrevious: state.currentIndex > 0,
            canGoNext: state.currentIndex + 1 < state.items.count
        )
        guard let direction = resolution.direction else {
            settlePage(at: 0, velocity: event.velocity)
            return
        }
        if reduceMotion {
            crossFade(to: state.currentIndex + direction.rawValue)
            return
        }

        let continuousOffset = pageTranslation + CGFloat(direction.rawValue) * width
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            state.select(
                index: state.currentIndex + direction.rawValue,
                settlesInteractionAutomatically: false
            )
            pageTranslation = continuousOffset
            pageGesture.settle(at: continuousOffset)
        }
        settlePage(at: 0, velocity: event.velocity)
    }

    private func settlePage(at target: CGFloat, velocity: CGFloat) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : springAnimation(
            parameters: .momentum,
            velocity: velocity,
            current: pageTranslation,
            target: target
        )) {
            pageTranslation = target
            contentOpacity = 1
        } completion: {
            state.setInteractionState(.idle)
        }
        pageGesture.settle(at: target)
    }

    private func crossFade(to index: Int) {
        withAnimation(.easeOut(duration: 0.09)) {
            contentOpacity = 0
        } completion: {
            state.select(index: index, settlesInteractionAutomatically: false)
            withAnimation(.easeIn(duration: 0.09)) {
                contentOpacity = 1
            } completion: {
                state.setInteractionState(.idle)
            }
        }
    }

    private func handleDismissDrag(_ event: ViewerDragEvent) {
        let height = max(viewportSize.height, 1)
        switch event.phase {
        case .began:
            dismissalGesture.begin(from: presentationValues.dismissalTranslation)
            fallthrough
        case .changed:
            dismissalGesture.update(gestureTranslation: event.translation)
            let translation = max(dismissalGesture.value, 0)
            let progress = ZoomGeometry.dismissalProgress(
                translation: translation,
                viewportHeight: height
            )
            dismissalTranslation = reduceMotion ? 0 : translation
            dismissalScale = motionPolicy.dismissalScale(progress: progress)
            backgroundOpacity = 1 - progress * 0.82
            contentOpacity = reduceMotion ? 1 - progress * 0.65 : 1
        case .ended:
            if ZoomGeometry.shouldCompleteDismissal(
                translation: max(dismissalGesture.value, 0),
                velocity: event.velocity,
                viewportHeight: height
            ) {
                completeDismissal(height: height, velocity: event.velocity)
            } else {
                cancelDismissal(velocity: event.velocity)
            }
        case .cancelled:
            cancelDismissal(velocity: event.velocity)
        }
    }

    private func completeDismissal(height: CGFloat, velocity: CGFloat) {
        let animation = reduceMotion ? Animation.easeOut(duration: 0.18) : springAnimation(
            parameters: .momentum,
            velocity: velocity,
            current: dismissalTranslation,
            target: height
        )
        withAnimation(animation) {
            dismissalTranslation = reduceMotion ? 0 : max(height, dismissalTranslation)
            dismissalScale = reduceMotion ? 1 : 0.9
            backgroundOpacity = 0
            contentOpacity = 0
        } completion: {
            actions.onDismiss()
        }
    }

    private func cancelDismissal(velocity: CGFloat) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.18) : springAnimation(
            parameters: .momentum,
            velocity: velocity,
            current: dismissalTranslation,
            target: 0
        )) {
            dismissalTranslation = 0
            dismissalScale = 1
            backgroundOpacity = 1
            contentOpacity = 1
        } completion: {
            state.setInteractionState(.idle)
        }
        dismissalGesture.settle(at: 0)
    }

    private func springAnimation(
        parameters: ViewerSpringParameters,
        velocity: CGFloat,
        current: CGFloat,
        target: CGFloat
    ) -> Animation {
        let frequency = 2 * Double.pi / parameters.response
        let relativeVelocity = abs(target - current) > 0.001
            ? Double(velocity / (target - current))
            : 0
        return .interpolatingSpring(
            mass: 1,
            stiffness: frequency * frequency,
            damping: 2 * parameters.dampingRatio * frequency,
            initialVelocity: relativeVelocity
        )
    }

    private func toggleChrome() {
        isChromeVisible.toggle()
    }

    private func selectAccessiblePage(_ delta: Int) {
        let index = state.currentIndex + delta
        guard state.items.indices.contains(index) else { return }
        state.select(index: index)
    }

    private func loadMoreIfNeeded() {
        guard state.currentIndex >= max(0, state.items.count - 3),
              loadMoreTask == nil else { return }
        loadMoreTask = Task {
            let additional = await loadMore()
            guard !Task.isCancelled else { return }
            state.append(additional)
            loadMoreTask = nil
        }
    }

    private func ratingSelection(for item: ViewerItem) -> Binding<AssetRating?> {
        Binding(
            get: { state.rating(for: item.id) },
            set: { rating in
                ratingFailure = nil
                let previous = state.rating(for: item.id)
                if verifiedRatings[item.id] == nil {
                    verifiedRatings[item.id] = VerifiedRating(value: previous)
                }
                state.setRating(rating, for: item.id)
                let predecessor = ratingTasks[item.id]
                ratingTasks[item.id] = Task {
                    await predecessor?.value
                    guard !Task.isCancelled else { return }
                    let verifiedBeforeRequest = verifiedRatings[item.id]?.value ?? previous
                    let outcome = await actions.onRate(item, rating)
                    guard !Task.isCancelled else { return }
                    let isLatestOptimisticValue = state.rating(for: item.id) == rating
                    switch outcome {
                    case let .verified(verified):
                        verifiedRatings[item.id] = VerifiedRating(value: verified)
                        if isLatestOptimisticValue {
                            state.setRating(verified, for: item.id)
                        }
                    case .failed where isLatestOptimisticValue:
                        state.setRating(verifiedBeforeRequest, for: item.id)
                        ratingFailure = PresentationFailure(
                            title: "Rating Failed",
                            message: "The previous rating was restored."
                        )
                    case .failed:
                        break
                    }
                }
            }
        )
    }

    private func favoriteSelection(for item: ViewerItem) -> Binding<Bool> {
        Binding(
            get: { state.isFavorite(item.id) },
            set: { isFavorite in
                favoriteFailure = nil
                let previous = state.isFavorite(item.id)
                if verifiedFavorites[item.id] == nil {
                    verifiedFavorites[item.id] = previous
                }
                state.setFavorite(isFavorite, for: item.id)
                let predecessor = favoriteTasks[item.id]
                favoriteTasks[item.id] = Task {
                    await predecessor?.value
                    guard !Task.isCancelled else { return }
                    let verifiedBeforeRequest = verifiedFavorites[item.id] ?? previous
                    let outcome = await actions.onFavorite(item, isFavorite)
                    guard !Task.isCancelled else { return }
                    let isLatestOptimisticValue = state.isFavorite(item.id) == isFavorite
                    switch outcome {
                    case let .verified(verified):
                        verifiedFavorites[item.id] = verified
                        if isLatestOptimisticValue {
                            state.setFavorite(verified, for: item.id)
                        }
                    case .failed where isLatestOptimisticValue:
                        state.setFavorite(verifiedBeforeRequest, for: item.id)
                        favoriteFailure = PresentationFailure(
                            title: "Favourite Failed",
                            message: "The previous Favourite state was restored.",
                            systemImage: "heart.slash"
                        )
                    case .failed:
                        break
                    }
                }
            }
        )
    }

    private func startDownload(for item: ViewerItem) {
        downloadCoordinator.start(
            item: item,
            variant: state.selectedVariant,
            perform: actions.onDownload,
            currentAssetID: { state.currentItem?.id }
        )
    }

    private func retryDownload() {
        downloadCoordinator.retry(
            perform: actions.onDownload,
            currentAssetID: { state.currentItem?.id }
        )
    }

    private enum FocusedControl: Hashable {
        case close
    }

    private struct VerifiedRating {
        let value: AssetRating?
    }
}

private struct ViewerMediaPage: View {
    let item: ViewerItem
    let pageIndex: Int
    let pageCount: Int
    let rating: AssetRating?
    let frame: MediaFrame?
    let resetGeneration: Int
    let isCurrent: Bool
    let isAccessibilityActive: Bool
    let onZoomScaleChanged: (CGFloat) -> Void
    let onInteractionChanged: (ViewerInteractionState) -> Void
    let reduceMotion: Bool
    let onSingleTap: () -> Void
    let onDrag: (ViewerDragEvent) -> Void

    var body: some View {
        ZoomingMediaSurface(
            surface: frame?.surface,
            accessibilityLabel: ViewerAccessibilityID.pageLabel(
                item: item,
                rating: rating,
                index: pageIndex,
                count: pageCount
            ),
            accessibilityIdentifier: ViewerAccessibilityID.media(assetID: item.id),
            isAccessibilityActive: isAccessibilityActive,
            resetGeneration: resetGeneration,
            onZoomScaleChanged: isCurrent ? onZoomScaleChanged : { _ in },
            onInteractionChanged: isCurrent ? onInteractionChanged : { _ in },
            reduceMotion: reduceMotion,
            onSingleTap: isCurrent ? onSingleTap : {},
            onDrag: isCurrent ? onDrag : { _ in }
        )
        .background(Color.clear)
    }
}

private struct ViewerInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var isDoneFocused: Bool

    let item: ViewerItem
    let rating: AssetRating?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(item.descriptor.originalFilename ?? "Photo")
                        .font(.headline)

                    if let date = item.captureDate {
                        Text(date, format: .dateTime.year().month(.wide).day().hour().minute())
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        if let dimensionsLine {
                            Text(dimensionsLine)
                        }
                        Text(item.descriptor.hasEdits ? "Current Version · includes server edits" : "Current Version · optimized for viewing")
                            .foregroundStyle(.secondary)
                        Text("Original · requested on demand")
                            .foregroundStyle(.secondary)
                        Text("Rating · \(ViewerRatingLabel.text(for: rating))")
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color(uiColor: .secondarySystemBackground),
                        in: RoundedRectangle(cornerRadius: 28, style: .continuous)
                    )
                }
                .padding()
                .frame(maxWidth: 920, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close Info")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel("Done")
                        .accessibilityFocused($isDoneFocused)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .task {
            await Task.yield()
            isDoneFocused = true
        }
    }

    private var dimensionsLine: String? {
        guard let width = item.descriptor.originalWidth,
              let height = item.descriptor.originalHeight else { return nil }
        let megapixels = Double(width * height) / 1_000_000
        let mediaType = item.descriptor.originalMimeType?
            .split(separator: "/")
            .last?
            .uppercased()
        return [
            "\(width) × \(height)",
            megapixels.formatted(.number.precision(.fractionLength(0...1))) + " MP",
            mediaType
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }
}

@MainActor
private final class ViewerPresentationValues {
    var pageTranslation: CGFloat = 0
    var dismissalTranslation: CGFloat = 0
}

private struct ViewerPresentationValueObserver: @preconcurrency AnimatableModifier {
    var pageTranslation: CGFloat
    var dismissalTranslation: CGFloat
    let onChange: @MainActor @Sendable (CGFloat, CGFloat) -> Void

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(pageTranslation, dismissalTranslation) }
        set {
            pageTranslation = newValue.first
            dismissalTranslation = newValue.second
            let page = pageTranslation
            let dismissal = dismissalTranslation
            let callback = onChange
            DispatchQueue.main.async {
                callback(page, dismissal)
            }
        }
    }

    func body(content: Content) -> some View {
        content
    }
}
