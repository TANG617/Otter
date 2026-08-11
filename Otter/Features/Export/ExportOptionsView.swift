import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ExportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var isCloseFocused: Bool
    @State private var variant: ExportVariant
    @State private var actionState: ActionState = .idle
    @State private var pendingDestination: ExportDestination?
    @State private var lastDestination: ExportDestination?
    @State private var revision: UInt64 = 0
    @State private var filesExport: PreparedExport?
    @State private var successFeedbackTrigger = 0

    private let asset: MediaAssetDescriptor
    private let currentAvailable: Bool
    private let exporter: any AssetExporting
    private let photosExporter: any PhotosExporting

    init(
        asset: MediaAssetDescriptor,
        initialVariant: ExportVariant = .current,
        currentAvailable: Bool,
        exporter: any AssetExporting,
        photosExporter: any PhotosExporting = PhotosExporter()
    ) {
        self.asset = asset
        _variant = State(initialValue: initialVariant)
        self.currentAvailable = currentAvailable
        self.exporter = exporter
        self.photosExporter = photosExporter
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Photo Version") {
                    Picker("Photo Version", selection: $variant) {
                        ForEach(ExportVariant.allCases) { option in
                            Text(option.title)
                                .tag(option)
                                .accessibilityIdentifier(AccessibilityID.Export.variant(option))
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .disabled(actionState.isWorking)
                    .accessibilityLabel("Photo Version")

                    if !currentAvailable {
                        Label(
                            "Current Version export is unavailable on this connection. Original will never be substituted automatically.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Save") {
                    destinationButton(.photos)
                    destinationButton(.files)
                    actionStatus
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.Export.screen)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(actionState.isSuccess ? "Done" : "Cancel") { dismiss() }
                        .accessibilityFocused($isCloseFocused)
                        .accessibilityIdentifier("export.close")
                }
            }
            .task(id: revision) { await performIfNeeded() }
            .onAppear { isCloseFocused = true }
            .sheet(item: $filesExport) { export in
                FilesExportPicker(url: export.fileURL) { didExport in
                    filesExport = nil
                    Task { await exporter.cleanup(export) }
                    if didExport {
                        finish(with: "Saved to Files.")
                    } else {
                        actionState = .idle
                    }
                }
            }
            .sensoryFeedback(.success, trigger: successFeedbackTrigger)
        }
        .presentationSizing(.fitted)
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var actionStatus: some View {
        switch actionState {
        case .idle, .working:
            EmptyView()
        case let .succeeded(message):
            Label(message, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityElement(children: .combine)
        case let .failed(failure):
            VStack(alignment: .leading, spacing: 8) {
                Label(failure.title, systemImage: failure.systemImage)
                    .foregroundStyle(.red)
                Text(failure.message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let lastDestination {
                    Button("Try Again") { begin(lastDestination) }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("export.retry")
                }
            }
            .accessibilityElement(children: .contain)
        }
    }

    @ViewBuilder
    private func destinationButton(_ destination: ExportDestination) -> some View {
        if destination == .photos {
            destinationAction(destination)
                .buttonStyle(.borderedProminent)
        } else {
            destinationAction(destination)
                .buttonStyle(.bordered)
        }
    }

    private func destinationAction(_ destination: ExportDestination) -> some View {
        Button {
            begin(destination)
        } label: {
            HStack(spacing: 10) {
                if isWorking(destination) {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: destination.systemImage)
                }

                Text(isWorking(destination) ? destination.workingTitle : destination.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .disabled(actionState.isWorking || (variant == .current && !currentAvailable))
        .accessibilityLabel(destination.title)
        .accessibilityValue(isWorking(destination) ? "In progress" : "")
        .accessibilityIdentifier(destination.accessibilityIdentifier)
    }

    private func begin(_ destination: ExportDestination) {
        pendingDestination = destination
        lastDestination = destination
        actionState = .working
        revision &+= 1
    }

    private func isWorking(_ destination: ExportDestination) -> Bool {
        actionState.isWorking && (pendingDestination == destination || lastDestination == destination)
    }

    private func performIfNeeded() async {
        guard actionState == .working, let destination = pendingDestination else { return }
        let currentRevision = revision
        var prepared: PreparedExport?
        do {
            let export = try await exporter.prepare(asset: asset, variant: variant)
            prepared = export
            guard !Task.isCancelled, currentRevision == revision else {
                await exporter.cleanup(export)
                return
            }
            switch destination {
            case .photos:
                try await photosExporter.save(export)
                await exporter.cleanup(export)
                prepared = nil
                finish(with: "Saved to Photos.")
            case .files:
                filesExport = export
                prepared = nil
            }
        } catch is CancellationError {
            if let prepared { await exporter.cleanup(prepared) }
        } catch {
            if let prepared { await exporter.cleanup(prepared) }
            let message = (error as? LocalizedError)?.errorDescription ?? "The export could not be completed."
            actionState = .failed(
                PresentationFailure(title: "Export Failed", message: message, systemImage: "arrow.down.circle")
            )
        }
        pendingDestination = nil
    }

    private func finish(with message: String) {
        actionState = .succeeded(message)
        successFeedbackTrigger &+= 1
    }
}

enum ExportDestination: CaseIterable, Equatable, Sendable {
    case photos
    case files

    var title: String {
        switch self {
        case .photos: "Save to Photos"
        case .files: "Save to Files"
        }
    }

    var workingTitle: String {
        switch self {
        case .photos: "Saving to Photos…"
        case .files: "Preparing for Files…"
        }
    }

    var systemImage: String {
        switch self {
        case .photos: "photo.badge.arrow.down"
        case .files: "folder.badge.plus"
        }
    }

    var accessibilityIdentifier: String {
        switch self {
        case .photos: AccessibilityID.Export.photos
        case .files: AccessibilityID.Export.files
        }
    }
}

private struct FilesExportPicker: UIViewControllerRepresentable {
    let url: URL
    let didFinish: @MainActor (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(didFinish: didFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let didFinish: @MainActor (Bool) -> Void

        init(didFinish: @escaping @MainActor (Bool) -> Void) {
            self.didFinish = didFinish
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor in didFinish(false) }
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            Task { @MainActor in didFinish(true) }
        }
    }
}

private extension ActionState {
    var isSuccess: Bool {
        guard case .succeeded = self else { return false }
        return true
    }
}
