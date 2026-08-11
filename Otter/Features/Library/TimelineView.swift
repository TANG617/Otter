import SwiftUI

struct TimelineViewerWindow: Sendable {
    let assets: [TimelineAsset]
    let loadMore: @MainActor @Sendable () async -> [TimelineAsset]
}

enum TimelineGridLayout {
    static let spacing: CGFloat = 1

    static func columnCount(for width: CGFloat) -> Int {
        switch width {
        case 1_100...: 7
        case 800...: 6
        case 600...: 5
        default: max(3, min(4, Int(width / 112)))
        }
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

enum TimelineScrollAnchorPolicy {
    static func preservedAnchor(
        current: UUID?,
        previousIDs: [UUID],
        refreshedIDs: [UUID]
    ) -> UUID? {
        guard let current else { return nil }
        let refreshedSet = Set(refreshedIDs)
        if refreshedSet.contains(current) { return current }
        guard let previousIndex = previousIDs.firstIndex(of: current) else { return nil }

        if let following = previousIDs[(previousIndex + 1)...].first(where: refreshedSet.contains) {
            return following
        }
        return previousIDs[..<previousIndex].reversed().first(where: refreshedSet.contains)
    }
}

@MainActor
struct TimelineView: View {
    typealias LoadMore = @MainActor @Sendable () async -> [TimelineAsset]
    typealias Selection = @MainActor (TimelineAsset, MediaFrame?, TimelineViewerWindow) -> Void
    typealias SettingsAction = @MainActor () -> Void

    @State private var state: TimelineState
    @State private var prefetchController: TimelinePrefetchController
    @State private var scrollAnchorID: UUID?
    @State private var previousAssetIDs: [UUID] = []

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private let mediaClient: TimelineMediaClient
    private let calendar: Calendar
    private let transitionNamespace: Namespace.ID
    private let updatedAsset: TimelineAsset?
    private let onSelectAsset: Selection
    private let onOpenSettings: SettingsAction

    init(
        accountNamespace: UUID,
        assetStore: any AssetStore,
        mediaPipeline: any MediaPipelineProtocol,
        transitionNamespace: Namespace.ID,
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
        self.transitionNamespace = transitionNamespace
        self.updatedAsset = updatedAsset
        self.onSelectAsset = onSelectAsset
        self.onOpenSettings = onOpenSettings
    }

    init(
        accountNamespace: UUID,
        dataClient: TimelineDataClient,
        mediaClient: TimelineMediaClient,
        transitionNamespace: Namespace.ID,
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
        self.transitionNamespace = transitionNamespace
        self.updatedAsset = updatedAsset
        self.onSelectAsset = onSelectAsset
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        GeometryReader { proxy in
            content(width: proxy.size.width)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            browseScopePicker
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Browse", selection: browseScopeBinding) {
                        ForEach(TimelineBrowseScope.allCases) { scope in
                            Text(scope.rawValue).tag(scope)
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease")
                }
                .accessibilityLabel("Filter Library")
                .accessibilityIdentifier(TimelineAccessibilityID.more)

                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Settings")
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
                "Connecting to Library",
                message: "Loading photo details…",
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
                emptyRefreshTitle,
                message: emptyRefreshMessage,
                accessibilityIdentifier: TimelineAccessibilityID.loading
            )
            .accessibilityValue(refreshStatusText)

        case .loaded where state.assets.isEmpty:
            ScrollView {
                EmptyStateView(
                    "No Photos Yet",
                    systemImage: "photo.stack",
                    message: "Photos from your server will appear here.",
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
            LazyVStack(spacing: 0) {
                ForEach(state.sections) { section in
                    LazyVGrid(columns: columns, spacing: TimelineGridLayout.spacing) {
                        ForEach(section.assets) { asset in
                            TimelineMediaCell(
                                asset: asset,
                                index: state.assetIndices[asset.id] ?? 0,
                                mediaClient: mediaClient,
                                calendar: calendar,
                                transitionNamespace: transitionNamespace,
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
                            .id(asset.id)
                        }
                    }
                    .scrollTargetLayout()
                    .overlay(alignment: .topLeading) {
                        sectionHeader(section)
                    }
                }

                paginationFooter
            }
        }
        .refreshable {
            await state.refresh()
        }
        .scrollPosition(id: $scrollAnchorID, anchor: .top)
        .onChange(of: state.windowRevision, initial: true) { _, _ in
            let refreshedIDs = state.assets.map(\.id)
            scrollAnchorID = TimelineScrollAnchorPolicy.preservedAnchor(
                current: scrollAnchorID,
                previousIDs: previousAssetIDs,
                refreshedIDs: refreshedIDs
            )
            previousAssetIDs = refreshedIDs
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if let refreshFailure = state.refreshFailure {
                refreshFailureBanner(refreshFailure)
            }
        }
        .overlay(alignment: .top) {
            if state.isRefreshing, state.refreshFailure == nil {
                refreshStatusPill
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
    }

    private func sectionHeader(_ section: TimelineSection) -> some View {
        Text(sectionTitle(section.day))
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
            .padding(10)
            .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(section.day.formatted(.dateTime.weekday(.wide).month(.wide).day().year())), "
                + "\(section.assets.count) photos"
        )
        .accessibilityIdentifier(TimelineAccessibilityID.section(day: section.day, calendar: calendar))
    }

    private func sectionTitle(_ date: Date) -> String {
        switch state.browseScope {
        case .years:
            date.formatted(.dateTime.year())
        case .months:
            date.formatted(.dateTime.month(.wide).year())
        case .all:
            date.formatted(.dateTime.month(.wide).day())
        }
    }

    private var browseScopeBinding: Binding<TimelineBrowseScope> {
        Binding(
            get: { state.browseScope },
            set: { state.setBrowseScope($0) }
        )
    }

    private var browseScopePicker: some View {
        Picker("Browse", selection: browseScopeBinding) {
            ForEach(TimelineBrowseScope.allCases) { scope in
                Text(scope.rawValue).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .accessibilityIdentifier(TimelineAccessibilityID.scope)
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
        .background {
            if reduceTransparency {
                Color(uiColor: .secondarySystemBackground)
            } else {
                Rectangle().fill(.thinMaterial)
            }
        }
        .overlay {
            if colorSchemeContrast == .increased {
                Rectangle().stroke(.primary.opacity(0.45), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(TimelineAccessibilityID.refreshFailure)
    }

    private var refreshStatusPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            Text(refreshStatusText)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background {
            if reduceTransparency {
                Capsule().fill(Color(uiColor: .secondarySystemBackground))
            } else {
                Capsule().fill(.regularMaterial)
            }
        }
        .overlay {
            if colorSchemeContrast == .increased {
                Capsule().stroke(.primary.opacity(0.7), lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Library refresh")
        .accessibilityValue(refreshStatusText)
        .accessibilityIdentifier(TimelineAccessibilityID.refreshStatus)
    }

    private var emptyRefreshTitle: String {
        switch state.refreshProgress?.stage {
        case .showingLatest, .organizing, .completed:
            "Showing Your Latest Photos"
        case .connecting, nil:
            "Connecting to Server"
        }
    }

    private var emptyRefreshMessage: String {
        switch state.refreshProgress?.stage {
        case .showingLatest, .organizing, .completed:
            "The first photos will appear while the rest of your library is organized."
        case .connecting, nil:
            "Checking for your latest photos."
        }
    }

    private var refreshStatusText: String {
        guard let progress = state.refreshProgress else { return "Connecting to Server" }
        switch progress.stage {
        case .connecting:
            return "Connecting to Server"
        case .showingLatest:
            return "Showing Your Latest Photos"
        case .organizing:
            if let totalCount = progress.totalCount {
                return "Organizing Library · \(progress.processedCount) / \(totalCount)"
            }
            return "Organizing Library · \(progress.processedCount) processed"
        case .completed:
            return "Library Updated · \(progress.storedCount) photos"
        }
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
