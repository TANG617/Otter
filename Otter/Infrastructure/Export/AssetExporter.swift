import Foundation
import UniformTypeIdentifiers

enum ExportVariant: String, CaseIterable, Hashable, Identifiable, Sendable {
    case current
    case original

    var id: String { rawValue }

    var title: String {
        switch self {
        case .current: "Current Version"
        case .original: "Original"
        }
    }
}

struct AssetExportAvailability: Equatable, Sendable {
    let current: CapabilityAvailability
    let original: CapabilityAvailability

    static let available = AssetExportAvailability(current: .available, original: .available)

    init(current: CapabilityAvailability, original: CapabilityAvailability) {
        self.current = current
        self.original = original
    }

    init(serverCapabilities: ServerCapabilities) {
        self.init(
            current: serverCapabilities.currentDownload,
            original: serverCapabilities.originalDownload
        )
    }

    func supports(_ variant: ExportVariant) -> Bool {
        let availability = variant == .current ? current : original
        if case .unavailable = availability { return false }
        return true
    }
}

struct PreparedExport: Hashable, Identifiable, Sendable {
    let id: UUID
    let fileURL: URL
    let filename: String
    let mimeType: String?
    let variant: ExportVariant
}

enum AssetExportError: Error, Equatable, LocalizedError {
    case currentUnavailable
    case originalUnavailable
    case permissionDenied
    case emptyFile
    case unsafeOutputPath
    case photosAddPermissionDenied
    case photosAddPermissionRestricted
    case photosSaveFailed
    case transport

    var errorDescription: String? {
        switch self {
        case .currentUnavailable:
            "This server cannot export the Current Version. Original was not substituted."
        case .originalUnavailable:
            "This server cannot export the Original. Current Version was not substituted."
        case .permissionDenied:
            "This API key does not have permission to download the selected version."
        case .emptyFile:
            "The server returned an empty file."
        case .unsafeOutputPath:
            "Otter could not create a safe export file."
        case .photosAddPermissionDenied:
            "Allow Otter to add photos in Settings, then try again."
        case .photosAddPermissionRestricted:
            "This device restricts access to adding photos. Check Screen Time or device management settings."
        case .photosSaveFailed:
            "Photos could not save this file format."
        case .transport:
            "The selected version could not be downloaded."
        }
    }
}

protocol AssetExporting: Sendable {
    func prepare(
        asset: MediaAssetDescriptor,
        variant: ExportVariant
    ) async throws -> PreparedExport
    func cleanup(_ export: PreparedExport) async
}

actor AssetExporter: AssetExporting {
    private let requestBuilder: any MediaRequestBuilding
    private let transport: any MediaTransporting
    private let exportDirectory: URL
    private let availability: AssetExportAvailability
    private let fileManager: FileManager

    init(
        requestBuilder: any MediaRequestBuilding,
        transport: any MediaTransporting,
        exportDirectory: URL,
        availability: AssetExportAvailability,
        fileManager: FileManager = .default
    ) throws {
        self.requestBuilder = requestBuilder
        self.transport = transport
        self.exportDirectory = exportDirectory.standardizedFileURL
        self.availability = availability
        self.fileManager = fileManager
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    }

    func prepare(
        asset: MediaAssetDescriptor,
        variant: ExportVariant
    ) async throws -> PreparedExport {
        guard availability.supports(variant) else {
            throw variant == .current
                ? AssetExportError.currentUnavailable
                : AssetExportError.originalUnavailable
        }
        try Task.checkCancellation()
        let assetVariant: AssetVariant = variant == .current ? .current : .original
        let request = try requestBuilder.urlRequest(
            for: asset,
            variant: assetVariant,
            representation: .original
        )

        let downloaded: TransportedMediaFile
        do {
            downloaded = try await transport.download(request)
        } catch let error as MediaTransportHTTPError {
            switch error.statusCode {
            case 403: throw AssetExportError.permissionDenied
            case 404 where variant == .current: throw AssetExportError.currentUnavailable
            default: throw AssetExportError.transport
            }
        } catch let error as MediaError {
            switch error {
            case .httpStatus(403, _): throw AssetExportError.permissionDenied
            case .httpStatus(404, _) where variant == .current:
                throw AssetExportError.currentUnavailable
            default: throw AssetExportError.transport
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AssetExportError.transport
        }

        defer { try? fileManager.removeItem(at: downloaded.fileURL) }
        guard downloaded.byteCount != 0 else { throw AssetExportError.emptyFile }

        let id = UUID()
        let directory = exportDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let filename = Self.filename(
                originalName: asset.originalFilename,
                mimeType: downloaded.mimeType ?? asset.originalMimeType,
                variant: variant
            )
            let destination = directory.appendingPathComponent(filename, isDirectory: false)
            try fileManager.moveItem(at: downloaded.fileURL, to: destination)
            let byteCount = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard byteCount > 0 else {
                try? fileManager.removeItem(at: directory)
                throw AssetExportError.emptyFile
            }
            return PreparedExport(
                id: id,
                fileURL: destination,
                filename: filename,
                mimeType: downloaded.mimeType ?? asset.originalMimeType,
                variant: variant
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    func cleanup(_ export: PreparedExport) {
        let parent = export.fileURL.deletingLastPathComponent().standardizedFileURL
        guard parent.deletingLastPathComponent() == exportDirectory else { return }
        try? fileManager.removeItem(at: parent)
    }

    private static func filename(
        originalName: String?,
        mimeType: String?,
        variant: ExportVariant
    ) -> String {
        let supplied = (originalName ?? "photo").trimmingCharacters(in: .whitespacesAndNewlines)
        let leaf = URL(fileURLWithPath: supplied).lastPathComponent
        let sanitized = leaf.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_. ")).contains(scalar)
                ? Character(String(scalar))
                : "_"
        }
        var name = String(sanitized).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        if name.isEmpty { name = "photo" }

        let url = URL(fileURLWithPath: name)
        var base = url.deletingPathExtension().lastPathComponent
        var fileExtension = url.pathExtension
        if variant == .current {
            base += "-current"
            if let mimeType, let suggested = UTType(mimeType: mimeType)?.preferredFilenameExtension {
                fileExtension = suggested
            }
        } else if fileExtension.isEmpty, let mimeType,
                  let suggested = UTType(mimeType: mimeType)?.preferredFilenameExtension {
            fileExtension = suggested
        }
        return fileExtension.isEmpty ? base : "\(base).\(fileExtension.lowercased())"
    }
}
