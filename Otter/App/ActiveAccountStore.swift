import Foundation

struct ActiveAccountRecord: Codable, Equatable, Sendable {
    let namespace: UUID
    let serverURL: URL
    let serverVersion: SemanticVersion
    var cacheLimitBytes: Int64
}

protocol ActiveAccountStoring: Sendable {
    func load() throws -> ActiveAccountRecord?
    func save(_ record: ActiveAccountRecord) throws
    func remove() throws
}

enum ActiveAccountStoreError: Error, Equatable {
    case corruptRecord
}

final class UserDefaultsActiveAccountStore: ActiveAccountStoring, @unchecked Sendable {
    static let defaultKey = "otter.active-account.v1"

    private let defaults: UserDefaults
    private let key: String
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard, key: String = defaultKey) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> ActiveAccountRecord? {
        try lock.withLock {
            guard let data = defaults.data(forKey: key) else { return nil }
            do { return try JSONDecoder().decode(ActiveAccountRecord.self, from: data) }
            catch { throw ActiveAccountStoreError.corruptRecord }
        }
    }

    func save(_ record: ActiveAccountRecord) throws {
        let data = try JSONEncoder().encode(record)
        lock.withLock { defaults.set(data, forKey: key) }
    }

    func remove() throws {
        lock.withLock { defaults.removeObject(forKey: key) }
    }
}
