import XCTest

enum FixtureLaunchScale: Int, Sendable {
    case standard = 10_000
    case stress = 100_000
}

@MainActor
enum OtterUIApplication {
    static func signedOut(
        additionalArguments: [String] = [],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        configuredApplication(
            arguments: additionalArguments,
            environment: environment.merging(["OTTER_USE_FIXTURES": "NO"]) { current, _ in current }
        )
    }

    static func fixtures(
        scale: FixtureLaunchScale = .standard,
        additionalArguments: [String] = [],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        var arguments = ["-OTTER_USE_FIXTURES", "YES"]
        if scale == .stress {
            arguments += ["-OTTER_FIXTURE_ASSET_COUNT", String(scale.rawValue)]
        }
        arguments += additionalArguments
        return configuredApplication(arguments: arguments, environment: environment)
    }

    private static func configuredApplication(
        arguments: [String],
        environment: [String: String]
    ) -> XCUIApplication {
        let application = XCUIApplication()
        application.launchArguments = arguments
        application.launchEnvironment = environment
        return application
    }
}

extension XCUIElement {
    @MainActor
    @discardableResult
    func assertExists(
        timeout: TimeInterval = 10,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let exists = waitForExistence(timeout: timeout)
        XCTAssertTrue(exists, "Expected element '\(identifier)' to exist.", file: file, line: line)
        return exists
    }
}

extension XCUIElementQuery {
    @MainActor
    func matching(identifierPrefix prefix: String) -> XCUIElementQuery {
        matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
    }
}
