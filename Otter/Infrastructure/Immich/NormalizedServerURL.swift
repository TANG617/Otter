import Foundation

enum ServerURLNormalizationError: Error, Equatable, LocalizedError {
    case empty
    case invalid
    case unsupportedScheme
    case credentialsNotAllowed
    case queryOrFragmentNotAllowed

    var errorDescription: String? {
        switch self {
        case .empty: "Enter an Immich server URL."
        case .invalid: "The Immich server URL is invalid."
        case .unsupportedScheme: "The Immich server URL must use HTTP or HTTPS."
        case .credentialsNotAllowed: "Credentials are not allowed in the server URL."
        case .queryOrFragmentNotAllowed: "Queries and fragments are not allowed in the server URL."
        }
    }
}

struct NormalizedServerURL: Hashable, Sendable, CustomStringConvertible {
    let url: URL

    init(_ input: String) throws {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ServerURLNormalizationError.empty
        }
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty else {
            throw ServerURLNormalizationError.invalid
        }
        guard scheme == "http" || scheme == "https" else {
            throw ServerURLNormalizationError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw ServerURLNormalizationError.credentialsNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw ServerURLNormalizationError.queryOrFragmentNotAllowed
        }

        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80) {
            components.port = nil
        }

        var pathComponents = components.percentEncodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        if pathComponents.last?.lowercased() == "api" {
            pathComponents.removeLast()
        }
        components.percentEncodedPath = pathComponents.isEmpty ? "" : "/" + pathComponents.joined(separator: "/")

        guard let normalized = components.url else {
            throw ServerURLNormalizationError.invalid
        }
        url = normalized
    }

    var description: String { url.absoluteString }

    func apiURL(pathComponents: [String], queryItems: [URLQueryItem] = []) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ServerURLNormalizationError.invalid
        }
        let base = components.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true)
        let escaped = try pathComponents.map { component -> String in
            guard !component.isEmpty,
                  !component.contains("/"),
                  let value = component.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#"))) else {
                throw ServerURLNormalizationError.invalid
            }
            return value
        }
        components.percentEncodedPath = "/" + (base.map(String.init) + ["api"] + escaped).joined(separator: "/")
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let result = components.url else {
            throw ServerURLNormalizationError.invalid
        }
        return result
    }
}

struct URLOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return nil
        }
        self.scheme = scheme
        self.host = host
        port = components.port ?? (scheme == "https" ? 443 : 80)
    }
}
