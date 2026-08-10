import Foundation

final class PrefetchToken: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        let current = lock.withLock { () -> Task<Void, Never>? in
            defer { task = nil }
            return task
        }
        current?.cancel()
    }

    deinit { cancel() }
}
