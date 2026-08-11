import Foundation
import Photos

protocol PhotosExporting: Sendable {
    func save(_ export: PreparedExport) async throws
}

struct PhotosExporter: PhotosExporting {
    func save(_ export: PreparedExport) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        if let error = Self.permissionError(for: status) { throw error }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = export.filename
                request.addResource(with: .photo, fileURL: export.fileURL, options: options)
            }
        } catch {
            throw AssetExportError.photosSaveFailed
        }
    }

    static func permissionError(for status: PHAuthorizationStatus) -> AssetExportError? {
        switch status {
        case .authorized, .limited:
            nil
        case .restricted:
            .photosAddPermissionRestricted
        case .denied, .notDetermined:
            .photosAddPermissionDenied
        @unknown default:
            .photosAddPermissionDenied
        }
    }
}

struct DirectPhotosDownload: Sendable {
    let availability: AssetExportAvailability
    let exporter: any AssetExporting
    let photosExporter: any PhotosExporting

    func save(asset: MediaAssetDescriptor, variant: ExportVariant) async throws {
        guard availability.supports(variant) else {
            throw variant == .current
                ? AssetExportError.currentUnavailable
                : AssetExportError.originalUnavailable
        }

        var prepared: PreparedExport?
        do {
            let export = try await exporter.prepare(asset: asset, variant: variant)
            prepared = export
            try Task.checkCancellation()
            try await photosExporter.save(export)
            try Task.checkCancellation()
            await exporter.cleanup(export)
            prepared = nil
        } catch {
            if let prepared { await exporter.cleanup(prepared) }
            throw error
        }
    }
}
