import Foundation
import Observation

@MainActor
@Observable
final class TimelineState {
    enum ContentState: Equatable {
        case idle
        case loading
        case loaded
        case failed(PresentationFailure)
    }

    private(set) var contentState: ContentState = .idle
    private(set) var assets: [TimelineAsset] = []
    private(set) var sections: [TimelineSection] = []
    private(set) var assetIndices: [UUID: Int] = [:]
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var canLoadMore = false
    private(set) var refreshFailure: PresentationFailure?
    private(set) var paginationFailure: PresentationFailure?

    let accountNamespace: UUID
    let pageSize: Int

    private let dataClient: TimelineDataClient
    private let calendar: Calendar
    private(set) var nextCursor: TimelineCursor?
    private var observedCursors: Set<TimelineCursor> = []

    init(
        accountNamespace: UUID,
        dataClient: TimelineDataClient,
        pageSize: Int = 200,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        self.accountNamespace = accountNamespace
        self.dataClient = dataClient
        self.pageSize = max(1, min(pageSize, 500))
        self.calendar = calendar
    }

    func loadIfNeeded() async {
        guard contentState == .idle else { return }
        contentState = .loading
        do {
            try await reloadLocalWindow(targetCount: pageSize)
            contentState = .loaded
        } catch is CancellationError {
            return
        } catch {
            contentState = .failed(Self.libraryFailure)
            return
        }

        await refresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        refreshFailure = nil
        defer { isRefreshing = false }

        do {
            _ = try await dataClient.refresh(
                accountNamespace,
                .incremental(overlap: 300)
            )
            try Task.checkCancellation()
            try await reloadLocalWindow(targetCount: max(pageSize, assets.count))
            contentState = .loaded
        } catch is CancellationError {
            return
        } catch {
            if assets.isEmpty {
                contentState = .failed(Self.libraryFailure)
            } else {
                refreshFailure = Self.refreshFailurePresentation
            }
        }
    }

    func loadMore() async {
        guard contentState == .loaded,
              canLoadMore,
              !isLoadingMore,
              !isRefreshing,
              let cursor = nextCursor else { return }

        isLoadingMore = true
        paginationFailure = nil
        defer { isLoadingMore = false }

        do {
            let page = try await dataClient.localPage(
                TimelinePageRequest(
                    accountNamespace: accountNamespace,
                    after: cursor,
                    limit: pageSize
                )
            )
            try Task.checkCancellation()
            appendOrderedPage(page.assets)
            updateContinuation(page.nextCursor)
        } catch is CancellationError {
            return
        } catch {
            paginationFailure = Self.paginationFailurePresentation
        }
    }

    func retry() async {
        if case .failed = contentState {
            contentState = .idle
            await loadIfNeeded()
        } else if refreshFailure != nil {
            await refresh()
        } else if paginationFailure != nil {
            await loadMore()
        }
    }

    func applyVerifiedUpdate(_ asset: TimelineAsset) {
        guard asset.accountNamespace == accountNamespace,
              let index = assetIndices[asset.id] else { return }
        assets[index] = asset

        let day = calendar.startOfDay(for: asset.timelineDate)
        guard let sectionIndex = sections.firstIndex(where: { $0.day == day }),
              let assetIndex = sections[sectionIndex].assets.firstIndex(where: { $0.id == asset.id })
        else { return }
        var sectionAssets = sections[sectionIndex].assets
        sectionAssets[assetIndex] = asset
        sections[sectionIndex] = TimelineSection(day: day, assets: sectionAssets)
    }

    private func reloadLocalWindow(targetCount: Int) async throws {
        var accumulated: [TimelineAsset] = []
        var cursor: TimelineCursor?
        var cursors: Set<TimelineCursor> = []

        repeat {
            let page = try await dataClient.localPage(
                TimelinePageRequest(
                    accountNamespace: accountNamespace,
                    after: cursor,
                    limit: pageSize
                )
            )
            try Task.checkCancellation()
            accumulated.append(contentsOf: page.assets)

            guard let candidate = page.nextCursor,
                  !cursors.contains(candidate),
                  accumulated.count < targetCount else {
                cursor = page.nextCursor
                break
            }
            cursors.insert(candidate)
            cursor = candidate
        } while true

        replace(with: accumulated)
        observedCursors = cursors
        updateContinuation(cursor)
        paginationFailure = nil
    }

    private func replace(with incoming: [TimelineAsset]) {
        var byID: [UUID: TimelineAsset] = [:]
        for asset in incoming where asset.accountNamespace == accountNamespace && asset.isTimelineEligible {
            byID[asset.id] = asset
        }
        assets = Self.ordered(Array(byID.values))
        assetIndices = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        sections = TimelineGrouping.sectionsFromOrdered(assets, calendar: calendar)
    }

    private func appendOrderedPage(_ incoming: [TimelineAsset]) {
        var known = Set(assetIndices.keys)
        let additions = incoming.filter { asset in
            asset.accountNamespace == accountNamespace
                && asset.isTimelineEligible
                && known.insert(asset.id).inserted
        }
        guard !additions.isEmpty else { return }

        let startIndex = assets.count
        assets.append(contentsOf: additions)
        for (offset, asset) in additions.enumerated() {
            assetIndices[asset.id] = startIndex + offset
        }

        for asset in additions {
            let day = calendar.startOfDay(for: asset.timelineDate)
            if let last = sections.last, last.day == day {
                sections[sections.count - 1] = TimelineSection(
                    day: day,
                    assets: last.assets + [asset]
                )
            } else {
                sections.append(TimelineSection(day: day, assets: [asset]))
            }
        }
    }

    private func updateContinuation(_ cursor: TimelineCursor?) {
        guard let cursor else {
            nextCursor = nil
            canLoadMore = false
            return
        }
        guard !observedCursors.contains(cursor) else {
            nextCursor = nil
            canLoadMore = false
            return
        }
        observedCursors.insert(cursor)
        nextCursor = cursor
        canLoadMore = true
    }

    private static func ordered(_ assets: [TimelineAsset]) -> [TimelineAsset] {
        assets.sorted {
            if $0.timelineDate != $1.timelineDate {
                return $0.timelineDate > $1.timelineDate
            }
            return $0.id.uuidString.lowercased() > $1.id.uuidString.lowercased()
        }
    }

    private static let libraryFailure = PresentationFailure(
        title: "Library Unavailable",
        message: "Your photo timeline could not be loaded. Try again."
    )

    private static let refreshFailurePresentation = PresentationFailure(
        title: "Couldn’t Refresh",
        message: "Showing saved library information. Pull to refresh or try again.",
        systemImage: "wifi.exclamationmark"
    )

    private static let paginationFailurePresentation = PresentationFailure(
        title: "Couldn’t Load More",
        message: "The rest of your timeline is still available to retry."
    )
}
