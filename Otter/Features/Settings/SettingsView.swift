import SwiftUI

@MainActor
struct SettingsView: View {
    typealias UpdateCacheLimit = @MainActor (SettingsCacheLimit) -> Void
    typealias PerformAction = @MainActor @Sendable () async -> ActionOutcome
    typealias OpenDiagnostics = @MainActor () -> Void

    @State private var cacheLimit: SettingsCacheLimit
    @State private var actionState: ActionState = .idle
    @State private var pendingAction: SettingsPendingAction?
    @State private var actionRevision: UInt64 = 0
    @State private var confirmation: SettingsConfirmation?

    private let snapshot: SettingsSnapshot
    private let updateCacheLimit: UpdateCacheLimit
    private let clearCache: PerformAction
    private let openDiagnostics: OpenDiagnostics
    private let signOut: PerformAction

    init(
        snapshot: SettingsSnapshot,
        updateCacheLimit: @escaping UpdateCacheLimit,
        clearCache: @escaping PerformAction,
        openDiagnostics: @escaping OpenDiagnostics,
        signOut: @escaping PerformAction
    ) {
        self.snapshot = snapshot
        _cacheLimit = State(initialValue: snapshot.cacheLimit)
        self.updateCacheLimit = updateCacheLimit
        self.clearCache = clearCache
        self.openDiagnostics = openDiagnostics
        self.signOut = signOut
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                cacheSection
                supportSection
                aboutSection
                signOutSection
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.Settings.screen)
            .alert(item: $confirmation, content: confirmationAlert)
            .task(id: actionRevision) {
                await performPendingActionIfNeeded()
            }
        }
    }

    private var accountSection: some View {
        Section("Account") {
            LabeledContent("Account", value: snapshot.accountDisplayName)
            LabeledContent("Server", value: snapshot.serverDisplayName)
            LabeledContent("Server Version", value: snapshot.serverVersion)

            if snapshot.usesFixtures {
                Label("Fixture Mode", systemImage: "wrench.and.screwdriver")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var cacheSection: some View {
        Section {
            LabeledContent("Used", value: formattedBytes(snapshot.cacheUsageBytes))

            Picker("Limit", selection: $cacheLimit) {
                ForEach(SettingsCacheLimit.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .accessibilityIdentifier(AccessibilityID.Settings.cacheLimit)
            .onChange(of: cacheLimit) { _, newLimit in
                updateCacheLimit(newLimit)
                actionState = .succeeded("Media cache limit updated.")
            }

            Button("Clear Media Cache", role: .destructive) {
                confirmation = .clearCache
            }
            .disabled(actionState.isWorking)
            .accessibilityIdentifier(AccessibilityID.Settings.clearCache)

            actionStatus
        } header: {
            Text("Media Cache")
        } footer: {
            Text("The media cache improves browsing performance. It does not provide offline storage.")
        }
    }

    private var supportSection: some View {
        Section("Support") {
            Button(action: openDiagnostics) {
                HStack {
                    Label("Diagnostics", systemImage: "stethoscope")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.Settings.diagnostics)

            LabeledContent("Otter Version", value: snapshot.appVersion)
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                confirmation = .signOut
            }
            .disabled(actionState.isWorking)
            .accessibilityIdentifier(AccessibilityID.Settings.signOut)
        } footer: {
            Text("Signing out removes the saved API key and active-account session from this device.")
        }
    }

    private var aboutSection: some View {
        Section("About Otter") {
            LabeledContent("Tagline", value: "Native Photos for Immich")
            LabeledContent("Platform", value: "iOS and iPadOS 18+")
        }
    }

    @ViewBuilder
    private var actionStatus: some View {
        switch actionState {
        case .idle:
            EmptyView()
        case .working:
            HStack(spacing: 10) {
                ProgressView()
                Text("Working…")
            }
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Settings.actionStatus)
        case let .succeeded(message):
            Label(message, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Settings.actionStatus)
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 4) {
                Label(failure.title, systemImage: failure.systemImage)
                    .foregroundStyle(.red)
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Settings.actionStatus)
        }
    }

    private func confirmationAlert(_ confirmation: SettingsConfirmation) -> Alert {
        Alert(
            title: Text(confirmation.title),
            message: Text(confirmation.message),
            primaryButton: .destructive(Text(confirmation.confirmationTitle)) {
                begin(confirmation == .clearCache ? .clearCache : .signOut)
            },
            secondaryButton: .cancel()
        )
    }

    private func begin(_ action: SettingsPendingAction) {
        pendingAction = action
        actionState = .working
        actionRevision &+= 1
    }

    private func performPendingActionIfNeeded() async {
        guard actionState == .working, let pendingAction else { return }
        let revision = actionRevision
        let outcome: ActionOutcome

        switch pendingAction {
        case .clearCache:
            outcome = await clearCache()
        case .signOut:
            outcome = await signOut()
        }

        guard !Task.isCancelled, actionRevision == revision else { return }
        self.pendingAction = nil

        switch outcome {
        case let .success(message):
            actionState = .succeeded(message)
        case let .failure(failure):
            actionState = .failed(failure)
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

#Preview("Fixture Settings") {
    SettingsView(
        snapshot: .fixture,
        updateCacheLimit: { _ in },
        clearCache: { .success(message: "Media cache cleared.") },
        openDiagnostics: {},
        signOut: { .success(message: "Signed out.") }
    )
}
