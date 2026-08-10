import Foundation

struct OnboardingConnectRequest: Equatable, Sendable {
    let serverURL: URL
    let apiKey: String
}

struct ConnectedServerSummary: Equatable, Sendable {
    let serverVersion: String
    let accountDisplayName: String
}

enum ConnectionValidationFailure: Equatable, Sendable {
    case invalidCredentials
    case serverUnavailable
    case incompatibleServer
    case insufficientPermissions
    case transportSecurity
    case unknown

    var presentation: PresentationFailure {
        switch self {
        case .invalidCredentials:
            PresentationFailure(
                title: "API Key Rejected",
                message: "Check the API key and make sure it is still active.",
                systemImage: "key.slash"
            )
        case .serverUnavailable:
            PresentationFailure(
                title: "Server Unavailable",
                message: "Check the server address and network connection, then try again.",
                systemImage: "network.slash"
            )
        case .incompatibleServer:
            PresentationFailure(
                title: "Server Not Supported",
                message: "Otter could not use the required Immich API on this server.",
                systemImage: "exclamationmark.arrow.triangle.2.circlepath"
            )
        case .insufficientPermissions:
            PresentationFailure(
                title: "More Access Required",
                message: "Create an API key with permission to view assets and metadata.",
                systemImage: "lock.trianglebadge.exclamationmark"
            )
        case .transportSecurity:
            PresentationFailure(
                title: "Secure Connection Required",
                message: "Use trusted HTTPS, or a local-network HTTP server allowed by iOS.",
                systemImage: "lock.slash"
            )
        case .unknown:
            PresentationFailure(
                title: "Connection Failed",
                message: "Otter could not validate this server. Try again in a moment."
            )
        }
    }
}

enum ConnectionValidationResult: Equatable, Sendable {
    case connected(ConnectedServerSummary)
    case failed(ConnectionValidationFailure)
}

enum OnboardingConnectionState: Equatable, Sendable {
    case idle
    case validating
    case connected(ConnectedServerSummary)
    case failed(ConnectionValidationFailure)
}

enum OnboardingFieldIssue: Equatable, Sendable {
    case required
    case invalidServerURL
    case unsupportedScheme
    case apiKeyContainsWhitespace

    var message: String {
        switch self {
        case .required:
            "This field is required."
        case .invalidServerURL:
            "Enter a server name or an HTTP or HTTPS URL."
        case .unsupportedScheme:
            "The server URL must use HTTP or HTTPS."
        case .apiKeyContainsWhitespace:
            "The API key cannot contain spaces or line breaks."
        }
    }
}

struct OnboardingFormState: Equatable, Sendable {
    private(set) var serverURLText: String
    private(set) var apiKeyText: String
    private(set) var connectionState: OnboardingConnectionState
    private(set) var validationRevision: UInt64

    init(
        serverURLText: String = "",
        apiKeyText: String = "",
        connectionState: OnboardingConnectionState = .idle,
        validationRevision: UInt64 = 0
    ) {
        self.serverURLText = serverURLText
        self.apiKeyText = apiKeyText
        self.connectionState = connectionState
        self.validationRevision = validationRevision
    }

    var normalizedServerURL: URL? {
        ServerURLNormalizer.normalizedURL(from: serverURLText)
    }

    var normalizedAPIKey: String? {
        let key = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \Character.isWhitespace) else { return nil }
        return key
    }

    var serverURLIssue: OnboardingFieldIssue? {
        let input = serverURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return .required }

        if let scheme = ServerURLNormalizer.explicitScheme(in: input),
           !ServerURLNormalizer.supportedSchemes.contains(scheme.lowercased()) {
            return .unsupportedScheme
        }

        return normalizedServerURL == nil ? .invalidServerURL : nil
    }

    var apiKeyIssue: OnboardingFieldIssue? {
        let key = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .required }
        return key.contains(where: \Character.isWhitespace) ? .apiKeyContainsWhitespace : nil
    }

    var canValidateConnection: Bool {
        serverURLIssue == nil && apiKeyIssue == nil && connectionState != .validating
    }

    var connectRequest: OnboardingConnectRequest? {
        guard let serverURL = normalizedServerURL, let apiKey = normalizedAPIKey else { return nil }
        return OnboardingConnectRequest(serverURL: serverURL, apiKey: apiKey)
    }

    mutating func setServerURLText(_ value: String) {
        guard value != serverURLText else { return }
        serverURLText = value
        invalidateValidation()
    }

    mutating func setAPIKeyText(_ value: String) {
        guard value != apiKeyText else { return }
        apiKeyText = value
        invalidateValidation()
    }

    mutating func beginValidation() {
        guard canValidateConnection else { return }
        validationRevision &+= 1
        connectionState = .validating
    }

    @discardableResult
    mutating func completeValidation(
        _ result: ConnectionValidationResult,
        revision: UInt64
    ) -> Bool {
        guard validationRevision == revision, connectionState == .validating else { return false }

        switch result {
        case let .connected(summary):
            connectionState = .connected(summary)
        case let .failed(failure):
            connectionState = .failed(failure)
        }
        return true
    }

    private mutating func invalidateValidation() {
        validationRevision &+= 1
        connectionState = .idle
    }
}

enum ServerURLNormalizer {
    static let supportedSchemes: Set<String> = ["http", "https"]

    static func explicitScheme(in input: String) -> String? {
        guard let separator = input.range(of: "://") else { return nil }
        return String(input[..<separator.lowerBound])
    }

    static func normalizedURL(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let candidate = explicitScheme(in: trimmed) == nil ? "https://\(trimmed)" : trimmed
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              supportedSchemes.contains(scheme),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            return nil
        }

        if let port = components.port, !(1...65_535).contains(port) {
            return nil
        }

        components.scheme = scheme
        components.host = host.lowercased()
        components.percentEncodedPath = normalizedPath(components.percentEncodedPath)
        return components.url
    }

    private static func normalizedPath(_ path: String) -> String {
        var normalized = path
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
