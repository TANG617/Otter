import Foundation

enum RatingWriteAvailability: Equatable, Sendable {
    case available
    case unverified
    case unavailable
}

enum RatingRepositoryError: Error, Equatable {
    case unavailable
    case assetNotFound
    case verificationMismatch
}

struct RatingMutationResult: Equatable, Sendable {
    let previousRating: AssetRating?
    let asset: TimelineAsset
}

actor RatingRepository {
    private let database: AssetDatabase
    private let remote: any AssetRemoteDataSource
    private(set) var writeAvailability: RatingWriteAvailability
    private var lockedAssets: Set<RatingMutationKey> = []
    private var waiters: [RatingMutationKey: [CheckedContinuation<Void, Never>]] = [:]

    init(
        database: AssetDatabase,
        remote: any AssetRemoteDataSource,
        writeAvailability: RatingWriteAvailability = .available
    ) {
        self.database = database
        self.remote = remote
        self.writeAvailability = writeAvailability
    }

    func setRating(
        _ rating: AssetRating?,
        assetID: UUID,
        accountNamespace: UUID
    ) async throws -> RatingMutationResult {
        guard writeAvailability != .unavailable else {
            throw RatingRepositoryError.unavailable
        }
        let mutationKey = RatingMutationKey(accountNamespace: accountNamespace, assetID: assetID)
        await acquire(mutationKey)
        defer { release(mutationKey) }
        guard let previous = try database.asset(id: assetID, accountNamespace: accountNamespace) else {
            throw RatingRepositoryError.assetNotFound
        }

        try database.updateRating(rating, assetID: assetID, accountNamespace: accountNamespace)
        do {
            try await remote.writeRating(
                rating,
                assetID: assetID,
                accountNamespace: accountNamespace
            )
            let verified = try await remote.asset(id: assetID, accountNamespace: accountNamespace)
            guard verified.rating == rating else {
                writeAvailability = .unavailable
                throw RatingRepositoryError.verificationMismatch
            }
            writeAvailability = .available
            try database.upsertAssets([verified], accountNamespace: accountNamespace)
            return RatingMutationResult(previousRating: previous.rating, asset: verified)
        } catch {
            try? database.updateRating(previous.rating, assetID: assetID, accountNamespace: accountNamespace)
            if error as? RatingRepositoryError == .verificationMismatch
                || error as? ImmichClientError == .permissionDenied {
                writeAvailability = .unavailable
            }
            throw error
        }
    }

    private func acquire(_ key: RatingMutationKey) async {
        guard !lockedAssets.insert(key).inserted else { return }
        await withCheckedContinuation { continuation in
            waiters[key, default: []].append(continuation)
        }
    }

    private func release(_ key: RatingMutationKey) {
        guard var queued = waiters[key], !queued.isEmpty else {
            waiters.removeValue(forKey: key)
            lockedAssets.remove(key)
            return
        }
        let next = queued.removeFirst()
        waiters[key] = queued.isEmpty ? nil : queued
        next.resume()
    }
}

private struct RatingMutationKey: Hashable, Sendable {
    let accountNamespace: UUID
    let assetID: UUID
}
