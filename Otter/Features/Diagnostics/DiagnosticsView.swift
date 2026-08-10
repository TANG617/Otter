import SwiftUI

@MainActor
struct DiagnosticsView: View {
    typealias Refresh = @Sendable () async -> DiagnosticsRefreshOutcome
    typealias CopySummary = @MainActor (String) -> Void

    @State private var snapshot: DiagnosticsSnapshot
    @State private var actionState: ActionState = .idle
    @State private var refreshRevision: UInt64 = 0

    private let refresh: Refresh
    private let copySummary: CopySummary

    init(
        snapshot: DiagnosticsSnapshot,
        refresh: @escaping Refresh,
        copySummary: @escaping CopySummary
    ) {
        _snapshot = State(initialValue: snapshot)
        self.refresh = refresh
        self.copySummary = copySummary
    }

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                librarySection
                mediaSection
                applicationSection
                actionsSection
            }
            .formStyle(.grouped)
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.Diagnostics.screen)
            .task(id: refreshRevision) {
                await refreshIfNeeded()
            }
        }
    }

    private var connectionSection: some View {
        Section("Connection") {
            LabeledContent("Status") {
                Label(snapshot.connectionStatus.title, systemImage: snapshot.connectionStatus.systemImage)
                    .foregroundStyle(connectionStatusColor)
            }
            .accessibilityIdentifier(AccessibilityID.Diagnostics.connectionStatus)

            LabeledContent("Server Version", value: snapshot.serverVersion ?? "Unavailable")
            LabeledContent(
                "Last Metadata Refresh",
                value: snapshot.lastMetadataRefresh?.formatted(date: .abbreviated, time: .shortened) ?? "Never"
            )
        }
    }

    private var librarySection: some View {
        Section("Library") {
            LabeledContent("Assets", value: snapshot.assetCount.formatted())
                .accessibilityIdentifier(AccessibilityID.Diagnostics.assetCount)
            LabeledContent("Fixture Mode", value: snapshot.usesFixtures ? "Enabled" : "Disabled")
        }
    }

    private var mediaSection: some View {
        Section("Media") {
            LabeledContent("Disk Cache", value: formattedBytes(snapshot.mediaCacheBytes))
            LabeledContent("In-flight Requests", value: snapshot.inFlightMediaRequests.formatted())
        }
    }

    private var applicationSection: some View {
        Section("Application") {
            LabeledContent("Version", value: snapshot.appVersion)
            LabeledContent("Build", value: snapshot.buildNumber)
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                actionState = .working
                refreshRevision &+= 1
            } label: {
                Label(actionState.isWorking ? "Refreshing…" : "Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(actionState.isWorking)
            .accessibilityIdentifier(AccessibilityID.Diagnostics.refresh)

            Button {
                copySummary(snapshot.safeTextSummary)
                actionState = .succeeded("Diagnostics copied without credentials or server addresses.")
            } label: {
                Label("Copy Safe Summary", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier(AccessibilityID.Diagnostics.copySummary)

            actionStatus
        }
    }

    @ViewBuilder
    private var actionStatus: some View {
        switch actionState {
        case .idle, .working:
            EmptyView()
        case let .succeeded(message):
            Label(message, systemImage: "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.Diagnostics.actionStatus)
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 4) {
                Label(failure.title, systemImage: failure.systemImage)
                    .foregroundStyle(.red)
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier(AccessibilityID.Diagnostics.actionStatus)
        }
    }

    private var connectionStatusColor: Color {
        switch snapshot.connectionStatus {
        case .connected:
            .green
        case .degraded:
            .orange
        case .offline, .signedOut:
            .secondary
        }
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshIfNeeded() async {
        guard actionState == .working else { return }
        let revision = refreshRevision
        let outcome = await refresh()
        guard !Task.isCancelled, refreshRevision == revision else { return }

        switch outcome {
        case let .updated(updatedSnapshot):
            snapshot = updatedSnapshot
            actionState = .succeeded("Diagnostics refreshed.")
        case let .failure(failure):
            actionState = .failed(failure)
        }
    }
}

#Preview("Fixture Diagnostics") {
    DiagnosticsView(
        snapshot: .fixture,
        refresh: { .updated(.fixture) },
        copySummary: { _ in }
    )
}
