import Foundation
import Observation

@MainActor
@Observable
final class AppSession {
    enum State: Equatable, Sendable {
        case signedOut
        case connecting
        case active(accountNamespace: UUID)
        case fixture
        case authenticationInvalid
    }

    private(set) var state: State

    init(initialState: State = .signedOut) {
        state = initialState
    }

    func transition(to state: State) {
        self.state = state
    }
}

