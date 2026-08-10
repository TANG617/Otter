import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let session: AppSession
    let usesFixtures: Bool

    init(session: AppSession, usesFixtures: Bool) {
        self.session = session
        self.usesFixtures = usesFixtures
    }

    static func makeDefault(processInfo: ProcessInfo = .processInfo) -> AppEnvironment {
        let arguments = processInfo.arguments
        let environment = processInfo.environment
        let fixtureArgumentIndex = arguments.firstIndex(of: "-OTTER_USE_FIXTURES")
        let fixtureArgumentValue = fixtureArgumentIndex.flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
        let usesFixtures = fixtureArgumentValue == "YES" || environment["OTTER_USE_FIXTURES"] == "YES"
        let session = AppSession(initialState: usesFixtures ? .fixture : .signedOut)
        return AppEnvironment(session: session, usesFixtures: usesFixtures)
    }
}

