import SwiftUI
import UIKit

@MainActor
struct AppRootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(AppSession.self) private var session
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewer: ViewerPresentation?
    @State private var viewerReturnAssetID: UUID?
    @State private var sheet: RootSheet?
    @State private var latestAssetUpdate: TimelineAsset?
    @Namespace private var viewerTransition

    var body: some View {
        rootContent
            .accessibilityHidden(sheet != nil)
            .allowsHitTesting(sheet == nil)
            .sheet(item: $sheet) { destination in
                sheetContent(destination)
                    .accessibilityAddTraits(.isModal)
            }
            .onChange(of: session.state) { _, state in
                if state == .signedOut || state == .authenticationInvalid {
                    viewer = nil
                    viewerReturnAssetID = nil
                    sheet = nil
                }
            }
    }

    @ViewBuilder
    private var rootContent: some View {
        switch session.state {
        case .signedOut, .authenticationInvalid:
            OnboardingView(
                initialState: environment.onboardingInitialState,
                validateConnection: { request in
                    await environment.validateConnection(request)
                },
                onConnected: { request, summary in
                    await environment.completeConnection(request: request, summary: summary)
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
                transitionNamespace: viewerTransition,
                updatedAsset: latestAssetUpdate,
                onSelectAsset: { asset, frame, window in
                    presentViewer(
                        selected: asset,
                        initialFrame: frame,
                        window: window
                    )
                },
                onOpenSettings: openSettings
            )
            .navigationDestination(item: $viewer) { presentation in
                presentedViewer(presentation)
            }
        }
    }

    @ViewBuilder
    private func presentedViewer(_ presentation: ViewerPresentation) -> some View {
        if reduceMotion {
            viewerHost(presentation)
                .accessibilityAddTraits(.isModal)
        } else {
            viewerHost(presentation)
                .navigationTransition(
                    .zoom(
                        sourceID: viewerReturnAssetID ?? presentation.selectedAssetID,
                        in: viewerTransition
                    )
                )
                .accessibilityAddTraits(.isModal)
        }
    }

    @ViewBuilder
    private func viewerHost(_ presentation: ViewerPresentation) -> some View {
        if let runtime = environment.liveRuntime {
            ViewerHostView(
                presentation: presentation,
                pipeline: runtime.mediaPipeline,
                exporter: runtime.exporter,
                photosExporter: PhotosExporter(),
                currentDownloadAvailable: true,
                onRate: { item, rating in
                    do {
                        let result = try await runtime.ratingRepository.setRating(
                            rating,
                            assetID: item.id,
                            accountNamespace: item.descriptor.accountNamespace
                        )
                        latestAssetUpdate = result.asset
                        return .verified(result.asset.rating)
                    } catch {
                        return .failed
                    }
                },
                onFavorite: { item, isFavorite in
                    do {
                        let result = try await runtime.ratingRepository.setFavorite(
                            isFavorite,
                            assetID: item.id,
                            accountNamespace: item.descriptor.accountNamespace
                        )
                        latestAssetUpdate = result.asset
                        return .verified(result.asset.isFavorite)
                    } catch {
                        return .failed
                    }
                },
                onCurrentItemChanged: { viewerReturnAssetID = $0 },
                onDismiss: dismissViewer
            )
        } else if let runtime = environment.fixtureRuntime {
            ViewerHostView(
                presentation: presentation,
                pipeline: runtime.mediaPipeline,
                exporter: runtime.exporter,
                photosExporter: FixturePhotosExporter(),
                currentDownloadAvailable: environment.fixtureCurrentExportAvailable,
                onRate: { item, rating in
                    if environment.fixtureRatingWritesFail { return .failed }
                    guard let verified = await runtime.assetStore.setRating(rating, assetID: item.id) else {
                        return .failed
                    }
                    latestAssetUpdate = verified
                    return .verified(verified.rating)
                },
                onFavorite: { item, isFavorite in
                    if environment.fixtureRatingWritesFail { return .failed }
                    guard let verified = await runtime.assetStore.setFavorite(isFavorite, assetID: item.id) else {
                        return .failed
                    }
                    latestAssetUpdate = verified
                    return .verified(verified.isFavorite)
                },
                onCurrentItemChanged: { viewerReturnAssetID = $0 },
                onDismiss: dismissViewer
            )
        }
    }

    @ViewBuilder
    private func sheetContent(_ destination: RootSheet) -> some View {
        switch destination {
        case let .settings(snapshot, diagnostics):
            SettingsView(
                snapshot: snapshot,
                diagnosticsSnapshot: diagnostics,
                updateCacheLimit: environment.updateCacheLimit,
                clearCache: { await environment.clearMediaCache() },
                refreshDiagnostics: { .updated(await environment.diagnosticsSnapshot()) },
                copyDiagnosticsSummary: { summary in UIPasteboard.general.string = summary },
                signOut: {
                    let outcome = await environment.signOut()
                    sheet = nil
                    return outcome
                }
            )
        }
    }

    private func presentViewer(
        selected: TimelineAsset,
        initialFrame: MediaFrame?,
        window: TimelineViewerWindow
    ) {
        let source = window.assets.contains(where: { $0.id == selected.id }) ? window.assets : [selected]
        let items = source.map(Self.viewerItem(for:))
        viewerReturnAssetID = selected.id
        viewer = ViewerPresentation(
            selectedAssetID: selected.id,
            items: items,
            initialFrame: initialFrame,
            loadMoreItems: {
                (await window.loadMore()).map(Self.viewerItem(for:))
            }
        )
    }

    private static func viewerItem(for asset: TimelineAsset) -> ViewerItem {
        ViewerItem(
            descriptor: TimelineMediaDemand.descriptor(for: asset),
            accessibilityLabel: TimelineAccessibilityLabel.asset(asset),
            rating: asset.rating,
            isFavorite: asset.isFavorite,
            captureDate: asset.timelineDate
        )
    }

    private func openSettings() {
        Task {
            async let settings = environment.settingsSnapshot()
            async let diagnostics = environment.diagnosticsSnapshot()
            sheet = .settings(await settings, await diagnostics)
        }
    }

    private func dismissViewer() {
        viewer = nil
    }

}

private struct ViewerPresentation: Identifiable, Hashable {
    let selectedAssetID: UUID
    let items: [ViewerItem]
    let initialFrame: MediaFrame?
    let loadMoreItems: @MainActor @Sendable () async -> [ViewerItem]

    var id: UUID { selectedAssetID }

    static func == (lhs: ViewerPresentation, rhs: ViewerPresentation) -> Bool {
        lhs.selectedAssetID == rhs.selectedAssetID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(selectedAssetID)
    }
}

private enum RootSheet: Identifiable {
    case settings(SettingsSnapshot, DiagnosticsSnapshot)

    var id: String {
        "settings"
    }
}

@MainActor
private struct ViewerHostView: View {
    typealias Rate = @MainActor @Sendable (ViewerItem, AssetRating?) async -> ViewerRatingMutationOutcome
    typealias Favorite = @MainActor @Sendable (ViewerItem, Bool) async -> ViewerFavoriteMutationOutcome

    let presentation: ViewerPresentation
    let pipeline: any MediaPipelineProtocol
    let exporter: any AssetExporting
    let photosExporter: any PhotosExporting
    let currentDownloadAvailable: Bool
    let onRate: Rate
    let onFavorite: Favorite
    let onCurrentItemChanged: @MainActor @Sendable (UUID) -> Void
    let onDismiss: @MainActor @Sendable () -> Void

    var body: some View {
        FullscreenViewer(
            items: presentation.items,
            initialAssetID: presentation.selectedAssetID,
            initialFrame: presentation.initialFrame,
            pipeline: pipeline,
            loadMore: presentation.loadMoreItems,
            actions: ViewerActions(
                onDismiss: onDismiss,
                onRate: onRate,
                onFavorite: onFavorite,
                onDownload: download,
                onCurrentItemChanged: onCurrentItemChanged
            )
        )
    }

    private func download(_ item: ViewerItem, _ variant: AssetVariant) async -> ActionOutcome {
        let exportVariant: ExportVariant = variant == .current ? .current : .original
        var prepared: PreparedExport?
        do {
            if exportVariant == .current, !currentDownloadAvailable {
                throw AssetExportError.currentUnavailable
            }
            let export = try await exporter.prepare(asset: item.descriptor, variant: exportVariant)
            prepared = export
            try await photosExporter.save(export)
            await exporter.cleanup(export)
            return .success(message: "Saved to Photos")
        } catch is CancellationError {
            if let prepared { await exporter.cleanup(prepared) }
            return .failure(
                PresentationFailure(
                    title: "Download Cancelled",
                    message: "The photo was not saved.",
                    systemImage: "xmark.circle"
                )
            )
        } catch {
            if let prepared { await exporter.cleanup(prepared) }
            let message = (error as? LocalizedError)?.errorDescription
                ?? "The selected photo version could not be saved."
            return .failure(
                PresentationFailure(
                    title: "Download Failed",
                    message: message,
                    systemImage: "arrow.clockwise.circle"
                )
            )
        }
    }
}

private struct FixturePhotosExporter: PhotosExporting {
    func save(_ export: PreparedExport) async throws { }
}
