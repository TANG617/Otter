import SwiftUI

struct FullscreenViewer: View {
    @Environment(\.displayScale) private var displayScale
    @State private var state: ViewerPresentationState
    @State private var loadMoreTask: Task<Void, Never>?
    @State private var infoItem: ViewerItem?
    @State private var ratingTasks: [UUID: Task<Void, Never>] = [:]

    private let actions: ViewerActions
    private let loadMore: @MainActor @Sendable () async -> [ViewerItem]

    init(
        items: [ViewerItem],
        initialAssetID: UUID? = nil,
        initialFrame: MediaFrame? = nil,
        pipeline: any MediaPipelineProtocol,
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
        self.loadMore = loadMore
        self.actions = actions
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if state.items.isEmpty {
                    ContentUnavailableView(
                        "No Photos",
                        systemImage: "photo",
                        description: Text("There are no photos to display.")
                    )
                    .foregroundStyle(.white)
                } else {
                    pages
                    controls
                }
            }
            .onAppear {
                state.updateViewport(size: proxy.size, displayScale: displayScale)
                state.start()
                loadMoreIfNeeded()
            }
            .onChange(of: proxy.size) { _, size in
                state.updateViewport(size: size, displayScale: displayScale)
            }
            .onChange(of: displayScale) { _, scale in
                state.updateViewport(size: proxy.size, displayScale: scale)
            }
            .onChange(of: state.currentIndex) { _, _ in
                loadMoreIfNeeded()
            }
            .onDisappear {
                loadMoreTask?.cancel()
                ratingTasks.values.forEach { $0.cancel() }
                ratingTasks.removeAll()
                state.stop()
            }
        }
        .overlay(alignment: .topTrailing) {
            if state.items.isEmpty {
                closeButton
                    .padding()
            }
        }
        .background(Color.black)
        .statusBarHidden()
        .sheet(item: $infoItem) { item in
            ViewerInfoView(item: item, rating: state.rating(for: item.id))
        }
    }

    private var pages: some View {
        TabView(selection: pageSelection) {
            ForEach(state.items.indices, id: \.self) { index in
                let item = state.items[index]
                ViewerPage(
                    item: item,
                    pageIndex: index,
                    pageCount: state.items.count,
                    rating: state.rating(for: item.id),
                    frame: state.frame(for: item.id),
                    resetGeneration: state.resetGeneration,
                    isCurrent: index == state.currentIndex,
                    onZoomScaleChanged: { scale in
                        guard state.currentItem?.id == item.id else { return }
                        state.updateZoomScale(scale)
                    },
                    onInteractionChanged: { interaction in
                        guard state.currentItem?.id == item.id else { return }
                        state.setInteractionState(interaction)
                    }
                )
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack {
                closeButton
                Spacer()
                settingsButton
            }

            Spacer()

            currentStatus

            if let item = state.currentItem {
                ViewerBottomControls(
                    selectedVariant: variantSelection,
                    rating: ratingSelection(for: item),
                    canGoPrevious: state.currentIndex > 0,
                    canGoNext: state.currentIndex + 1 < state.items.count,
                    isLoadingVariant: state.isLoadingSelectedVariant,
                    onPrevious: { state.select(index: state.currentIndex - 1) },
                    onNext: { state.select(index: state.currentIndex + 1) },
                    onFit: { state.requestFit() },
                    onInfo: { infoItem = item },
                    onDownload: { actions.onExport(item, state.selectedVariant) }
                )
            }
        }
        .padding()
    }

    @ViewBuilder
    private var currentStatus: some View {
        if state.currentFrame == nil, state.isLoadingCurrent {
            ProgressView("Loading Photo")
                .tint(.white)
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .accessibilityIdentifier(ViewerAccessibilityID.loading)
        } else if let message = state.currentErrorMessage {
            HStack(spacing: 12) {
                Text(message)
                    .lineLimit(2)
                Button("Retry") {
                    state.retryCurrent()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(ViewerAccessibilityID.retry)
            }
            .font(.callout)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ViewerAccessibilityID.error)
        }
    }

    private var closeButton: some View {
        ViewerIconButton(
            title: "Close Viewer",
            systemImage: "xmark",
            accessibilityIdentifier: ViewerAccessibilityID.close,
            action: actions.onDismiss
        )
    }

    private var settingsButton: some View {
        ViewerIconButton(
            title: "Open Settings",
            systemImage: "gearshape",
            accessibilityIdentifier: ViewerAccessibilityID.settings,
            action: actions.onSettings
        )
    }

    private var pageSelection: Binding<Int> {
        Binding(
            get: { state.currentIndex },
            set: { state.select(index: $0) }
        )
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

    private var variantSelection: Binding<AssetVariant> {
        Binding(
            get: { state.selectedVariant },
            set: { state.selectVariant($0) }
        )
    }

    private func ratingSelection(for item: ViewerItem) -> Binding<AssetRating?> {
        Binding(
            get: { state.rating(for: item.id) },
            set: { rating in
                let previous = state.rating(for: item.id)
                state.setRating(rating, for: item.id)
                let predecessor = ratingTasks[item.id]
                ratingTasks[item.id] = Task {
                    await predecessor?.value
                    guard !Task.isCancelled else { return }
                    let outcome = await actions.onRate(item, rating)
                    guard state.rating(for: item.id) == rating else { return }
                    switch outcome {
                    case let .verified(verified):
                        state.setRating(verified, for: item.id)
                    case .failed:
                        state.setRating(previous, for: item.id)
                    }
                }
            }
        )
    }
}

private struct ViewerInfoView: View {
    @Environment(\.dismiss) private var dismiss

    let item: ViewerItem
    let rating: AssetRating?

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo") {
                    if let filename = item.descriptor.originalFilename {
                        LabeledContent("Filename", value: filename)
                    }
                    if let width = item.descriptor.originalWidth,
                       let height = item.descriptor.originalHeight {
                        LabeledContent("Dimensions", value: "\(width) × \(height)")
                    }
                    if let mimeType = item.descriptor.originalMimeType {
                        LabeledContent("Media Type", value: mimeType)
                    }
                    LabeledContent("Edited", value: item.descriptor.hasEdits ? "Yes" : "No")
                    LabeledContent("Rating", value: ViewerRatingLabel.text(for: rating))
                }

                Section("Identity") {
                    LabeledContent("Asset ID", value: item.id.uuidString.lowercased())
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
