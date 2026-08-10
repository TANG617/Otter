import Foundation

enum ImmichClientError: Error, Equatable, LocalizedError {
    case invalidResponse
    case invalidPayload
    case invalidContinuation
    case wrongAccount
    case authenticationInvalid
    case permissionDenied
    case notFound
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int)
    case transport(code: Int?)
    case crossOriginResponse

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The server returned an invalid response."
        case .invalidPayload: "The server returned data Otter could not read."
        case .invalidContinuation: "The server returned an invalid search continuation."
        case .wrongAccount: "The request does not belong to this account."
        case .authenticationInvalid: "The Immich API key is no longer valid."
        case .permissionDenied: "The API key does not have permission for this operation."
        case .notFound: "The requested Immich resource was not found."
        case let .rateLimited(retryAfter):
            retryAfter.map { "The server is rate limiting requests. Retry in \(Int($0)) seconds." }
                ?? "The server is rate limiting requests."
        case let .server(status): "The Immich server failed the request (HTTP \(status))."
        case let .transport(code):
            code.map { "The network request failed (code \($0))." } ?? "The network request failed."
        case .crossOriginResponse: "A protected request was redirected to another server."
        }
    }
}

enum ImmichHTTPResponseValidator {
    static func validate(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw ImmichClientError.authenticationInvalid
        case 403:
            throw ImmichClientError.permissionDenied
        case 404:
            throw ImmichClientError.notFound
        case 429:
            throw ImmichClientError.rateLimited(retryAfter: retryAfter(from: response))
        default:
            throw ImmichClientError.server(status: response.statusCode)
        }
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return nil
        }
        if let seconds = TimeInterval(value), seconds >= 0 {
            return seconds
        }
        return nil
    }
}
