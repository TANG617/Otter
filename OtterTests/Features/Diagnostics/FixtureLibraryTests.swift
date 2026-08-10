import Foundation
import Testing
@testable import Otter

@Suite("Deterministic fixture library")
struct FixtureLibraryTests {
    @Test("Standard fixture contains ten thousand stable lightweight items")
    func standardFixtureIsDeterministic() {
        let first = FixtureLibraryGenerator.generate()
        let second = FixtureLibraryGenerator.generate()

        #expect(first.items.count == 10_000)
        #expect(first == second)
        #expect(Set(first.items.map(\.id)).count == first.items.count)
        #expect(first.items.first?.id.uuidString == "4F747465-7246-4000-8000-000000000000")
        #expect(first.items.last?.id.uuidString == "4F747465-7246-4000-8000-00000000270F")
    }

    @Test("Fixture content varies without losing determinism")
    func fixtureContentHasUsefulVariation() throws {
        let library = FixtureLibraryGenerator.generate()
        let first = try #require(library.items.first)
        let second = try #require(library.items.dropFirst().first)

        #expect(first.capturedAt > second.capturedAt)
        #expect(first.aspectRatio != second.aspectRatio)
        #expect(first.hasEdits)
        #expect(second.rating == -1)
    }

    @Test("One hundred thousand item stress scale is opt-in")
    func stressScaleFlag() {
        let defaults = FixtureLibraryConfiguration.resolved(arguments: [], environment: [:])
        let argument = FixtureLibraryConfiguration.resolved(
            arguments: ["Otter", "-OTTER_FIXTURE_ASSET_COUNT", "100000"],
            environment: [:]
        )
        let environment = FixtureLibraryConfiguration.resolved(
            arguments: [],
            environment: ["OTTER_FIXTURE_ASSET_COUNT": "100000"]
        )
        let unsupported = FixtureLibraryConfiguration.resolved(
            arguments: ["Otter", "-OTTER_FIXTURE_ASSET_COUNT", "50000"],
            environment: [:]
        )

        #expect(defaults.scale == .standard)
        #expect(argument.scale == .stress)
        #expect(environment.scale == .stress)
        #expect(unsupported.scale == .standard)
    }

    @Test("Safe diagnostics summary omits endpoint and credential fields")
    func safeDiagnosticsSummary() {
        let summary = DiagnosticsSnapshot.fixture.safeTextSummary

        #expect(!summary.contains(FixtureAccount.standard.serverURL.absoluteString))
        #expect(!summary.localizedCaseInsensitiveContains("api key"))
        #expect(summary.contains("Assets: 10000"))
    }
}
