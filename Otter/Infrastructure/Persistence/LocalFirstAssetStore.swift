import Foundation

enum AssetStoreError: Error, Equatable {
    case paginationCycle
}

actor LocalFirstAssetStore: AssetStore {
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
        let state = try database.syncState(accountNamespace: accountNamespace)
        let updatedAfter: Date?
        let isReconciliation: Bool
        switch mode {
        case .bootstrap, .fullReconciliation:
            updatedAfter = nil
            isReconciliation = true
        case let .incremental(overlap):
            updatedAfter = state.highestObservedUpdatedAt.map {
                $0.addingTimeInterval(-max(0, overlap))
            }
            isReconciliation = updatedAfter == nil
        }

        let generation = isReconciliation
            ? try database.beginReconciliation(accountNamespace: accountNamespace)
            : nil
        var continuation: String?
        var observedContinuations = Set<String>()
        var seenAssets: [UUID: Date] = [:]
        var receivedCount = 0
        var highest: Date?

        repeat {
            let page = try await remote.searchAssets(
                AssetSearchRequest(
                    continuation: continuation,
                    pageSize: 1_000,
                    updatedAfter: updatedAfter
                ),
                accountNamespace: accountNamespace
            )
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
                try database.upsertAssets(
                    batch,
                    accountNamespace: accountNamespace,
                    reconciliationGeneration: generation
                )
            }
            if let next = page.nextContinuation {
                guard observedContinuations.insert(next).inserted else {
                    throw AssetStoreError.paginationCycle
                }
            }
            continuation = page.nextContinuation
        } while continuation != nil

        let deletedCount: Int
        let completedAt = now()
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
        return AssetRefreshResult(
            receivedCount: receivedCount,
            storedCount: seenAssets.count,
            deletedCount: deletedCount,
            highestObservedUpdatedAt: highest
        )
    }
}
