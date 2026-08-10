import Foundation
import Testing
@testable import Otter

private actor StubImmichTransport: ImmichHTTPTransport {
    struct Stub: Sendable {
        let data: Data
        let status: Int
        let headers: [String: String]
        let responseURL: URL?

        init(data: Data = Data(), status: Int = 200, headers: [String: String] = [:], responseURL: URL? = nil) {
            self.data = data
            self.status = status
            self.headers = headers
            self.responseURL = responseURL
        }
    }

    private var stubs: [Stub]
    private var capturedRequests: [URLRequest] = []

    init(_ stubs: [Stub]) {
        self.stubs = stubs
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        capturedRequests.append(request)
        let stub = stubs.removeFirst()
        let response = HTTPURLResponse(
            url: stub.responseURL ?? request.url!,
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )!
        return (stub.data, response)
    }

    func requests() -> [URLRequest] {
        capturedRequests
    }
}

@Suite("Immich v3.1 client contract")
struct ImmichClientContractTests {
    private let account = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!

    @Test("Version probe is unauthenticated and reports API-key sync unavailable")
    func versionProbe() async throws {
        let transport = StubImmichTransport([
            .init(data: Data(#"{"major":3,"minor":1,"patch":0,"prerelease":"beta.1"}"#.utf8)),
        ])
        let client = try makeClient(transport: transport)

        let result = try await client.probeVersion()

        #expect(result.version.description == "3.1.0-beta.1")
        #expect(result.capabilities.metadataSearch == .available)
        #expect(result.capabilities.syncStream == .unavailable(.apiKeyAuthenticationUnsupported))
        let request = try #require(await transport.requests().first)
        #expect(request.url?.path == "/api/server/version")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }

    @Test("Search maps minimum fields, ignores total, and deduplicates each page")
    func searchMapping() async throws {
        let id = "11111111-1111-1111-1111-111111111111"
        let payload = """
            {
              "assets": {
                "items": [
                  {
                    "id": "\(id)", "type": "IMAGE",
                    "ownerId": "22222222-2222-2222-2222-222222222222",
                    "localDateTime": "2026-08-10T10:00:00.123Z",
                    "fileCreatedAt": "2026-08-09T10:00:00Z",
                    "createdAt": "2026-08-08T10:00:00Z",
                    "updatedAt": "2026-08-10T11:00:00Z",
                    "width": 4032, "height": 3024,
                    "thumbhash": "hash", "checksum": "sum",
                    "originalFileName": "photo.jpg", "originalMimeType": "image/jpeg",
                    "isFavorite": true, "isEdited": true,
                    "isArchived": false, "isTrashed": false, "visibility": "timeline",
                    "exifInfo": { "rating": 5 }
                  },
                  {
                    "id": "\(id)", "type": "IMAGE",
                    "createdAt": "2026-08-08T10:00:00Z",
                    "updatedAt": "2026-08-10T11:00:00Z"
                  }
                ],
                "nextPage": 2,
                "total": 0
              }
            }
            """
        let transport = StubImmichTransport([.init(data: Data(payload.utf8))])
        let client = try makeClient(transport: transport)

        let page = try await client.searchAssets(
            AssetSearchRequest(pageSize: 250),
            accountNamespace: account
        )

        #expect(page.assets.count == 1)
        #expect(page.assets[0].rating == .five)
        #expect(page.assets[0].width == 4_032)
        #expect(page.nextContinuation == "2")
        let request = try #require(await transport.requests().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/search/metadata")
        #expect(request.value(forHTTPHeaderField: "x-api-key") == "secret")
        let body = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["page"] as? Int == 1)
        #expect(json["size"] as? Int == 250)
        #expect(json["withExif"] as? Bool == true)
        #expect(json["type"] as? String == "IMAGE")
        #expect(String(data: body, encoding: .utf8)?.contains("timeline/") == false)
    }

    @Test("Rating clear is encoded as explicit null")
    func ratingNull() async throws {
        let transport = StubImmichTransport([.init()])
        let client = try makeClient(transport: transport)
        let assetID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

        try await client.writeRating(nil, assetID: assetID, accountNamespace: account)

        let request = try #require(await transport.requests().first)
        #expect(request.httpMethod == "PUT")
        #expect(String(data: request.httpBody!, encoding: .utf8) == #"{"rating":null}"#)
    }

    @Test("HTTP status is mapped without response bodies or credentials")
    func errorMapping() async throws {
        let cases: [(Int, [String: String], ImmichClientError)] = [
            (401, [:], .authenticationInvalid),
            (403, [:], .permissionDenied),
            (404, [:], .notFound),
            (429, ["Retry-After": "7"], .rateLimited(retryAfter: 7)),
            (503, [:], .server(status: 503)),
        ]
        for (status, headers, expected) in cases {
            let transport = StubImmichTransport([.init(data: Data("secret server body".utf8), status: status, headers: headers)])
            let client = try makeClient(transport: transport)
            do {
                _ = try await client.probeVersion()
                Issue.record("Expected status \(status) to fail")
            } catch let error as ImmichClientError {
                #expect(error == expected)
                #expect(error.localizedDescription.contains("secret server body") == false)
                #expect(error.localizedDescription.contains("secret") == false)
            }
        }
    }

    @Test("Protected final response cannot cross the configured origin")
    func crossOriginResponse() async throws {
        let transport = StubImmichTransport([
            .init(
                data: Data(#"{"major":3,"minor":1,"patch":0}"#.utf8),
                responseURL: URL(string: "https://other.example.com/api/server/version")!
            ),
        ])
        let client = try makeClient(transport: transport)
        await #expect(throws: ImmichClientError.crossOriginResponse) {
            try await client.probeVersion()
        }
    }

    private func makeClient(transport: any ImmichHTTPTransport) throws -> ImmichClient {
        let key = try #require(APIKey("secret"))
        return ImmichClient(
            accountNamespace: account,
            serverURL: try NormalizedServerURL("https://photos.example.com"),
            apiKey: key,
            transport: transport
        )
    }
}
