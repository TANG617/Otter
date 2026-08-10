import Foundation
import Testing
@testable import Otter

private final class RecordingKeychainAccess: KeychainAccess, @unchecked Sendable {
    struct Write: Sendable {
        let data: Data
        let service: String
        let account: String
        let accessibility: KeychainAccessibility
    }

    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private(set) var lastWrite: Write?

    func readGenericPassword(service: String, account: String) throws -> Data? {
        lock.withLock { values[service + ":" + account] }
    }

    func writeGenericPassword(
        _ data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) throws {
        lock.withLock {
            values[service + ":" + account] = data
            lastWrite = Write(data: data, service: service, account: account, accessibility: accessibility)
        }
    }

    func removeGenericPassword(service: String, account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: service + ":" + account) }
    }

    func write() -> Write? {
        lock.withLock { lastWrite }
    }
}

@Suite("Device-only API key storage")
struct KeychainAPIKeyStoreTests {
    @Test("Key is namespaced, device-only, replaceable, and removable")
    func lifecycle() throws {
        let access = RecordingKeychainAccess()
        let store = KeychainAPIKeyStore(service: "test.otter", access: access)
        let namespace = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let first = try #require(APIKey("first-secret"))
        let second = try #require(APIKey("second-secret"))

        try store.save(first, accountNamespace: namespace)
        #expect(try store.apiKey(accountNamespace: namespace) == first)
        let write = try #require(access.write())
        #expect(write.service == "test.otter")
        #expect(write.account == "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
        switch write.accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            break
        }

        try store.save(second, accountNamespace: namespace)
        #expect(try store.apiKey(accountNamespace: namespace) == second)
        try store.remove(accountNamespace: namespace)
        #expect(try store.apiKey(accountNamespace: namespace) == nil)
    }

    @Test("Empty keys and invalid stored UTF-8 are rejected without disclosure")
    func invalidKeys() throws {
        #expect(APIKey(" \n ") == nil)
        let access = RecordingKeychainAccess()
        let store = KeychainAPIKeyStore(service: "test.otter", access: access)
        let namespace = UUID()
        try access.writeGenericPassword(
            Data([0xff]),
            service: "test.otter",
            account: namespace.uuidString.lowercased(),
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
        #expect(throws: APIKeyStoreError.invalidStoredValue) {
            try store.apiKey(accountNamespace: namespace)
        }
    }
}
