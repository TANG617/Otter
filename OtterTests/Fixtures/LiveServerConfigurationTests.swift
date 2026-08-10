import XCTest
@testable import Otter

final class LiveServerConfigurationTests: XCTestCase {
    func testEnvironmentConfigurationIsValidWhenLiveTestsAreEnabled() throws {
        guard LiveServerTestConfiguration.isEnabled() else {
            throw XCTSkip(
                "Set OTTER_RUN_LIVE_SERVER_TESTS=YES with OTTER_TEST_SERVER_URL and OTTER_TEST_API_KEY to validate the live-server test configuration."
            )
        }

        _ = try LiveServerTestConfiguration.required()
    }
}
