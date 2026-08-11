import Foundation
import Observation

enum TimelineBrowseScope: String, CaseIterable, Identifiable, Sendable {
    case years = "Years"
    case months = "Months"
    case all = "All"

    var id: String { rawValue }
}

struct TimelineMutationDiagnostics: Equatable, Sendable {
    fileprivate(set) var fullSectionRebuildCount = 0
    fileprivate(set) var incrementalMetadataUpdateCount = 0
    fileprivate(set) var incrementalPageAppendCount = 0
    fileprivate(set) var appendFallbackRebuildCount = 0
}

private struct TimelineSectionLocation: Equatable, Sendable {
    let sectionIndex: Int
    let assetIndex: Int
}

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
    private(set) var windowRevision = 0
    private(set) var isRefreshing = false
    private(set) var isLoadingMore = false
    private(set) var canLoadMore = false
    private(set) var refreshProgress: AssetRefreshProgress?
    private(set) var refreshFailure: PresentationFailure?
    private(set) var paginationFailure: PresentationFailure?
    private(set) var browseScope: TimelineBrowseScope = .all
    private(set) var mutationDiagnostics = TimelineMutationDiagnostics()

    let accountNamespace: UUID
    let pageSize: Int

    private let dataClient: TimelineDataClient
    private let calendar: Calendar
    private(set) var nextCursor: TimelineCursor?
    private var observedCursors: Set<TimelineCursor> = []
    private var sectionIndices: [Date: Int] = [:]
    private var assetSectionLocations: [UUID: TimelineSectionLocation] = [:]

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
        refreshProgress = AssetRefreshProgress(
            stage: .connecting,
            processedCount: 0,
            storedCount: 0,
            totalCount: nil
        )
        refreshFailure = nil
        defer { isRefreshing = false }

        do {
            for try await event in dataClient.refreshEvents(
                accountNamespace,
                .incremental(overlap: 300)
            ) {
                try Task.checkCancellation()
                switch event {
                case let .progress(progress):
                    refreshProgress = progress
                    switch progress.stage {
                    case .showingLatest, .organizing:
                        try await reloadLocalWindow(targetCount: max(pageSize, assets.count))
                        contentState = .loaded
                    case .connecting, .completed:
                        break
                    }
                case .completed:
                    try await reloadLocalWindow(targetCount: max(pageSize, assets.count))
                    contentState = .loaded
                }
            }
        } catch is CancellationError {
            return
        } catch {
            refreshProgress = nil
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
        let previous = assets[index]
        guard previous.isTimelineEligible == asset.isTimelineEligible,
              asset.isTimelineEligible,
              previous.timelineDate == asset.timelineDate,
              let sectionKey = sectionStart(for: asset),
              sectionStart(for: previous) == sectionKey,
              let location = assetSectionLocations[asset.id],
              sectionIndices[sectionKey] == location.sectionIndex,
              sections.indices.contains(location.sectionIndex),
              sections[location.sectionIndex].assets.indices.contains(location.assetIndex) else {
            var replacement = assets
            replacement[index] = asset
            replace(with: replacement)
            return
        }

        assets[index] = asset
        var sectionAssets = sections[location.sectionIndex].assets
        sectionAssets[location.assetIndex] = asset
        sections[location.sectionIndex] = TimelineSection(
            day: sections[location.sectionIndex].day,
            assets: sectionAssets
        )
        mutationDiagnostics.incrementalMetadataUpdateCount += 1
    }

    func setBrowseScope(_ scope: TimelineBrowseScope) {
        guard browseScope != scope else { return }
        browseScope = scope
        rebuildSections()
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
                  accumulated.count < max(targetCount, assets.count) else {
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
        let previousIDs = assets.map(\.id)
        var byID: [UUID: TimelineAsset] = [:]
        for asset in incoming where asset.accountNamespace == accountNamespace && asset.isTimelineEligible {
            byID[asset.id] = asset
        }
        assets = Self.ordered(Array(byID.values))
        assetIndices = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
        rebuildSections()
        if assets.map(\.id) != previousIDs {
            windowRevision += 1
        }
    }

    private func appendOrderedPage(_ incoming: [TimelineAsset]) {
        var known = Set(assetIndices.keys)
        let additions = incoming.filter { asset in
            asset.accountNamespace == accountNamespace
                && asset.isTimelineEligible
                && known.insert(asset.id).inserted
        }
        guard !additions.isEmpty else { return }

        guard Self.isOrdered(additions),
              additions.first.map({ first in
                  assets.last.map { Self.precedes($0, first) } ?? true
              }) ?? true else {
            mutationDiagnostics.appendFallbackRebuildCount += 1
            replace(with: assets + additions)
            return
        }

        let startIndex = assets.count
        assets.append(contentsOf: additions)
        for (offset, asset) in additions.enumerated() {
            assetIndices[asset.id] = startIndex + offset
        }

        appendSections(additions)
        mutationDiagnostics.incrementalPageAppendCount += 1
        windowRevision += 1
    }

    private func rebuildSections() {
        switch browseScope {
        case .all:
            sections = TimelineGrouping.sectionsFromOrdered(assets, calendar: calendar)
        case .months:
            sections = groupedSections(component: .month)
        case .years:
            sections = groupedSections(component: .year)
        }
        rebuildSectionIndices()
        mutationDiagnostics.fullSectionRebuildCount += 1
    }

    private func appendSections(_ additions: [TimelineAsset]) {
        for asset in additions {
            guard let start = sectionStart(for: asset) else { continue }
            if let lastIndex = sections.indices.last,
               sections[lastIndex].day == start {
                var sectionAssets = sections[lastIndex].assets
                let assetIndex = sectionAssets.count
                sectionAssets.append(asset)
                sections[lastIndex] = TimelineSection(day: start, assets: sectionAssets)
                assetSectionLocations[asset.id] = TimelineSectionLocation(
                    sectionIndex: lastIndex,
                    assetIndex: assetIndex
                )
            } else {
                let sectionIndex = sections.count
                sections.append(TimelineSection(day: start, assets: [asset]))
                sectionIndices[start] = sectionIndex
                assetSectionLocations[asset.id] = TimelineSectionLocation(
                    sectionIndex: sectionIndex,
                    assetIndex: 0
                )
            }
        }
    }

    private func rebuildSectionIndices() {
        sectionIndices.removeAll(keepingCapacity: true)
        assetSectionLocations.removeAll(keepingCapacity: true)
        for (sectionIndex, section) in sections.enumerated() {
            sectionIndices[section.day] = sectionIndex
            for (assetIndex, asset) in section.assets.enumerated() {
                assetSectionLocations[asset.id] = TimelineSectionLocation(
                    sectionIndex: sectionIndex,
                    assetIndex: assetIndex
                )
            }
        }
    }

    private func sectionStart(for asset: TimelineAsset) -> Date? {
        switch browseScope {
        case .all:
            calendar.startOfDay(for: asset.timelineDate)
        case .months:
            calendar.dateInterval(of: .month, for: asset.timelineDate)?.start
        case .years:
            calendar.dateInterval(of: .year, for: asset.timelineDate)?.start
        }
    }

    private func groupedSections(component: Calendar.Component) -> [TimelineSection] {
        var result: [TimelineSection] = []
        var currentStart: Date?
        var currentAssets: [TimelineAsset] = []

        for asset in assets {
            guard let start = calendar.dateInterval(of: component, for: asset.timelineDate)?.start else {
                continue
            }
            if let currentStart, currentStart != start {
                result.append(TimelineSection(day: currentStart, assets: currentAssets))
                currentAssets.removeAll(keepingCapacity: true)
            }
            currentStart = start
            currentAssets.append(asset)
        }
        if let currentStart {
            result.append(TimelineSection(day: currentStart, assets: currentAssets))
        }
        return result
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
        assets.sorted(by: precedes)
    }

    private static func precedes(_ lhs: TimelineAsset, _ rhs: TimelineAsset) -> Bool {
        if lhs.timelineDate != rhs.timelineDate {
            return lhs.timelineDate > rhs.timelineDate
        }
        return lhs.id.uuidString.lowercased() > rhs.id.uuidString.lowercased()
    }

    private static func isOrdered(_ assets: [TimelineAsset]) -> Bool {
        zip(assets, assets.dropFirst()).allSatisfy { precedes($0.0, $0.1) }
    }

    private static let libraryFailure = PresentationFailure(
        title: "Couldn’t Refresh Library",
        message: "Check your connection, then try again."
    )

    private static let refreshFailurePresentation = PresentationFailure(
        title: "Couldn’t Refresh Library",
        message: "Showing saved library information. Pull to refresh or try again.",
        systemImage: "wifi.exclamationmark"
    )

    private static let paginationFailurePresentation = PresentationFailure(
        title: "Couldn’t Load More",
        message: "The rest of your timeline is still available to retry."
    )
}
