import Foundation
import Photos

protocol PhotosExporting: Sendable {
    func save(_ export: PreparedExport) async throws
}

struct PhotosExporter: PhotosExporting {
    func save(_ export: PreparedExport) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw AssetExportError.photosAddPermissionDenied
        }
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
}
