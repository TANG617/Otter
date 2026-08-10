import Foundation

struct ImmichRequestBuilder: Sendable {
    let serverURL: NormalizedServerURL
    let apiKey: APIKey

    func request(
        method: String,
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        body: Data? = nil,
        authenticated: Bool = true
    ) throws -> URLRequest {
        let url = try serverURL.apiURL(pathComponents: pathComponents, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            request.setValue(apiKey.headerValue(), forHTTPHeaderField: "x-api-key")
        }
        return request
    }
}

enum ImmichMediaVariant: Hashable, Sendable {
    case current
    case original
}

enum ImmichRemoteRepresentation: String, Hashable, Sendable {
    case thumbnail
    case preview
    case fullsize
    case original
}

enum ImmichMediaRequestError: Error, Equatable {
    case originalDerivativeUnavailable
}

struct ImmichMediaEndpointBuilder: Sendable {
    private let requestBuilder: ImmichRequestBuilder

    init(serverURL: NormalizedServerURL, apiKey: APIKey) {
        requestBuilder = ImmichRequestBuilder(serverURL: serverURL, apiKey: apiKey)
    }

    func request(
        assetID: UUID,
        variant: ImmichMediaVariant,
        representation: ImmichRemoteRepresentation
    ) throws -> URLRequest {
        let edited = variant == .current ? "true" : "false"
        switch representation {
        case .original:
            return try requestBuilder.request(
                method: "GET",
                pathComponents: ["assets", assetID.uuidString.lowercased(), "original"],
                queryItems: [URLQueryItem(name: "edited", value: edited)]
            )
        case .thumbnail, .preview, .fullsize:
            guard variant == .current else {
                throw ImmichMediaRequestError.originalDerivativeUnavailable
            }
            return try requestBuilder.request(
                method: "GET",
                pathComponents: ["assets", assetID.uuidString.lowercased(), "thumbnail"],
                queryItems: [
                    URLQueryItem(name: "size", value: representation.rawValue),
                    URLQueryItem(name: "edited", value: "true"),
                ]
            )
        }
    }
}
