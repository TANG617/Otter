import XCTest
@testable import Otter

final class LiveServerReadOnlyTests: XCTestCase {
    func testPublicReadOnlyContract() async throws {
        guard LiveServerTestConfiguration.isEnabled() else {
            throw XCTSkip(
                "Set OTTER_RUN_LIVE_SERVER_TESTS=YES with OTTER_TEST_SERVER_URL and OTTER_TEST_API_KEY to run the read-only live contract."
            )
        }

        let configuration = try LiveServerTestConfiguration.required()
        let client = try LiveServerReadOnlyClient(configuration: configuration)

        let version = try await client.version()
        guard version.major > 0, version.minor >= 0, version.patch >= 0 else {
            XCTFail("The server version probe returned invalid semantic-version components.")
            return
        }

        guard let asset = try await client.firstImageAsset() else {
            throw XCTSkip(
                "The read-only metadata search succeeded but returned no readable image asset for detail and thumbnail probes."
            )
        }

        let detail = try await client.assetDetail(id: asset.id)
        guard detail.id == asset.id, detail.type == "IMAGE" else {
            XCTFail("The asset-detail response did not match the selected image asset.")
            return
        }

        let thumbnail = try await client.thumbnail(id: asset.id)
        XCTAssertGreaterThan(thumbnail.byteCount, 0)
        XCTAssertTrue(thumbnail.mimeType.hasPrefix("image/"))
    }
}
