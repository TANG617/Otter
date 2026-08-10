import Foundation

protocol ImmichHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

final class URLSessionImmichTransport: ImmichHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let redirectDelegate: ImmichRedirectDelegate

    init(
        serverURL: NormalizedServerURL,
        apiKey: APIKey,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        redirectDelegate = ImmichRedirectDelegate(serverURL: serverURL, apiKey: apiKey)
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImmichClientError.invalidResponse
        }
        return (data, httpResponse)
    }
}
