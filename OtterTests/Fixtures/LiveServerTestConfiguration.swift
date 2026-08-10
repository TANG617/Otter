import Foundation

struct LiveServerTestConfiguration: Sendable, CustomDebugStringConvertible {
    static let enabledEnvironmentKey = "OTTER_RUN_LIVE_SERVER_TESTS"
    static let serverURLEnvironmentKey = "OTTER_TEST_SERVER_URL"
    static let apiKeyEnvironmentKey = "OTTER_TEST_API_KEY"

    let serverURL: URL
    let apiKey: String

    var debugDescription: String {
        "LiveServerTestConfiguration(serverURL: <redacted>, apiKey: <redacted>)"
    }

    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[enabledEnvironmentKey] == "YES"
    }

    static func required(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LiveServerTestConfiguration {
        guard isEnabled(environment: environment) else {
            throw LiveServerConfigurationError.notEnabled
        }
        guard let serverURLText = environment[serverURLEnvironmentKey],
              let apiKey = environment[apiKeyEnvironmentKey],
              !apiKey.isEmpty else {
            throw LiveServerConfigurationError.missingRequiredEnvironment
        }
        guard !apiKey.contains(where: \Character.isWhitespace) else {
            throw LiveServerConfigurationError.invalidCredentialShape
        }

        guard let components = URLComponents(string: serverURLText),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              let serverURL = components.url else {
            throw LiveServerConfigurationError.invalidServerURL
        }

        return LiveServerTestConfiguration(serverURL: serverURL, apiKey: apiKey)
    }
}

enum LiveServerConfigurationError: Error, Equatable, LocalizedError, Sendable {
    case notEnabled
    case missingRequiredEnvironment
    case invalidServerURL
    case invalidCredentialShape

    var errorDescription: String? {
        switch self {
        case .notEnabled:
            "Live-server tests are disabled."
        case .missingRequiredEnvironment:
            "Live-server tests require the server URL and credential environment variables."
        case .invalidServerURL:
            "The live-server URL must be an HTTP or HTTPS origin/path without credentials, query, or fragment."
        case .invalidCredentialShape:
            "The live-server credential is empty or contains whitespace."
        }
    }
}
