import Foundation
import Testing
@testable import Otter

@Suite("Onboarding form state")
struct OnboardingFormStateTests {
    @Test("Server input defaults to HTTPS and removes trailing slashes")
    func normalizesServerURL() {
        var form = OnboardingFormState()
        form.setServerURLText("  Photos.EXAMPLE.com/immich///  ")

        #expect(form.normalizedServerURL?.absoluteString == "https://photos.example.com/immich")
        #expect(form.serverURLIssue == nil)
    }

    @Test("HTTP, ports, and reverse proxy paths remain explicit")
    func preservesExplicitServerComponents() {
        let form = OnboardingFormState(serverURLText: "http://localhost:2283/photos/")

        #expect(form.normalizedServerURL?.absoluteString == "http://localhost:2283/photos")
    }

    @Test("Unsupported and ambiguous URLs are rejected")
    func rejectsInvalidURLs() {
        #expect(OnboardingFormState(serverURLText: "ftp://example.com").serverURLIssue == .unsupportedScheme)
        #expect(OnboardingFormState(serverURLText: "https://example.com?token=value").serverURLIssue == .invalidServerURL)
        #expect(OnboardingFormState(serverURLText: "https://user@example.com").serverURLIssue == .invalidServerURL)
    }

    @Test("API key input trims edges but rejects embedded whitespace")
    func validatesAPIKeyShape() {
        let valid = OnboardingFormState(apiKeyText: "  value-without-whitespace  ")
        let invalid = OnboardingFormState(apiKeyText: "two values")

        #expect(valid.normalizedAPIKey == "value-without-whitespace")
        #expect(valid.apiKeyIssue == nil)
        #expect(invalid.normalizedAPIKey == nil)
        #expect(invalid.apiKeyIssue == .apiKeyContainsWhitespace)
    }

    @Test("Editing input cancels the observable validation revision")
    func rejectsStaleValidationResult() {
        var form = OnboardingFormState(
            serverURLText: "https://example.com",
            apiKeyText: "value-without-whitespace"
        )
        form.beginValidation()
        let staleRevision = form.validationRevision
        form.setServerURLText("https://other.example.com")

        let applied = form.completeValidation(
            .connected(ConnectedServerSummary(serverVersion: "1.0", accountDisplayName: "Account")),
            revision: staleRevision
        )

        #expect(!applied)
        #expect(form.connectionState == .idle)
    }

    @Test("Current validation result updates connection state")
    func appliesCurrentValidationResult() {
        var form = OnboardingFormState(
            serverURLText: "https://example.com",
            apiKeyText: "value-without-whitespace"
        )
        form.beginValidation()
        let revision = form.validationRevision
        let summary = ConnectedServerSummary(serverVersion: "1.0", accountDisplayName: "Account")

        let applied = form.completeValidation(.connected(summary), revision: revision)

        #expect(applied)
        #expect(form.connectionState == .connected(summary))
    }
}
