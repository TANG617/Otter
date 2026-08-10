import SwiftUI

@MainActor
struct OnboardingView: View {
    typealias ValidateConnection = @Sendable (OnboardingConnectRequest) async -> ConnectionValidationResult
    typealias DidConnect = @MainActor (OnboardingConnectRequest, ConnectedServerSummary) -> Void

    @State private var form: OnboardingFormState
    @FocusState private var focusedField: Field?

    private let validateConnection: ValidateConnection
    private let onConnected: DidConnect

    init(
        initialState: OnboardingFormState = OnboardingFormState(),
        validateConnection: @escaping ValidateConnection,
        onConnected: @escaping DidConnect
    ) {
        _form = State(initialValue: initialState)
        self.validateConnection = validateConnection
        self.onConnected = onConnected
    }

    var body: some View {
        NavigationStack {
            Form {
                introductionSection
                credentialsSection
                connectionSection
            }
            .formStyle(.grouped)
            .navigationTitle("Connect to Immich")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier(AccessibilityID.Onboarding.screen)
            .task(id: form.validationRevision) {
                await validateCurrentRequestIfNeeded()
            }
        }
    }

    private var introductionSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 38, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("Otter")
                    .font(.largeTitle.bold())

                Text("A fast, native photo experience for your Immich library.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 8)
            .accessibilityElement(children: .combine)
        }
    }

    private var credentialsSection: some View {
        Section {
            TextField("Server URL", text: serverURLBinding)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focusedField, equals: .serverURL)
                .onSubmit { focusedField = .apiKey }
                .accessibilityIdentifier(AccessibilityID.Onboarding.serverURL)

            if shouldShowServerURLIssue, let issue = form.serverURLIssue {
                validationMessage(issue.message, identifier: AccessibilityID.Onboarding.serverURLError)
            }

            SecureField("API key", text: apiKeyBinding)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                .focused($focusedField, equals: .apiKey)
                .onSubmit(beginValidation)
                .accessibilityIdentifier(AccessibilityID.Onboarding.apiKey)

            if shouldShowAPIKeyIssue, let issue = form.apiKeyIssue {
                validationMessage(issue.message, identifier: AccessibilityID.Onboarding.apiKeyError)
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Your API key is never shown again and will be stored in the device Keychain after validation.")
        }
    }

    private var connectionSection: some View {
        Section {
            Button(action: beginValidation) {
                HStack(spacing: 10) {
                    if form.connectionState == .validating {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(form.connectionState == .validating ? "Connecting…" : "Connect")
                        .frame(maxWidth: .infinity)
                }
            }
            .disabled(!form.canValidateConnection)
            .accessibilityIdentifier(AccessibilityID.Onboarding.connect)

            connectionStatus
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch form.connectionState {
        case .idle:
            EmptyView()
        case .validating:
            Label("Validating server and API key", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Onboarding.connectionStatus)
        case let .connected(summary):
            VStack(alignment: .leading, spacing: 4) {
                Label("Connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text("\(summary.accountDisplayName) · Immich \(summary.serverVersion)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Onboarding.connectionStatus)
        case let .failed(failure):
            let presentation = failure.presentation
            VStack(alignment: .leading, spacing: 4) {
                Label(presentation.title, systemImage: presentation.systemImage)
                    .foregroundStyle(.red)
                Text(presentation.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Onboarding.connectionStatus)
        }
    }

    private var serverURLBinding: Binding<String> {
        Binding(
            get: { form.serverURLText },
            set: { form.setServerURLText($0) }
        )
    }

    private var apiKeyBinding: Binding<String> {
        Binding(
            get: { form.apiKeyText },
            set: { form.setAPIKeyText($0) }
        )
    }

    private var shouldShowServerURLIssue: Bool {
        !form.serverURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var shouldShowAPIKeyIssue: Bool {
        !form.apiKeyText.isEmpty && form.apiKeyIssue != nil
    }

    private func validationMessage(_ message: String, identifier: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.footnote)
            .foregroundStyle(.red)
            .accessibilityIdentifier(identifier)
    }

    private func beginValidation() {
        focusedField = nil
        form.beginValidation()
    }

    private func validateCurrentRequestIfNeeded() async {
        guard form.connectionState == .validating, let request = form.connectRequest else { return }
        let revision = form.validationRevision
        let result = await validateConnection(request)
        guard !Task.isCancelled else { return }
        guard form.completeValidation(result, revision: revision) else { return }

        if case let .connected(summary) = result {
            onConnected(request, summary)
        }
    }

    private enum Field: Hashable {
        case serverURL
        case apiKey
    }
}

#Preview("Signed Out") {
    OnboardingView(
        initialState: OnboardingFormState(serverURLText: "demo.immich.app"),
        validateConnection: { _ in
            try? await Task.sleep(for: .milliseconds(400))
            return .connected(
                ConnectedServerSummary(serverVersion: "2.4.1", accountDisplayName: "Preview Account")
            )
        },
        onConnected: { _, _ in }
    )
}

#Preview("Connection Error") {
    OnboardingView(
        initialState: OnboardingFormState(
            serverURLText: "https://photos.example.com",
            connectionState: .failed(.serverUnavailable)
        ),
        validateConnection: { _ in .failed(.serverUnavailable) },
        onConnected: { _, _ in }
    )
}
