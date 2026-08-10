import Foundation

struct AssetSearchRequest: Equatable, Sendable {
    let continuation: String?
    let pageSize: Int
    let updatedAfter: Date?

    init(continuation: String? = nil, pageSize: Int = 1_000, updatedAfter: Date? = nil) {
        self.continuation = continuation
        self.pageSize = max(1, min(pageSize, 1_000))
        self.updatedAfter = updatedAfter
    }
}

struct AssetSearchPage: Equatable, Sendable {
    let assets: [TimelineAsset]
    let nextContinuation: String?
}

protocol AssetRemoteDataSource: Sendable {
    func searchAssets(_ request: AssetSearchRequest, accountNamespace: UUID) async throws -> AssetSearchPage
    func asset(id: UUID, accountNamespace: UUID) async throws -> TimelineAsset
    func writeRating(_ rating: AssetRating?, assetID: UUID, accountNamespace: UUID) async throws
}

enum AssetRefreshMode: Equatable, Sendable {
    case bootstrap
    case incremental(overlap: TimeInterval)
    case fullReconciliation
}

struct AssetRefreshResult: Equatable, Sendable {
    let receivedCount: Int
    let storedCount: Int
    let deletedCount: Int
    let highestObservedUpdatedAt: Date?
}

protocol AssetStore: Sendable {
    func localPage(_ request: TimelinePageRequest) async throws -> TimelineAssetPage
    func localAsset(id: UUID, accountNamespace: UUID) async throws -> TimelineAsset?
    func refresh(accountNamespace: UUID, mode: AssetRefreshMode) async throws -> AssetRefreshResult
}
