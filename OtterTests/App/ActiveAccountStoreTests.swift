import Foundation
import Testing
@testable import Otter

@Suite("Active account persistence")
struct ActiveAccountStoreTests {
    @Test("Record round trips without an API key")
    func roundTrip() throws {
        let suite = "Otter.ActiveAccountTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsActiveAccountStore(defaults: defaults)
        let record = ActiveAccountRecord(
            namespace: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            serverURL: URL(string: "https://photos.example.com")!,
            serverVersion: SemanticVersion(major: 3, minor: 1, patch: 0),
            cacheLimitBytes: SettingsCacheLimit.gibibytes2.rawValue
        )

        try store.save(record)
        #expect(try store.load() == record)
        let persisted = try #require(defaults.data(forKey: UserDefaultsActiveAccountStore.defaultKey))
        let persistedText = String(decoding: persisted, as: UTF8.self)
        #expect(!persistedText.localizedCaseInsensitiveContains("api key"))

        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test("Corrupt record fails closed")
    func corrupt() throws {
        let suite = "Otter.ActiveAccountTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not-json".utf8), forKey: UserDefaultsActiveAccountStore.defaultKey)
        let store = UserDefaultsActiveAccountStore(defaults: defaults)

        #expect(throws: ActiveAccountStoreError.corruptRecord) { try store.load() }
    }

    @Test("A new credential on the same server receives an isolated namespace")
    func newCredentialNamespaceIsolation() {
        let previous = ActiveAccountRecord(
            namespace: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            serverURL: URL(string: "http://photos.local")!,
            serverVersion: SemanticVersion(major: 3, minor: 1, patch: 0),
            cacheLimitBytes: SettingsCacheLimit.gibibytes2.rawValue
        )

        let replacement = AccountNamespacePolicy.namespaceForNewConnection(existing: previous)

        #expect(replacement != previous.namespace)
    }
}
