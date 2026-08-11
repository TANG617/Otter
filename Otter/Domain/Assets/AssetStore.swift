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
    func writeFavorite(_ isFavorite: Bool, assetID: UUID, accountNamespace: UUID) async throws
}

extension AssetRemoteDataSource {
    func writeFavorite(_ isFavorite: Bool, assetID: UUID, accountNamespace: UUID) async throws {
        throw AssetMetadataMutationError.unavailable
    }
}

enum AssetMetadataMutationError: Error, Equatable {
    case unavailable
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

struct AssetRefreshProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        case connecting
        case showingLatest
        case organizing
        case completed
    }

    let stage: Stage
    let processedCount: Int
    let storedCount: Int
    let totalCount: Int?
}

enum AssetRefreshEvent: Equatable, Sendable {
    case progress(AssetRefreshProgress)
    case completed(AssetRefreshResult)
}

typealias AssetRefreshEventStream = AsyncThrowingStream<AssetRefreshEvent, Error>

protocol AssetStore: Sendable {
    func localPage(_ request: TimelinePageRequest) async throws -> TimelineAssetPage
    func localAsset(id: UUID, accountNamespace: UUID) async throws -> TimelineAsset?
    func refresh(accountNamespace: UUID, mode: AssetRefreshMode) async throws -> AssetRefreshResult
    func refreshEvents(accountNamespace: UUID, mode: AssetRefreshMode) -> AssetRefreshEventStream
}

extension AssetStore {
    func refreshEvents(accountNamespace: UUID, mode: AssetRefreshMode) -> AssetRefreshEventStream {
        AssetRefreshEventStream(bufferingPolicy: .bufferingNewest(2)) { continuation in
            let task = Task {
                continuation.yield(
                    .progress(
                        AssetRefreshProgress(
                            stage: .connecting,
                            processedCount: 0,
                            storedCount: 0,
                            totalCount: nil
                        )
                    )
                )
                do {
                    let result = try await refresh(accountNamespace: accountNamespace, mode: mode)
                    try Task.checkCancellation()
                    continuation.yield(
                        .progress(
                            AssetRefreshProgress(
                                stage: .completed,
                                processedCount: result.receivedCount,
                                storedCount: result.storedCount,
                                totalCount: result.receivedCount
                            )
                        )
                    )
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
}
