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
    func testDebugTestCredentialsPrefillOnboarding() {
        let app = OtterUIApplication.signedOut(environment: [
            "OTTER_TEST_SERVER_URL": "https://photos.example.com",
            "OTTER_TEST_API_KEY": "ui-test-key"
        ])
        app.launch()

        let serverURL = app.textFields["onboarding.serverURL"]
        serverURL.assertExists()
        XCTAssertEqual(serverURL.value as? String, "https://photos.example.com")
        app.secureTextFields["onboarding.apiKey"].assertExists()

        let connect = app.buttons["onboarding.connect"]
        connect.assertExists()
        XCTAssertTrue(connect.isEnabled)
    }

    @MainActor
    func testFixtureTimelineScrollViewerRatingAndDirectDownload() {
        let app = OtterUIApplication.fixtures()
        app.launch()

        app.navigationBars["Library"].assertExists(timeout: 20)
        let timeline = app.scrollViews.firstMatch
        timeline.assertExists()
        timeline.swipeUp(velocity: .fast)
        timeline.swipeDown(velocity: .fast)

        openFirstVisiblePhoto(in: app)
        let media = app.images.matching(identifierPrefix: "viewer.media.").firstMatch
        media.assertExists()
        let initialMediaIdentifier = media.identifier
        let initialPageLabel = media.label
        XCTAssertTrue(initialPageLabel.contains("1 of"), "Viewer must expose Photo X of Y.")
        XCTAssertFalse(app.buttons["viewer.settings"].exists)
        XCTAssertFalse(app.buttons.matching(identifierPrefix: "library.timeline.asset.").firstMatch.exists)

        showViewerChrome(in: app)
        let download = app.buttons["viewer.download"]
        download.tap()
        waitForDownload(in: app, button: download)

        let secondThumbnail = app.buttons.matching(
            NSPredicate(format: "label == %@", "Photo 2 of 200")
        ).firstMatch
        secondThumbnail.assertExists()
        secondThumbnail.tap()
        let viewer = app.descendants(matching: .any)["viewer.screen"]
        let secondPage = NSPredicate(format: "value CONTAINS %@", "Photo 2 of")
        expectation(for: secondPage, evaluatedWith: viewer)
        waitForExpectations(timeout: 5)
        let nextMedia = app.images
            .matching(identifierPrefix: "viewer.media.")
            .matching(NSPredicate(format: "label CONTAINS %@", "2 of"))
            .firstMatch
        nextMedia.assertExists(timeout: 5)
        XCTAssertNotEqual(nextMedia.identifier, initialMediaIdentifier)
        XCTAssertNotEqual(nextMedia.label, initialPageLabel)

        showViewerChrome(in: app)
        tapCenter(of: app.buttons["viewer.variant"])
        let original = app.descendants(matching: .any)["Original"]
        original.assertExists()
        original.tap()
        app.images.matching(identifierPrefix: "viewer.media.").firstMatch.assertExists()

        showViewerChrome(in: app)
        let rating = app.buttons["viewer.rate"]
        rating.assertExists()
        tapCenter(of: rating)
        let fiveStars = app.buttons["viewer.rating.5"]
        fiveStars.assertExists()
        fiveStars.tap()
        let ratedFive = NSPredicate { evaluated, _ in
            (evaluated as? XCUIElement)?.label.contains("5 Stars") == true
        }
        expectation(for: ratedFive, evaluatedWith: rating)
        waitForExpectations(timeout: 5)

        showViewerChrome(in: app)
        tapCenter(of: rating)
        let favorite = app.descendants(matching: .any)["viewer.favorite"]
        favorite.assertExists()
        favorite.tap()
        let favoriteSelected = NSPredicate { evaluated, _ in
            (evaluated as? XCUIElement)?.value as? String == "Favourite"
        }
        expectation(for: favoriteSelected, evaluatedWith: rating)
        waitForExpectations(timeout: 5)

        showViewerChrome(in: app)
        download.tap()
        waitForDownload(in: app, button: download)
        XCTAssertFalse(app.navigationBars["Download"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["export.screen"].exists)

        showViewerChrome(in: app)
        tapCenter(of: app.buttons["viewer.close"])
        app.navigationBars["Library"].assertExists()
    }

    @MainActor
    func testFixtureFilmstripLoadsDistantThumbnailBeforeSelection() {
        let app = OtterUIApplication.fixtures()
        app.launch()
        openFirstVisiblePhoto(in: app)

        let initialMedia = app.images.matching(identifierPrefix: "viewer.media.").firstMatch
        initialMedia.assertExists()
        let initialIdentifier = initialMedia.identifier
        let filmstrip = app.scrollViews["viewer.filmstrip"]
        filmstrip.assertExists()
        let photo20 = app.buttons["viewer.filmstrip.photo.20"]
        for _ in 0..<4 where !photo20.exists {
            filmstrip.swipeLeft(velocity: .fast)
        }
        photo20.assertExists()
        let loaded = NSPredicate(format: "value == %@", "Thumbnail loaded")
        expectation(for: loaded, evaluatedWith: photo20)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(
            app.images.matching(identifierPrefix: "viewer.media.").firstMatch.identifier,
            initialIdentifier
        )

        photo20.tap()
        let twentieth = app.images
            .matching(identifierPrefix: "viewer.media.")
            .matching(NSPredicate(format: "label CONTAINS %@", "20 of"))
            .firstMatch
        twentieth.assertExists(timeout: 5)
    }

    @MainActor
    func testFixtureViewerGesturePagingBounceAndDismissal() {
        let app = OtterUIApplication.fixtures()
        app.launch()
        openFirstVisiblePhoto(in: app)

        let initialMedia = app.images.matching(identifierPrefix: "viewer.media.").firstMatch
        initialMedia.assertExists()
        let initialIdentifier = initialMedia.identifier
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5))
            .press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.5))
            )
        let viewer = app.descendants(matching: .any)["viewer.screen"]
        let changedPage = NSPredicate(format: "value CONTAINS %@", "Photo 2 of")
        expectation(for: changedPage, evaluatedWith: viewer)
        waitForExpectations(timeout: 5)
        let currentMedia = app.images
            .matching(identifierPrefix: "viewer.media.")
            .matching(NSPredicate(format: "label CONTAINS %@", "2 of"))
            .firstMatch
        currentMedia.assertExists()
        XCTAssertNotEqual(currentMedia.identifier, initialIdentifier)
        let pagedIdentifier = currentMedia.identifier

        currentMedia.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
            .press(
                forDuration: 0.2,
                thenDragTo: currentMedia.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.50))
            )
        app.descendants(matching: .any)["viewer.screen"].assertExists()
        XCTAssertTrue(String(describing: viewer.value).contains("Photo 2 of"))
        app.images[pagedIdentifier].assertExists()

        let mediaAfterBounce = app.images[pagedIdentifier]
        mediaAfterBounce.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(
                forDuration: 0.08,
                thenDragTo: mediaAfterBounce.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88))
            )
        app.navigationBars["Library"].assertExists(timeout: 5)
    }

    @MainActor
    func testFixtureChromeTapToggleAndModalAccessibilityIsolation() {
        let app = OtterUIApplication.fixtures()
        app.launch()
        openFirstVisiblePhoto(in: app)

        let viewer = app.descendants(matching: .any)["viewer.screen"]
        viewer.assertExists()
        let chromeVisible = NSPredicate(format: "value CONTAINS %@", "Controls visible")
        expectation(for: chromeVisible, evaluatedWith: viewer)
        waitForExpectations(timeout: 2)

        let unexpectedAutoHide = expectation(
            for: NSPredicate(format: "value CONTAINS %@", "Controls hidden"),
            evaluatedWith: viewer
        )
        unexpectedAutoHide.isInverted = true
        waitForExpectations(timeout: 3.5)
        XCTAssertTrue(app.buttons["viewer.close"].isHittable)

        let media = app.images.matching(identifierPrefix: "viewer.media.").firstMatch
        media.assertExists()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let chromeHidden = NSPredicate(format: "value CONTAINS %@", "Controls hidden")
        expectation(for: chromeHidden, evaluatedWith: viewer)
        waitForExpectations(timeout: 2)
        XCTAssertFalse(app.buttons["viewer.close"].exists)

        showViewerChrome(in: app)
        app.buttons["viewer.info"].tap()
        app.navigationBars["Info"].assertExists()
        assertUnavailable(app.buttons["viewer.close"])
        assertUnavailable(app.images.matching(identifierPrefix: "viewer.media.").firstMatch)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Info"].waitForNonExistence(timeout: 5))
        showViewerChrome(in: app)

        tapCenter(of: app.buttons["viewer.close"])
        app.navigationBars["Library"].assertExists()
        openSettings(in: app)
        app.descendants(matching: .any)["settings.screen"].assertExists()
        assertUnavailable(app.buttons.matching(identifierPrefix: "library.timeline.asset.").firstMatch)
        assertUnavailable(app.buttons["library.timeline.more"])
    }

    @MainActor
    func testFixtureRatingFailureRollsBack() {
        let app = OtterUIApplication.fixtures(
            environment: ["OTTER_FIXTURE_RATING_FAILURE": "YES"]
        )
        app.launch()
        openFirstVisiblePhoto(in: app)

        showViewerChrome(in: app)
        let rating = app.buttons["viewer.rate"]
        rating.assertExists()
        tapCenter(of: rating)
        let fiveStars = app.buttons["viewer.rating.5"]
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
        showViewerChrome(in: app)
        let download = app.buttons["viewer.download"]
        download.tap()

        let retry = NSPredicate(format: "label == %@", "Retry Download")
        expectation(for: retry, evaluatedWith: download)
        waitForExpectations(timeout: 5)
        app.descendants(matching: .any)["viewer.download.status"].assertExists()
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Original was not substituted")
        ).firstMatch.assertExists()
        XCTAssertFalse(app.navigationBars["Download"].exists)
    }

    @MainActor
    func testFixtureSettingsDiagnosticsAndRotation() {
        let app = OtterUIApplication.fixtures()
        app.launch()

        openSettings(in: app)
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
    private func openSettings(in app: XCUIApplication) {
        app.navigationBars["Library"].assertExists(timeout: 20)
        let settings = app.buttons["library.timeline.settings"]
        settings.assertExists()
        settings.tap()
    }

    @MainActor
    private func showViewerChrome(in app: XCUIApplication) {
        let viewer = app.descendants(matching: .any)["viewer.screen"]
        viewer.assertExists()
        if !String(describing: viewer.value).contains("Controls visible") {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let controlsVisible = NSPredicate(format: "value CONTAINS %@", "Controls visible")
        expectation(for: controlsVisible, evaluatedWith: viewer)
        waitForExpectations(timeout: 2)
        XCTAssertTrue(app.buttons["viewer.close"].isHittable)
    }

    @MainActor
    private func tapCenter(of element: XCUIElement) {
        // Xcode 16.4/iOS 18.5 can fail Menu's implicit AXScrollToVisible even
        // when the identified button has a visible frame. A direct center tap
        // exercises the same control without depending on that XCTest action.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    @MainActor
    private func waitForDownload(in app: XCUIApplication, button: XCUIElement) {
        let saved = NSPredicate { evaluated, _ in
            let element = evaluated as? XCUIElement
            return element?.label == "Photo Saved"
                && String(describing: element?.value).contains("Complete")
        }
        expectation(for: saved, evaluatedWith: button)
        waitForExpectations(timeout: 5)
        XCTAssertFalse(app.navigationBars["Download"].exists)
    }

    @MainActor
    private func assertUnavailable(
        _ element: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertFalse(
            element.exists && element.isHittable,
            "Expected background element '\(element.identifier)' to be hidden or non-interactive.",
            file: file,
            line: line
        )
    }
}
