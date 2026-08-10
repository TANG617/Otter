import Foundation

enum RedirectPolicyError: Error, Equatable {
    case invalidDestination
    case crossOrigin
}

struct SameOriginRedirectPolicy: Sendable {
    private let allowedOrigin: URLOrigin

    init(serverURL: NormalizedServerURL) {
        // NormalizedServerURL construction guarantees an HTTP(S) origin.
        allowedOrigin = URLOrigin(url: serverURL.url)!
    }

    func authorizedRequest(_ request: URLRequest, apiKey: APIKey, includeCredential: Bool) throws -> URLRequest {
        guard let destination = request.url, let origin = URLOrigin(url: destination) else {
            throw RedirectPolicyError.invalidDestination
        }
        guard origin == allowedOrigin else {
            throw RedirectPolicyError.crossOrigin
        }
        var authorized = request
        if includeCredential {
            authorized.setValue(apiKey.headerValue(), forHTTPHeaderField: "x-api-key")
        } else {
            authorized.setValue(nil, forHTTPHeaderField: "x-api-key")
        }
        return authorized
    }
}

final class ImmichRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: SameOriginRedirectPolicy
    private let apiKey: APIKey

    init(serverURL: NormalizedServerURL, apiKey: APIKey) {
        policy = SameOriginRedirectPolicy(serverURL: serverURL)
        self.apiKey = apiKey
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let originalHadCredential = task.originalRequest?.value(forHTTPHeaderField: "x-api-key") != nil
        let redirected = try? policy.authorizedRequest(
            request,
            apiKey: apiKey,
            includeCredential: originalHadCredential
        )
        completionHandler(redirected)
    }
}
