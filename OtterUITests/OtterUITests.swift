import XCTest

final class OtterUITests: XCTestCase {
    @MainActor
    func testFixtureLaunchesLibraryShell() {
        let app = XCUIApplication()
        app.launchArguments = ["-OTTER_USE_FIXTURES", "YES"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Fixture Library"].waitForExistence(timeout: 10))
    }
}
