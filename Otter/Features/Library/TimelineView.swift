import SwiftUI

struct TimelineViewerWindow: Sendable {
    let assets: [TimelineAsset]
    let loadMore: @MainActor @Sendable () async -> [TimelineAsset]
}

enum TimelineGridLayout {
    static let spacing: CGFloat = 1

    static func columnCount(for width: CGFloat) -> Int {
        max(3, min(10, Int(width / 104)))
    }

    static func columns(for width: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: spacing),
            count: columnCount(for: width)
        )
    }

    static func cellSide(for width: CGFloat) -> CGFloat {
        let count = CGFloat(columnCount(for: width))
        return max((width - spacing * (count - 1)) / count, 1)
    }
}

@MainActor
struct TimelineView: View {
    typealias LoadMore = @MainActor @Sendable () async -> [TimelineAsset]
    typealias Selection = @MainActor (TimelineAsset, MediaFrame?, TimelineViewerWindow) -> Void
    typealias SettingsAction = @MainActor () -> Void

    @State private var state: TimelineState
    @State private var prefetchController: TimelinePrefetchController

    private let mediaClient: TimelineMediaClient
    private let calendar: Calendar
    private let updatedAsset: TimelineAsset?
    private let onSelectAsset: Selection
    private let onOpenSettings: SettingsAction

    init(
        accountNamespace: UUID,
        assetStore: any AssetStore,
        mediaPipeline: any MediaPipelineProtocol,
        pageSize: Int = 200,
        calendar: Calendar = .autoupdatingCurrent,
        updatedAsset: TimelineAsset? = nil,
        onSelectAsset: @escaping Selection,
        onOpenSettings: @escaping SettingsAction
    ) {
        let mediaClient = TimelineMediaClient(pipeline: mediaPipeline)
        _state = State(
            initialValue: TimelineState(
                accountNamespace: accountNamespace,
                dataClient: TimelineDataClient(store: assetStore),
                pageSize: pageSize,
                calendar: calendar
            )
        )
        _prefetchController = State(
            initialValue: TimelinePrefetchController(mediaClient: mediaClient)
        )
        self.mediaClient = mediaClient
        self.calendar = calendar
        self.updatedAsset = updatedAsset
        self.onSelectAsset = onSelectAsset
        self.onOpenSettings = onOpenSettings
    }

    init(
        accountNamespace: UUID,
        dataClient: TimelineDataClient,
        mediaClient: TimelineMediaClient,
        pageSize: Int = 200,
        calendar: Calendar = .autoupdatingCurrent,
        updatedAsset: TimelineAsset? = nil,
        onSelectAsset: @escaping Selection,
        onOpenSettings: @escaping SettingsAction
    ) {
        _state = State(
            initialValue: TimelineState(
                accountNamespace: accountNamespace,
                dataClient: dataClient,
                pageSize: pageSize,
                calendar: calendar
            )
        )
        _prefetchController = State(
            initialValue: TimelinePrefetchController(mediaClient: mediaClient)
        )
        self.mediaClient = mediaClient
        self.calendar = calendar
        self.updatedAsset = updatedAsset
        self.onSelectAsset = onSelectAsset
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .navigationTitle("Library")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Settings", systemImage: "gearshape", action: onOpenSettings)
                    .accessibilityIdentifier(TimelineAccessibilityID.settings)
            }
        }
        .task {
            await state.loadIfNeeded()
        }
        .onChange(of: updatedAsset) { _, asset in
            if let asset { state.applyVerifiedUpdate(asset) }
        }
        .onDisappear {
            prefetchController.cancel()
        }
    }

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch state.contentState {
        case .idle, .loading:
            LoadingStateView(
                "Loading Library",
                message: "Preparing your timeline.",
                accessibilityIdentifier: TimelineAccessibilityID.loading
            )

        case let .failed(failure):
            FailureStateView(
                failure: failure,
                retryTitle: "Retry",
                accessibilityIdentifier: TimelineAccessibilityID.failure
            ) {
                Task { await state.retry() }
            }

        case .loaded where state.assets.isEmpty && state.isRefreshing:
            LoadingStateView(
                "Refreshing Library",
                message: "Looking for your photos.",
                accessibilityIdentifier: TimelineAccessibilityID.loading
            )

        case .loaded where state.assets.isEmpty:
            ScrollView {
                EmptyStateView(
                    "No Photos",
                    systemImage: "photo.stack",
                    message: "Photos from your Immich library will appear here.",
                    accessibilityIdentifier: TimelineAccessibilityID.empty
                )
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
            }
            .refreshable {
                await state.refresh()
            }

        case .loaded:
            timeline(width: width)
        }
    }

    private func timeline(width: CGFloat) -> some View {
        let columns = TimelineGridLayout.columns(for: width)

        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                if let refreshFailure = state.refreshFailure {
                    refreshFailureBanner(refreshFailure)
                }

                ForEach(state.sections) { section in
                    Section {
                        LazyVGrid(columns: columns, spacing: TimelineGridLayout.spacing) {
                            ForEach(section.assets) { asset in
                                TimelineMediaCell(
                                    asset: asset,
                                    index: state.assetIndices[asset.id] ?? 0,
                                    mediaClient: mediaClient,
                                    calendar: calendar,
                                    onSelect: { asset, frame in
                                        onSelectAsset(
                                            asset,
                                            frame,
                                            TimelineViewerWindow(assets: state.assets) {
                                                await state.loadMore()
                                                return state.assets
                                            }
                                        )
                                    },
                                    onVisible: updatePrefetch
                                )
                            }
                        }
                    } header: {
                        sectionHeader(section)
                    }
                }

                paginationFooter
            }
        }
        .refreshable {
            await state.refresh()
        }
    }

    private func sectionHeader(_ section: TimelineSection) -> some View {
        HStack {
            Text(section.day, format: .dateTime.weekday(.wide).month(.wide).day().year())
                .font(.headline)
            Spacer()
            Text(
                section.id == state.sections.last?.id && state.canLoadMore
                    ? "\(section.assets.count)+"
                    : "\(section.assets.count)"
            )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(TimelineAccessibilityID.section(day: section.day, calendar: calendar))
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if let failure = state.paginationFailure {
            VStack(spacing: 8) {
                Label(failure.title, systemImage: failure.systemImage)
                    .font(.subheadline)
                Button("Retry") {
                    Task { await state.loadMore() }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(TimelineAccessibilityID.retry)
            }
            .padding()
        } else if state.canLoadMore {
            ProgressView()
                .padding(24)
                .frame(maxWidth: .infinity)
                .accessibilityIdentifier(TimelineAccessibilityID.loadMore)
                .task(id: state.nextCursor) {
                    await state.loadMore()
                }
        }
    }

    private func refreshFailureBanner(_ failure: PresentationFailure) -> some View {
        HStack(spacing: 10) {
            Image(systemName: failure.systemImage)
            Text(failure.message)
                .font(.footnote)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Retry") {
                Task { await state.refresh() }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(10)
        .background(.thinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TimelineAccessibilityID.refreshFailure)
    }

    private func updatePrefetch(index: Int, cellSide: Double, displayScale: Double) {
        prefetchController.update(
            assets: state.assets,
            anchorIndex: index,
            cellSide: cellSide,
            displayScale: displayScale
        )
    }
}
