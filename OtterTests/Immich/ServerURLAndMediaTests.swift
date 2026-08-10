import Foundation
import Testing
@testable import Otter

@Suite("Immich URL, authentication, and media endpoints")
struct ServerURLAndMediaTests {
    @Test("Normalization canonicalizes origin and optional API suffix")
    func normalization() throws {
        let server = try NormalizedServerURL("  HTTPS://Example.COM:443/immich/api///  ")
        #expect(server.url.absoluteString == "https://example.com/immich")
        let endpoint = try server.apiURL(pathComponents: ["server", "version"])
        #expect(endpoint.absoluteString == "https://example.com/immich/api/server/version")
    }

    @Test("Normalization rejects URL credential and data-bearing components")
    func normalizationRejections() {
        #expect(throws: ServerURLNormalizationError.credentialsNotAllowed) {
            try NormalizedServerURL("https://user:password@example.com")
        }
        #expect(throws: ServerURLNormalizationError.queryOrFragmentNotAllowed) {
            try NormalizedServerURL("https://example.com?apiKey=secret")
        }
        #expect(throws: ServerURLNormalizationError.unsupportedScheme) {
            try NormalizedServerURL("ftp://example.com")
        }
    }

    @Test("API key is header-only and never included in endpoint URL")
    func headerAuthentication() throws {
        let key = try #require(APIKey("super-secret"))
        let builder = ImmichRequestBuilder(
            serverURL: try NormalizedServerURL("https://photos.example.com"),
            apiKey: key
        )
        let request = try builder.request(method: "GET", pathComponents: ["assets", "abc"])
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "super-secret")
        #expect(request.url?.absoluteString.contains("super-secret") == false)
        #expect(request.description.contains("super-secret") == false)
        #expect(key.description == "<redacted>")
        #expect(key.debugDescription.contains("super-secret") == false)
        #expect(APIKey("has whitespace") == nil)
    }

    @Test("Current derivatives and original bytes use exact edited semantics")
    func mediaEndpoints() throws {
        let key = try #require(APIKey("key"))
        let builder = ImmichMediaEndpointBuilder(
            serverURL: try NormalizedServerURL("https://photos.example.com/base"),
            apiKey: key
        )
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        let preview = try builder.request(assetID: id, variant: .current, representation: .preview)
        #expect(preview.url?.path == "/base/api/assets/11111111-1111-1111-1111-111111111111/thumbnail")
        #expect(URLComponents(url: preview.url!, resolvingAgainstBaseURL: false)?.queryItems == [
            URLQueryItem(name: "size", value: "preview"),
            URLQueryItem(name: "edited", value: "true"),
        ])

        let current = try builder.request(assetID: id, variant: .current, representation: .original)
        let original = try builder.request(assetID: id, variant: .original, representation: .original)
        #expect(current.url?.query == "edited=true")
        #expect(original.url?.query == "edited=false")
        #expect(throws: ImmichMediaRequestError.originalDerivativeUnavailable) {
            try builder.request(assetID: id, variant: .original, representation: .thumbnail)
        }
    }

    @Test("Redirect credentials are retained only on the normalized origin")
    func redirectPolicy() throws {
        let server = try NormalizedServerURL("https://photos.example.com/base")
        let policy = SameOriginRedirectPolicy(serverURL: server)
        let key = try #require(APIKey("secret"))
        let sameOrigin = URLRequest(url: URL(string: "https://PHOTOS.example.com:443/base/file")!)
        let authorized = try policy.authorizedRequest(sameOrigin, apiKey: key, includeCredential: true)
        #expect(authorized.value(forHTTPHeaderField: "x-api-key") == "secret")

        let crossOrigin = URLRequest(url: URL(string: "https://cdn.example.com/file")!)
        #expect(throws: RedirectPolicyError.crossOrigin) {
            try policy.authorizedRequest(crossOrigin, apiKey: key, includeCredential: true)
        }
    }
}
