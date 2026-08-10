import Foundation
import Security

enum KeychainAccessibility: Sendable {
    case afterFirstUnlockThisDeviceOnly
}

protocol KeychainAccess: Sendable {
    func readGenericPassword(service: String, account: String) throws -> Data?
    func writeGenericPassword(
        _ data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) throws
    func removeGenericPassword(service: String, account: String) throws
}

final class SystemKeychainAccess: KeychainAccess, @unchecked Sendable {
    func readGenericPassword(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw APIKeyStoreError.invalidStoredValue
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw APIKeyStoreError.keychain(status: status)
        }
    }

    func writeGenericPassword(
        _ data: Data,
        service: String,
        account: String,
        accessibility: KeychainAccessibility
    ) throws {
        var query = baseQuery(service: service, account: account)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = accessibilityValue(accessibility)

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw APIKeyStoreError.keychain(status: addStatus)
        }

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibilityValue(accessibility),
        ]
        let updateStatus = SecItemUpdate(
            baseQuery(service: service, account: account) as CFDictionary,
            attributes as CFDictionary
        )
        guard updateStatus == errSecSuccess else {
            throw APIKeyStoreError.keychain(status: updateStatus)
        }
    }

    func removeGenericPassword(service: String, account: String) throws {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw APIKeyStoreError.keychain(status: status)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func accessibilityValue(_ accessibility: KeychainAccessibility) -> CFString {
        switch accessibility {
        case .afterFirstUnlockThisDeviceOnly:
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
    }
}

struct KeychainAPIKeyStore: APIKeyStoring, Sendable {
    static let defaultService = "com.tang617.otter.api-key"

    private let service: String
    private let access: any KeychainAccess

    init(
        service: String = KeychainAPIKeyStore.defaultService,
        access: any KeychainAccess = SystemKeychainAccess()
    ) {
        self.service = service
        self.access = access
    }

    func save(_ apiKey: APIKey, accountNamespace: UUID) throws {
        try access.writeGenericPassword(
            apiKey.encodedForKeychain,
            service: service,
            account: accountNamespace.uuidString.lowercased(),
            accessibility: .afterFirstUnlockThisDeviceOnly
        )
    }

    func apiKey(accountNamespace: UUID) throws -> APIKey? {
        guard let data = try access.readGenericPassword(
            service: service,
            account: accountNamespace.uuidString.lowercased()
        ) else {
            return nil
        }
        guard let string = String(data: data, encoding: .utf8), let key = APIKey(string) else {
            throw APIKeyStoreError.invalidStoredValue
        }
        return key
    }

    func remove(accountNamespace: UUID) throws {
        try access.removeGenericPassword(
            service: service,
            account: accountNamespace.uuidString.lowercased()
        )
    }
}
