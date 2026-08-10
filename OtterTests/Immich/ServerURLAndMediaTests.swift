import Foundation
import Testing
@testable import Otter

private final class MediaTransportSuccessURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "image/jpeg"]
              ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x01, 0x02, 0x03]))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { }
}

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

    @Test("Media redirects reject cross-origin and fullsize-to-Original substitution")
    func mediaRedirectPolicy() throws {
        let fullsize = try #require(
            URL(string: "https://photos.example.com/api/assets/asset/thumbnail?size=fullsize&edited=true")
        )
        let preview = try #require(
            URL(string: "https://photos.example.com/api/assets/asset/thumbnail?size=preview&edited=true")
        )
        let original = try #require(
            URL(string: "https://photos.example.com/api/assets/asset/original?edited=true")
        )
        let crossOrigin = try #require(URL(string: "https://cdn.example.com/media"))

        #expect(MediaRedirectPolicy.sameOrigin(fullsize, preview))
        #expect(!MediaRedirectPolicy.sameOrigin(fullsize, crossOrigin))
        #expect(MediaRedirectPolicy.shouldRejectOriginalSubstitution(
            initialURL: fullsize,
            destinationURL: original
        ))
        #expect(!MediaRedirectPolicy.shouldRejectOriginalSubstitution(
            initialURL: preview,
            destinationURL: original
        ))

        let metadata = MediaResponseMetadata(
            initialURL: fullsize,
            finalURL: fullsize,
            redirects: [
                MediaRedirectHop(
                    sourceURL: fullsize,
                    destinationURL: original,
                    statusCode: 302,
                    disposition: .rejectedOriginalSubstitution
                ),
            ]
        )
        #expect(metadata.wasRedirected)
        #expect(metadata.nominalFullsizeResolvedToOriginal)
    }

    @Test("Media transport exposes initial and final response URL metadata")
    func mediaTransportResponseMetadata() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaTransportSuccessURLProtocol.self]
        let transport = try URLSessionMediaTransport(
            configuration: configuration,
            stagingDirectory: root.appendingPathComponent("staging")
        )
        let url = try #require(
            URL(string: "https://photos.example.com/api/assets/asset/thumbnail?size=fullsize&edited=true")
        )

        let downloaded = try await transport.download(URLRequest(url: url))
        defer { try? FileManager.default.removeItem(at: downloaded.fileURL) }

        #expect(downloaded.responseMetadata?.initialURL == url)
        #expect(downloaded.responseMetadata?.finalURL == url)
        #expect(downloaded.responseMetadata?.wasRedirected == false)
    }
}
