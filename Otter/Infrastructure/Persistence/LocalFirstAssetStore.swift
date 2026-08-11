import Foundation

enum AssetStoreError: Error, Equatable {
    case paginationCycle
}

actor LocalFirstAssetStore: AssetStore {
    static let fullReconciliationInterval: TimeInterval = 24 * 60 * 60

    private let database: AssetDatabase
    private let remote: any AssetRemoteDataSource
    private let now: @Sendable () -> Date

    init(
        database: AssetDatabase,
        remote: any AssetRemoteDataSource,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.database = database
        self.remote = remote
        self.now = now
    }

    func localPage(_ request: TimelinePageRequest) throws -> TimelineAssetPage {
        try database.timelinePage(request)
    }

    func localAsset(id: UUID, accountNamespace: UUID) throws -> TimelineAsset? {
        try database.asset(id: id, accountNamespace: accountNamespace)
    }

    func refresh(accountNamespace: UUID, mode: AssetRefreshMode) async throws -> AssetRefreshResult {
        try await performRefresh(accountNamespace: accountNamespace, mode: mode)
    }

    nonisolated func refreshEvents(
        accountNamespace: UUID,
        mode: AssetRefreshMode
    ) -> AssetRefreshEventStream {
        AssetRefreshEventStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task {
                do {
                    let result = try await self.performRefresh(
                        accountNamespace: accountNamespace,
                        mode: mode
                    ) { progress in
                        continuation.yield(.progress(progress))
                    }
                    try Task.checkCancellation()
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    private func performRefresh(
        accountNamespace: UUID,
        mode: AssetRefreshMode,
        onProgress: (@Sendable (AssetRefreshProgress) -> Void)? = nil
    ) async throws -> AssetRefreshResult {
        let state = try database.syncState(accountNamespace: accountNamespace)
        let refreshDate = now()
        let updatedAfter: Date?
        let isReconciliation: Bool
        switch mode {
        case .bootstrap, .fullReconciliation:
            updatedAfter = nil
            isReconciliation = true
        case let .incremental(overlap):
            let reconciliationIsDue = state.lastFullReconciliationAt.map {
                refreshDate.timeIntervalSince($0) >= Self.fullReconciliationInterval
            } ?? true
            isReconciliation = reconciliationIsDue
            updatedAfter = reconciliationIsDue ? nil : state.highestObservedUpdatedAt.map {
                $0.addingTimeInterval(-max(0, overlap))
            }
        }

        let generation = isReconciliation
            ? try database.beginReconciliation(accountNamespace: accountNamespace)
            : nil
        var continuation: String?
        var observedContinuations = Set<String>()
        var seenAssets: [UUID: Date] = [:]
        var receivedCount = 0
        var highest: Date?
        var pageIndex = 0

        onProgress?(
            AssetRefreshProgress(
                stage: .connecting,
                processedCount: 0,
                storedCount: 0,
                totalCount: nil
            )
        )

        repeat {
            let page = try await remote.searchAssets(
                AssetSearchRequest(
                    continuation: continuation,
                    pageSize: 1_000,
                    updatedAfter: updatedAfter
                ),
                accountNamespace: accountNamespace
            )
            try Task.checkCancellation()
            receivedCount += page.assets.count
            var batch: [TimelineAsset] = []
            batch.reserveCapacity(page.assets.count)
            for asset in page.assets {
                guard asset.accountNamespace == accountNamespace else {
                    throw AssetDatabaseError.wrongAccount
                }
                if let existingDate = seenAssets[asset.id], existingDate >= asset.updatedAt {
                    continue
                }
                seenAssets[asset.id] = asset.updatedAt
                highest = max(highest ?? asset.updatedAt, asset.updatedAt)
                batch.append(asset)
            }
            if !batch.isEmpty {
                try Task.checkCancellation()
                try database.upsertAssets(
                    batch,
                    accountNamespace: accountNamespace,
                    reconciliationGeneration: generation
                )
            }
            onProgress?(
                AssetRefreshProgress(
                    stage: pageIndex == 0 ? .showingLatest : .organizing,
                    processedCount: receivedCount,
                    storedCount: seenAssets.count,
                    totalCount: nil
                )
            )
            pageIndex += 1
            if let next = page.nextContinuation {
                guard observedContinuations.insert(next).inserted else {
                    throw AssetStoreError.paginationCycle
                }
            }
            continuation = page.nextContinuation
            try Task.checkCancellation()
        } while continuation != nil

        let deletedCount: Int
        let completedAt = refreshDate
        if let generation {
            deletedCount = try database.deleteAssetsNotSeen(
                accountNamespace: accountNamespace,
                generation: generation
            )
        } else {
            deletedCount = 0
        }
        try database.updateSyncState(
            accountNamespace: accountNamespace,
            incrementalAt: isReconciliation ? nil : completedAt,
            reconciliationAt: isReconciliation ? completedAt : nil,
            highestObservedUpdatedAt: highest
        )
        let result = AssetRefreshResult(
            receivedCount: receivedCount,
            storedCount: seenAssets.count,
            deletedCount: deletedCount,
            highestObservedUpdatedAt: highest
        )
        onProgress?(
            AssetRefreshProgress(
                stage: .completed,
                processedCount: result.receivedCount,
                storedCount: result.storedCount,
                totalCount: result.receivedCount
            )
        )
        return result
    }
}
