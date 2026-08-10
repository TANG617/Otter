import CoreGraphics
import Foundation
import ImageIO

struct ImageProperties: Equatable, Sendable {
    let pixelWidth: Int
    let pixelHeight: Int
    let mimeType: String?
}
protocol MediaDecoding: Sendable {
    func inspect(fileURL: URL, mimeType: String?) async throws -> ImageProperties
    func decode(fileURL: URL, maxPixelSize: Int) async throws -> RenderSurface
}

final class ImageIODecoder: MediaDecoding, @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String = "com.tang617.otter.image-decode") {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func inspect(fileURL: URL, mimeType: String? = nil) async throws -> ImageProperties {
        try await onDecodeQueue {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
                throw MediaError.corruptMedia
            }
            let detectedType = CGImageSourceGetType(source) as String?
            return .init(
                pixelWidth: width.intValue,
                pixelHeight: height.intValue,
                mimeType: mimeType ?? detectedType
            )
        }
    }

    func decode(fileURL: URL, maxPixelSize: Int) async throws -> RenderSurface {
        let target = max(1, maxPixelSize)
        return try await onDecodeQueue {
            #if DEBUG
            dispatchPrecondition(condition: .notOnQueue(.main))
            #endif
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, [
                kCGImageSourceShouldCache: false,
            ] as CFDictionary) else {
                throw MediaError.corruptMedia
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceShouldCache: false,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  max(image.width, image.height) <= target else {
                throw MediaError.corruptMedia
            }
            return RenderSurface(cgImage: image)
        }
    }

    private func onDecodeQueue<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try operation()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
