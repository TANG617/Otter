import Foundation
import Testing
@testable import Otter

private final class ImmichContractURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path
        let bodyContainsInternalTimeline = request.httpBody
            .flatMap({ String(data: $0, encoding: .utf8) })?
            .contains("/timeline/") ?? false
        let status: Int
        let payload: Data
        if path == "/api/server/version",
           request.value(forHTTPHeaderField: "x-api-key") == nil {
            status = 200
            payload = Data(#"{"major":3,"minor":1,"patch":0}"#.utf8)
        } else if path == "/api/search/metadata",
                  request.httpMethod == "POST",
                  request.value(forHTTPHeaderField: "x-api-key") == "contract-secret",
                  request.url?.query == nil,
                  !bodyContainsInternalTimeline {
            status = 200
            payload = Data(#"{"assets":{"items":[],"nextPage":null,"total":999999}}"#.utf8)
        } else {
            status = 418
            payload = Data()
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("URLProtocol Immich boundary")
struct URLProtocolContractTests {
    @Test("Production URLSession transport preserves auth and public endpoints")
    func transportContract() async throws {
        let serverURL = try NormalizedServerURL("https://photos.example.com")
        let apiKey = try #require(APIKey("contract-secret"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImmichContractURLProtocol.self]
        let transport = URLSessionImmichTransport(
            serverURL: serverURL,
            apiKey: apiKey,
            configuration: configuration
        )
        let account = UUID()
        let client = ImmichClient(
            accountNamespace: account,
            serverURL: serverURL,
            apiKey: apiKey,
            transport: transport
        )

        #expect(try await client.probeVersion().version == SemanticVersion(major: 3, minor: 1, patch: 0))
        let page = try await client.searchAssets(
            AssetSearchRequest(pageSize: 1),
            accountNamespace: account
        )
        #expect(page.assets.isEmpty)
        #expect(page.nextContinuation == nil)
    }
}
