import Foundation

struct APIKey: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    private let value: String

    init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        self.value = trimmed
    }

    var description: String { "<redacted>" }
    var debugDescription: String { "APIKey(<redacted>)" }

    func headerValue() -> String {
        value
    }

    var encodedForKeychain: Data {
        Data(value.utf8)
    }
}

protocol APIKeyStoring: Sendable {
    func save(_ apiKey: APIKey, accountNamespace: UUID) throws
    func apiKey(accountNamespace: UUID) throws -> APIKey?
    func remove(accountNamespace: UUID) throws
}

enum APIKeyStoreError: Error, Equatable, LocalizedError {
    case keychain(status: Int32)
    case invalidStoredValue

    var errorDescription: String? {
        switch self {
        case let .keychain(status):
            "The credential store failed (status \(status))."
        case .invalidStoredValue:
            "The stored credential is invalid."
        }
    }
}
