import Foundation
import ImageIO
import Testing
@testable import Otter

@Suite("Test infrastructure fixtures", .serialized)
struct TestInfrastructureTests {
    @Test("URL protocol records concurrent requests exactly once")
    func mockURLProtocolRecordsConcurrentRequests() async throws {
        MockURLProtocol.install { request, sequenceNumber in
            let body = Data("\(sequenceNumber):\(request.httpMethod ?? "")".utf8)
            return .response(MockURLProtocol.HTTPResponse(body: body))
        }
        defer { MockURLProtocol.reset() }

        let session = URLSession(configuration: MockURLProtocol.ephemeralSessionConfiguration())
        let responses = try await withThrowingTaskGroup(of: String.self, returning: [String].self) { group in
            for index in 0..<24 {
                group.addTask {
                    var request = URLRequest(url: URL(string: "https://fixture.invalid/assets/\(index)")!)
                    request.httpMethod = "GET"
                    let (data, response) = try await session.data(for: request)
                    #expect((response as? HTTPURLResponse)?.statusCode == 200)
                    return String(decoding: data, as: UTF8.self)
                }
            }

            var values: [String] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        let records = MockURLProtocol.recordedRequests
        #expect(records.count == 24)
        #expect(Set(records.map(\.sequenceNumber)).count == 24)
        #expect(responses.allSatisfy { $0.hasSuffix(":GET") })
    }

    @Test("URL protocol response queues are deterministic")
    func mockURLProtocolResponseSequence() async throws {
        MockURLProtocol.install(
            outcomes: [
                .response(.init(statusCode: 202, body: Data("first".utf8))),
                .response(.init(statusCode: 204))
            ]
        )
        defer { MockURLProtocol.reset() }

        let session = URLSession(configuration: MockURLProtocol.ephemeralSessionConfiguration())
        let first = try await session.data(from: URL(string: "https://fixture.invalid/first")!)
        let second = try await session.data(from: URL(string: "https://fixture.invalid/second")!)
        let third = await #expect(throws: URLError.self) {
            try await session.data(from: URL(string: "https://fixture.invalid/fallback")!)
        }

        #expect((first.1 as? HTTPURLResponse)?.statusCode == 202)
        #expect(String(decoding: first.0, as: UTF8.self) == "first")
        #expect((second.1 as? HTTPURLResponse)?.statusCode == 204)
        #expect(third != nil)
    }

    @Test("Synthetic PNG and JPEG encode requested dimensions")
    func syntheticImagesExposeDimensions() throws {
        let size = SyntheticImageSize(width: 96, height: 64)
        let png = try SyntheticImageFixtures.png(size: size, seed: 0x123456)
        let jpeg = try SyntheticImageFixtures.jpeg(size: size, seed: 0x654321)

        #expect(try dimensions(of: png) == size)
        #expect(try dimensions(of: jpeg) == size)
        #expect(png.count > 0)
        #expect(jpeg.count > 0)
    }

    @Test("Metadata helpers provide lazy deterministic 10k and 100k libraries")
    func syntheticMetadataScales() throws {
        let standard = SyntheticMetadataLibrary(scale: .standard)
        let stress = SyntheticMetadataLibrary(scale: .stress)

        #expect(standard.count == 10_000)
        #expect(stress.count == 100_000)
        #expect(standard[9_999] == SyntheticMetadataLibrary.makeItem(at: 9_999))
        #expect(stress[99_999].id.uuidString == "54657374-4D65-4000-8000-00000001869F")

        let pageData = try standard.searchResponseData(startingAt: 9_990, limit: 20)
        let json = try #require(JSONSerialization.jsonObject(with: pageData) as? [String: Any])
        let assets = try #require(json["assets"] as? [String: Any])
        let items = try #require(assets["items"] as? [[String: Any]])
        #expect(items.count == 10)
        #expect(assets["nextPage"] == nil)
    }

    @Test("Wall-clock helper returns ordered summary values")
    func performanceSamples() async throws {
        let samples = await PerformanceTestSupport.measureWallClock(
            warmupCount: 0,
            iterationCount: 3
        ) {
            await Task.yield()
        }

        #expect(samples.durations.count == 3)
        #expect(try #require(samples.minimum) <= #require(samples.median))
        #expect(try #require(samples.median) <= #require(samples.p95))
        #expect(try #require(samples.p95) <= #require(samples.maximum))
    }

    private func dimensions(of data: Data) throws -> SyntheticImageSize {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try #require(properties[kCGImagePropertyPixelWidth] as? Int)
        let height = try #require(properties[kCGImagePropertyPixelHeight] as? Int)
        return SyntheticImageSize(width: width, height: height)
    }
}
