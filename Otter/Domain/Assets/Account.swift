import Foundation

struct Account: Codable, Hashable, Sendable {
    let namespace: UUID
    let serverURL: URL
    let userID: UUID?
    let serverVersion: String?
    let createdAt: Date
}

struct SyncState: Codable, Equatable, Sendable {
    let accountNamespace: UUID
    var lastIncrementalRefreshAt: Date?
    var lastFullReconciliationAt: Date?
    var highestObservedUpdatedAt: Date?
}
