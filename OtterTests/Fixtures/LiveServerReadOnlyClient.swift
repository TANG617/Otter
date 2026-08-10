import Foundation

struct LiveServerVersion: Decodable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
}

struct LiveServerAssetReference: Decodable, Sendable {
    let id: UUID
    let type: String
}

struct LiveServerThumbnailProbe: Sendable {
    let byteCount: Int
    let mimeType: String
}

enum LiveServerReadOnlyError: Error, Equatable, LocalizedError, Sendable {
    case invalidEndpoint
    case nonHTTPResponse
    case unexpectedStatus(Int)
    case unexpectedContentType
    case emptyMedia
    case invalidResponseShape

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "The configured server could not form a same-origin test endpoint."
        case .nonHTTPResponse:
            "The live-server test received a non-HTTP response."
        case let .unexpectedStatus(statusCode):
            "The live-server test received HTTP status \(statusCode)."
        case .unexpectedContentType:
            "The thumbnail endpoint did not return image media."
        case .emptyMedia:
            "The thumbnail endpoint returned an empty body."
        case .invalidResponseShape:
            "The live-server response did not contain the required public contract fields."
        }
    }
}

final class LiveServerReadOnlyClient: @unchecked Sendable {
    private let configuration: LiveServerTestConfiguration
    private let redirectDelegate: SameOriginRedirectDelegate
    private let session: URLSession

    init(configuration: LiveServerTestConfiguration) throws {
        self.configuration = configuration
        let redirectDelegate = try SameOriginRedirectDelegate(serverURL: configuration.serverURL)
        self.redirectDelegate = redirectDelegate

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        session = URLSession(
            configuration: sessionConfiguration,
            delegate: redirectDelegate,
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }

    func version() async throws -> LiveServerVersion {
        let request = try request(path: ["api", "server", "version"])
        let data = try await responseData(for: request)
        do {
            return try JSONDecoder().decode(LiveServerVersion.self, from: data)
        } catch {
            throw LiveServerReadOnlyError.invalidResponseShape
        }
    }

    func firstImageAsset() async throws -> LiveServerAssetReference? {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "page": 1,
                "size": 1,
                "type": "IMAGE",
                "withExif": true
            ],
            options: [.sortedKeys]
        )
        let request = try request(
            path: ["api", "search", "metadata"],
            method: "POST",
            contentType: "application/json",
            body: body
        )
        let data = try await responseData(for: request)
        do {
            return try JSONDecoder().decode(SearchResponse.self, from: data).assets.items.first
        } catch {
            throw LiveServerReadOnlyError.invalidResponseShape
        }
    }

    func assetDetail(id: UUID) async throws -> LiveServerAssetReference {
        let request = try request(path: ["api", "assets", id.uuidString.lowercased()])
        let data = try await responseData(for: request)
        do {
            return try JSONDecoder().decode(LiveServerAssetReference.self, from: data)
        } catch {
            throw LiveServerReadOnlyError.invalidResponseShape
        }
    }

    func thumbnail(id: UUID) async throws -> LiveServerThumbnailProbe {
        let request = try request(
            path: ["api", "assets", id.uuidString.lowercased(), "thumbnail"],
            queryItems: [
                URLQueryItem(name: "edited", value: "true"),
                URLQueryItem(name: "size", value: "thumbnail")
            ]
        )
        let (data, response) = try await response(for: request)
        guard !data.isEmpty else { throw LiveServerReadOnlyError.emptyMedia }
        guard let mimeType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              mimeType.hasPrefix("image/") else {
            throw LiveServerReadOnlyError.unexpectedContentType
        }
        return LiveServerThumbnailProbe(byteCount: data.count, mimeType: mimeType)
    }

    private func request(
        path: [String],
        queryItems: [URLQueryItem] = [],
        method: String = "GET",
        contentType: String? = nil,
        body: Data? = nil
    ) throws -> URLRequest {
        var endpoint = configuration.serverURL
        for component in path {
            endpoint.appendPathComponent(component)
        }

        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw LiveServerReadOnlyError.invalidEndpoint
        }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url,
              SameOriginRedirectDelegate.isSameOrigin(url, configuration.serverURL) else {
            throw LiveServerReadOnlyError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(configuration.apiKey, forHTTPHeaderField: "x-api-key")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        try await response(for: request).data
    }

    private func response(for request: URLRequest) async throws -> (data: Data, response: HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw LiveServerReadOnlyError.nonHTTPResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw LiveServerReadOnlyError.unexpectedStatus(response.statusCode)
        }
        return (data, response)
    }
}

private extension LiveServerReadOnlyClient {
    struct SearchResponse: Decodable {
        let assets: AssetPage
    }

    struct AssetPage: Decodable {
        let items: [LiveServerAssetReference]
    }
}

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let serverURL: URL

    init(serverURL: URL) throws {
        guard Self.originComponents(for: serverURL) != nil else {
            throw LiveServerReadOnlyError.invalidEndpoint
        }
        self.serverURL = serverURL
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              Self.isSameOrigin(destination, serverURL) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    static func isSameOrigin(_ first: URL, _ second: URL) -> Bool {
        originComponents(for: first) == originComponents(for: second)
    }

    private static func originComponents(for url: URL) -> Origin? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }
        let defaultPort = scheme == "https" ? 443 : 80
        return Origin(scheme: scheme, host: host, port: components.port ?? defaultPort)
    }

    private struct Origin: Equatable {
        let scheme: String
        let host: String
        let port: Int
    }
}
