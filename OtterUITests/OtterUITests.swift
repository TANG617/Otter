import XCTest

final class OtterUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testSignedOutLaunchShowsUsableOnboarding() {
        let app = OtterUIApplication.signedOut()
        app.launch()

        app.navigationBars["Connect to Immich"].assertExists()
        app.textFields["onboarding.serverURL"].assertExists()
        app.secureTextFields["onboarding.apiKey"].assertExists()
        let connect = app.buttons["onboarding.connect"]
        connect.assertExists()
        XCTAssertFalse(connect.isEnabled)
    }

    @MainActor
    func testFixtureTimelineScrollViewerRatingAndExport() {
        let app = OtterUIApplication.fixtures()
        app.launch()

        app.navigationBars["Library"].assertExists(timeout: 20)
        let timeline = app.scrollViews.firstMatch
        timeline.assertExists()
        timeline.swipeUp(velocity: .fast)
        timeline.swipeDown(velocity: .fast)

        openFirstVisiblePhoto(in: app)
        app.images.matching(identifierPrefix: "viewer.media.").firstMatch.assertExists()
        app.buttons["viewer.next"].assertExists()
        app.buttons["viewer.next"].tap()

        let original = app.descendants(matching: .any)["Original"]
        original.assertExists()
        original.tap()
        app.images.matching(identifierPrefix: "viewer.media.").firstMatch.assertExists()

        let rating = app.buttons["viewer.rate"]
        rating.assertExists()
        tapCenter(of: rating)
        let fiveStars = app.buttons["5 Stars"]
        fiveStars.assertExists()
        fiveStars.tap()
        XCTAssertTrue(rating.label.contains("5 Stars"))

        app.buttons["viewer.download"].tap()
        app.navigationBars["Download"].assertExists()
        app.descendants(matching: .any)["export.variant.current"].assertExists()
        app.descendants(matching: .any)["export.variant.original"].assertExists()
        app.buttons["export.photos"].assertExists()
        app.buttons["export.files"].assertExists()
    }

    @MainActor
    func testFixtureRatingFailureRollsBack() {
        let app = OtterUIApplication.fixtures(
            environment: ["OTTER_FIXTURE_RATING_FAILURE": "YES"]
        )
        app.launch()
        openFirstVisiblePhoto(in: app)

        let rating = app.buttons["viewer.rate"]
        rating.assertExists()
        tapCenter(of: rating)
        let fiveStars = app.buttons["5 Stars"]
        fiveStars.assertExists()
        fiveStars.tap()
        let rolledBack = NSPredicate { evaluated, _ in
            (evaluated as? XCUIElement)?.label.contains("Unrated") == true
        }
        expectation(for: rolledBack, evaluatedWith: rating)
        waitForExpectations(timeout: 5)
    }

    @MainActor
    func testCurrentExportUnavailableIsExplicit() {
        let app = OtterUIApplication.fixtures(
            environment: ["OTTER_FIXTURE_CURRENT_EXPORT_UNAVAILABLE": "YES"]
        )
        app.launch()
        openFirstVisiblePhoto(in: app)
        app.buttons["viewer.download"].tap()

        app.navigationBars["Download"].assertExists()
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Original will never be substituted")
        ).firstMatch.assertExists()
        XCTAssertFalse(app.buttons["export.photos"].isEnabled)
        XCTAssertFalse(app.buttons["export.files"].isEnabled)
    }

    @MainActor
    func testFixtureSettingsDiagnosticsAndRotation() {
        let app = OtterUIApplication.fixtures()
        app.launch()

        let settings = app.buttons["library.timeline.settings"]
        settings.assertExists(timeout: 20)
        settings.tap()
        app.navigationBars["Settings"].assertExists()
        app.descendants(matching: .any)["settings.cache.limit"].assertExists()
        app.buttons["settings.diagnostics"].tap()
        app.navigationBars["Diagnostics"].assertExists()
        app.descendants(matching: .any)["diagnostics.connection.status"].assertExists()
        app.descendants(matching: .any)["diagnostics.assetCount"].assertExists()

        app.swipeDown()
        app.terminate()
        let rotated = OtterUIApplication.fixtures()
        XCUIDevice.shared.orientation = .landscapeLeft
        rotated.launch()
        openFirstVisiblePhoto(in: rotated)
        rotated.images.matching(identifierPrefix: "viewer.media.").firstMatch.assertExists()
        XCUIDevice.shared.orientation = .portrait
    }

    @MainActor
    private func openFirstVisiblePhoto(in app: XCUIApplication) {
        app.navigationBars["Library"].assertExists(timeout: 20)
        let firstPhoto = app.buttons.matching(identifierPrefix: "library.timeline.asset.").firstMatch
        firstPhoto.assertExists(timeout: 20)
        firstPhoto.tap()
        app.buttons["viewer.close"].assertExists(timeout: 20)
    }

    @MainActor
    private func tapCenter(of element: XCUIElement) {
        // Xcode 16.4/iOS 18.5 can fail Menu's implicit AXScrollToVisible even
        // when the identified button has a visible frame. A direct center tap
        // exercises the same control without depending on that XCTest action.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }
}
