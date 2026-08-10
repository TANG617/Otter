import Foundation
import XCTest
@testable import Otter

final class LiveImmichTests: XCTestCase {
    func testVersionAndFirstSearchPageWhenEnvironmentIsConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let serverValue = environment["OTTER_TEST_SERVER_URL"],
              let keyValue = environment["OTTER_TEST_API_KEY"] else {
            throw XCTSkip("Set OTTER_TEST_SERVER_URL and OTTER_TEST_API_KEY to run live Immich verification.")
        }
        let serverURL = try NormalizedServerURL(serverValue)
        guard let apiKey = APIKey(keyValue) else {
            XCTFail("OTTER_TEST_API_KEY is empty")
            return
        }
        let namespace = UUID()
        let client = ImmichClient(
            accountNamespace: namespace,
            serverURL: serverURL,
            apiKey: apiKey
        )

        let probe = try await client.probeVersion()
        XCTAssertGreaterThanOrEqual(probe.version.major, 3)
        _ = try await client.searchAssets(
            AssetSearchRequest(pageSize: 1),
            accountNamespace: namespace
        )
    }
}
