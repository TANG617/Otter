import Foundation
import XCTest

struct WallClockSamples: Equatable, Sendable {
    let durations: [Duration]

    var minimum: Duration? { durations.min() }
    var maximum: Duration? { durations.max() }
    var median: Duration? { percentile(0.5) }
    var p95: Duration? { percentile(0.95) }

    func percentile(_ fraction: Double) -> Duration? {
        guard !durations.isEmpty else { return nil }
        let sorted = durations.sorted()
        let clamped = min(max(fraction, 0), 1)
        let index = Int((Double(sorted.count - 1) * clamped).rounded(.up))
        return sorted[index]
    }
}

enum PerformanceTestSupport {
    static let enabledEnvironmentKey = "OTTER_RUN_PERFORMANCE_TESTS"

    static var standardXCTestMetrics: [XCTMetric] {
        [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()]
    }

    static func measureWallClock(
        warmupCount: Int = 1,
        iterationCount: Int = 5,
        operation: @Sendable () async throws -> Void
    ) async rethrows -> WallClockSamples {
        precondition(warmupCount >= 0, "Warmup count must be nonnegative")
        precondition(iterationCount > 0, "Iteration count must be positive")

        for _ in 0..<warmupCount {
            try await operation()
        }

        let clock = ContinuousClock()
        var durations: [Duration] = []
        durations.reserveCapacity(iterationCount)

        for _ in 0..<iterationCount {
            let start = clock.now
            try await operation()
            durations.append(start.duration(to: clock.now))
        }
        return WallClockSamples(durations: durations)
    }

    static func requireEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
        guard environment[enabledEnvironmentKey] == "YES" else {
            throw XCTSkip(
                "Set \(enabledEnvironmentKey)=YES to run opt-in performance measurements."
            )
        }
    }
}
