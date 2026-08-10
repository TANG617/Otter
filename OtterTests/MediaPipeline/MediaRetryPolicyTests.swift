import Foundation
import Testing
@testable import Otter

@Suite("Media retry policy")
struct MediaRetryPolicyTests {
    private let policy = MediaRetryPolicy(visibleRetryLimit: 1)

    @Test("Visible timeout retries once while prefetch does not")
    func timeout() {
        #expect(policy.delay(for: URLError(.timedOut), attempt: 0, priority: .visible) != nil)
        #expect(policy.delay(for: URLError(.timedOut), attempt: 1, priority: .visible) == nil)
        #expect(policy.delay(for: URLError(.timedOut), attempt: 0, priority: .prefetch) == nil)
    }

    @Test("Cancellation and offline do not retry")
    func cancellation() {
        #expect(policy.delay(for: CancellationError(), attempt: 0, priority: .interactive) == nil)
        #expect(policy.delay(for: URLError(.notConnectedToInternet), attempt: 0, priority: .interactive) == nil)
    }
}
