import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ExportOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var variant: ExportVariant
    @State private var actionState: ActionState = .idle
    @State private var pendingDestination: ExportDestination?
    @State private var revision: UInt64 = 0
    @State private var filesExport: PreparedExport?

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
                Section("Version") {
                    Picker("Version", selection: $variant) {
                        ForEach(ExportVariant.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.inline)
                    .accessibilityIdentifier(AccessibilityID.Export.variant)

                    if !currentAvailable {
                        Label(
                            "Current Version export is unavailable on this connection. Original will never be substituted automatically.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Destination") {
                    Button {
                        begin(.photos)
                    } label: {
                        Label("Save to Photos", systemImage: "photo.badge.arrow.down")
                    }
                    .disabled(actionState.isWorking || (variant == .current && !currentAvailable))
                    .accessibilityIdentifier(AccessibilityID.Export.photos)

                    Button {
                        begin(.files)
                    } label: {
                        Label("Save to Files", systemImage: "folder.badge.plus")
                    }
                    .disabled(actionState.isWorking || (variant == .current && !currentAvailable))
                    .accessibilityIdentifier(AccessibilityID.Export.files)
                }

                statusSection
            }
            .formStyle(.grouped)
            .navigationTitle("Download")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier(AccessibilityID.Export.screen)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task(id: revision) { await performIfNeeded() }
            .sheet(item: $filesExport) { export in
                FilesExportPicker(url: export.fileURL) {
                    filesExport = nil
                    Task { await exporter.cleanup(export) }
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch actionState {
        case .idle:
            EmptyView()
        case .working:
            Section { ProgressView("Preparing export…") }
        case let .succeeded(message):
            Section { Label(message, systemImage: "checkmark.circle") }
        case let .failed(failure):
            Section {
                Label(failure.title, systemImage: failure.systemImage)
                    .foregroundStyle(.red)
                Text(failure.message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func begin(_ destination: ExportDestination) {
        pendingDestination = destination
        actionState = .working
        revision &+= 1
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
                actionState = .succeeded("Saved to Photos.")
            case .files:
                filesExport = export
                prepared = nil
                actionState = .succeeded("Choose a location in Files.")
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
}

private enum ExportDestination: Sendable {
    case photos
    case files
}

private struct FilesExportPicker: UIViewControllerRepresentable {
    let url: URL
    let didFinish: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(didFinish: didFinish) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        controller.delegate = context.coordinator
        controller.shouldShowFileExtensions = true
        return controller
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let didFinish: @MainActor () -> Void

        init(didFinish: @escaping @MainActor () -> Void) {
            self.didFinish = didFinish
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            Task { @MainActor in didFinish() }
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            Task { @MainActor in didFinish() }
        }
    }
}
