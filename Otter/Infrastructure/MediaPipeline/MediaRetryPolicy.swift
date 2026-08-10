import Foundation

struct MediaRetryPolicy: Sendable {
    let visibleRetryLimit: Int
    let negativeCacheTTL: TimeInterval

    init(visibleRetryLimit: Int = 1, negativeCacheTTL: TimeInterval = 30) {
        self.visibleRetryLimit = max(visibleRetryLimit, 0)
        self.negativeCacheTTL = max(negativeCacheTTL, 0)
    }

    func delay(for error: Error, attempt: Int, priority: MediaPriority) -> TimeInterval? {
        guard priority >= .visible, attempt < visibleRetryLimit else { return nil }
        if let mediaError = error as? MediaError {
            switch mediaError {
            case let .httpStatus(status, retryAfter) where status == 429:
                return retryAfter ?? 1
            case let .httpStatus(status, _) where (500...599).contains(status):
                return min(pow(2, Double(attempt)) * 0.25, 1)
            case .cancelled, .httpStatus(401, _), .httpStatus(403, _), .httpStatus(404, _):
                return nil
            default:
                return attempt == 0 ? 0.25 : nil
            }
        }
        return attempt == 0 ? 0.25 : nil
    }
}
actor NegativeMediaCache {
    private var expirations: [ByteCacheKey: Date] = [:]

    func contains(_ key: ByteCacheKey, now: Date = Date()) -> Bool {
        guard let expiration = expirations[key] else { return false }
        if expiration <= now {
            expirations.removeValue(forKey: key)
            return false
        }
        return true
    }

    func insert(_ key: ByteCacheKey, ttl: TimeInterval, now: Date = Date()) {
        expirations[key] = now.addingTimeInterval(max(ttl, 0))
    }

    func remove(accountNamespace: UUID, assetID: UUID) {
        expirations = expirations.filter {
            !($0.key.accountNamespace == accountNamespace && $0.key.assetID == assetID)
        }
    }
}
