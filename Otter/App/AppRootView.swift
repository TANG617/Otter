import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSession.self) private var session

    @State private var viewer: ViewerPresentation?
    @State private var sheet: RootSheet?
    @State private var libraryRevision = 0

    var body: some View {
        rootContent
            .fullScreenCover(item: $viewer) { presentation in
                viewerHost(presentation)
            }
            .sheet(item: $sheet) { destination in
                sheetContent(destination)
            }
            .onChange(of: session.state) { _, state in
                if state == .signedOut || state == .authenticationInvalid {
                    viewer = nil
                    sheet = nil
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch session.state {
        case .signedOut, .authenticationInvalid:
            OnboardingView(
                validateConnection: { request in
                    await environment.validateConnection(request)
                },
                onConnected: { request, summary in
                    environment.completeConnection(request: request, summary: summary)
                }
            )

        case .connecting:
            LoadingStateView(
                "Opening Library",
                message: "Preparing secure local storage and media caches.",
                accessibilityIdentifier: "app.connecting"
            )

        case let .active(accountNamespace):
            if let runtime = environment.liveRuntime {
                library(
                    accountNamespace: accountNamespace,
                    assetStore: runtime.assetStore,
                    mediaPipeline: runtime.mediaPipeline
                )
            } else {
                LoadingStateView(
                    "Opening Library",
                    message: "Restoring your saved session.",
                    accessibilityIdentifier: "app.restoring"
                )
            }

        case .fixture:
            if let runtime = environment.fixtureRuntime {
                library(
                    accountNamespace: runtime.accountNamespace,
                    assetStore: runtime.assetStore,
                    mediaPipeline: runtime.mediaPipeline
                )
            } else {
                FailureStateView(
                    failure: PresentationFailure(
                        title: "Fixture Unavailable",
                        message: "The deterministic fixture library could not be created."
                    ),
                    accessibilityIdentifier: "fixture.failure"
                ) { }
            }
        }
    }

    private func library(
        accountNamespace: UUID,
        assetStore: any AssetStore,
        mediaPipeline: any MediaPipelineProtocol
    ) -> some View {
        NavigationStack {
            TimelineView(
                accountNamespace: accountNamespace,
                assetStore: assetStore,
                mediaPipeline: mediaPipeline,
                onSelectAsset: { asset, frame, window in
                    presentViewer(selected: asset, initialFrame: frame, window: window)
                },
                onOpenSettings: openSettings
            )
            .id(libraryRevision)
        }
    }

    @ViewBuilder
    private func viewerHost(_ presentation: ViewerPresentation) -> some View {
        if let runtime = environment.liveRuntime {
            ViewerHostView(
                presentation: presentation,
                pipeline: runtime.mediaPipeline,
                exporter: runtime.exporter,
                currentExportAvailable: runtime.account.serverVersion?.hasPrefix("3.") == true,
                onRate: { item, rating in
                    do {
                        let result = try await runtime.ratingRepository.setRating(
                            rating,
                            assetID: item.id,
                            accountNamespace: item.descriptor.accountNamespace
                        )
                        libraryRevision &+= 1
                        return .verified(result.asset.rating)
                    } catch {
                        return .failed
                    }
                },
                onSettings: {
                    viewer = nil
                    openSettings()
                },
                onDismiss: { viewer = nil }
            )
        } else if let runtime = environment.fixtureRuntime {
            ViewerHostView(
                presentation: presentation,
                pipeline: runtime.mediaPipeline,
                exporter: runtime.exporter,
                currentExportAvailable: true,
                onRate: { item, rating in
                    guard let verified = await runtime.assetStore.setRating(rating, assetID: item.id) else {
                        return .failed
                    }
                    libraryRevision &+= 1
                    return .verified(verified.rating)
                },
                onSettings: {
                    viewer = nil
                    openSettings()
                },
                onDismiss: { viewer = nil }
            )
        }
    }

    @ViewBuilder
    private func sheetContent(_ destination: RootSheet) -> some View {
        switch destination {
        case let .settings(snapshot):
            SettingsView(
                snapshot: snapshot,
                updateCacheLimit: environment.updateCacheLimit,
                clearCache: { await environment.clearMediaCache() },
                openDiagnostics: openDiagnostics,
                signOut: {
                    let outcome = await environment.signOut()
                    sheet = nil
                    return outcome
                }
            )
        case let .diagnostics(snapshot):
            DiagnosticsView(
                snapshot: snapshot,
                refresh: { .updated(await environment.diagnosticsSnapshot()) },
                copySummary: { summary in UIPasteboard.general.string = summary }
            )
        }
    }

    private func presentViewer(
        selected: TimelineAsset,
        initialFrame: MediaFrame?,
        window: [TimelineAsset]
    ) {
        let source = window.contains(where: { $0.id == selected.id }) ? window : [selected]
        let items = source.map { asset in
            ViewerItem(
                descriptor: TimelineMediaDemand.descriptor(for: asset),
                accessibilityLabel: TimelineAccessibilityLabel.asset(asset),
                rating: asset.rating
            )
        }
        viewer = ViewerPresentation(
            selectedAssetID: selected.id,
            items: items,
            initialFrame: initialFrame
        )
    }

    private func openSettings() {
        Task { sheet = .settings(await environment.settingsSnapshot()) }
    }

    private func openDiagnostics() {
        Task { sheet = .diagnostics(await environment.diagnosticsSnapshot()) }
    }
}

private struct ViewerPresentation: Identifiable {
    let selectedAssetID: UUID
    let items: [ViewerItem]
    let initialFrame: MediaFrame?

    var id: UUID { selectedAssetID }
}

private enum RootSheet: Identifiable {
    case settings(SettingsSnapshot)
    case diagnostics(DiagnosticsSnapshot)

    var id: String {
        switch self {
        case .settings: "settings"
        case .diagnostics: "diagnostics"
        }
    }
}

@MainActor
private struct ViewerHostView: View {
    typealias Rate = @MainActor @Sendable (ViewerItem, AssetRating?) async -> ViewerRatingMutationOutcome

    @State private var export: ViewerExportPresentation?

    let presentation: ViewerPresentation
    let pipeline: any MediaPipelineProtocol
    let exporter: any AssetExporting
    let currentExportAvailable: Bool
    let onRate: Rate
    let onSettings: @MainActor @Sendable () -> Void
    let onDismiss: @MainActor @Sendable () -> Void

    var body: some View {
        FullscreenViewer(
            items: presentation.items,
            initialAssetID: presentation.selectedAssetID,
            initialFrame: presentation.initialFrame,
            pipeline: pipeline,
            actions: ViewerActions(
                onDismiss: onDismiss,
                onRate: onRate,
                onExport: { item, variant in
                    export = ViewerExportPresentation(item: item, variant: variant)
                },
                onSettings: onSettings
            )
        )
        .sheet(item: $export) { request in
            ExportOptionsView(
                asset: request.item.descriptor,
                initialVariant: request.variant == .current ? .current : .original,
                currentAvailable: currentExportAvailable,
                exporter: exporter
            )
        }
    }
}

private struct ViewerExportPresentation: Identifiable {
    let item: ViewerItem
    let variant: AssetVariant

    var id: String { "\(item.id.uuidString)-\(variant.rawValue)" }
}
