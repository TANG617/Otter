import Foundation
import Testing
@testable import Otter

@Suite("Onboarding form state")
struct OnboardingFormStateTests {
    @Test("Debug test credentials prefill a valid connection form")
    func prefillsTestCredentials() {
        let form = OnboardingFormState.testDefaults(environment: [
            "OTTER_TEST_SERVER_URL": " https://photos.example.com/ ",
            "OTTER_TEST_API_KEY": " test-key "
        ])

        #expect(form.serverURLText == "https://photos.example.com/")
        #expect(form.apiKeyText == "test-key")
        #expect(form.canValidateConnection)
    }

    @Test("Incomplete or invalid test credentials never partially prefill the form", arguments: [
        ["OTTER_TEST_SERVER_URL": "https://photos.example.com"],
        ["OTTER_TEST_API_KEY": "test-key"],
        ["OTTER_TEST_SERVER_URL": "ftp://photos.example.com", "OTTER_TEST_API_KEY": "test-key"],
        ["OTTER_TEST_SERVER_URL": "https://photos.example.com", "OTTER_TEST_API_KEY": "two values"]
    ])
    func rejectsUnsafeTestCredentialDefaults(environment: [String: String]) {
        let form = OnboardingFormState.testDefaults(environment: environment)

        #expect(form == OnboardingFormState())
    }

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

    @Test("Successful validation waits for secure activation before connecting")
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
        #expect(form.connectionState == .activating(summary))
        #expect(!form.canValidateConnection)

        let activated = form.completeActivation(.activated, revision: revision)

        #expect(activated)
        #expect(form.connectionState == .connected(summary))
    }

    @Test("Activation failure remains on onboarding with an actionable error")
    func surfacesActivationFailure() {
        var form = OnboardingFormState(
            serverURLText: "https://example.com",
            apiKeyText: "value-without-whitespace"
        )
        form.beginValidation()
        let revision = form.validationRevision
        let summary = ConnectedServerSummary(serverVersion: "3.1.0", accountDisplayName: "Server")
        let validated = form.completeValidation(.connected(summary), revision: revision)
        #expect(validated)

        let completed = form.completeActivation(
            .failed(.credentialStorage),
            revision: revision
        )

        #expect(completed)
        #expect(form.connectionState == .failed(.credentialStorage))
        #expect(form.canValidateConnection)
        #expect(ConnectionValidationFailure.credentialStorage.presentation.title == "Couldn’t Secure Account")
    }
}
