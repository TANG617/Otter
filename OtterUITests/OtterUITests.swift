import XCTest

final class OtterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSignedOutLaunchShowsOnboardingShell() {
        let app = OtterUIApplication.signedOut()
        app.launch()

        app.staticTexts["Otter"].assertExists()
        XCTAssertTrue(app.staticTexts["Native Photos for Immich"].exists)
    }

    @MainActor
    func testFixtureLaunchShowsLibraryShell() {
        let app = OtterUIApplication.fixtures()
        app.launch()

        app.staticTexts["Fixture Library"].assertExists()
        XCTAssertTrue(app.staticTexts["The deterministic fixture environment is ready."].exists)
    }
}
