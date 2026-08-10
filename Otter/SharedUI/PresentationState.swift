import Foundation

struct PresentationFailure: Equatable, Sendable {
    let title: String
    let message: String
    let systemImage: String

    init(title: String, message: String, systemImage: String = "exclamationmark.triangle") {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }
}

enum LoadState<Value: Equatable & Sendable>: Equatable, Sendable {
    case idle
    case loading
    case loaded(Value)
    case failed(PresentationFailure)

    var isLoading: Bool {
        self == .loading
    }

    var value: Value? {
        guard case let .loaded(value) = self else { return nil }
        return value
    }

    var failure: PresentationFailure? {
        guard case let .failed(failure) = self else { return nil }
        return failure
    }

    func map<MappedValue: Equatable & Sendable>(
        _ transform: (Value) -> MappedValue
    ) -> LoadState<MappedValue> {
        switch self {
        case .idle:
            .idle
        case .loading:
            .loading
        case let .loaded(value):
            .loaded(transform(value))
        case let .failed(failure):
            .failed(failure)
        }
    }
}

enum ActionState: Equatable, Sendable {
    case idle
    case working
    case succeeded(String)
    case failed(PresentationFailure)

    var isWorking: Bool {
        self == .working
    }
}

enum ActionOutcome: Equatable, Sendable {
    case success(message: String)
    case failure(PresentationFailure)
}
