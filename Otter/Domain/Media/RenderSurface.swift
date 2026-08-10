import CoreGraphics
import Foundation

/// `CGImage` is immutable after creation. This wrapper never exposes mutable backing state.
final class RenderSurface: @unchecked Sendable {
    let cgImage: CGImage
    let pixelWidth: Int
    let pixelHeight: Int
    let estimatedByteCost: Int

    init(cgImage: CGImage) {
        self.cgImage = cgImage
        pixelWidth = cgImage.width
        pixelHeight = cgImage.height
        estimatedByteCost = cgImage.bytesPerRow * cgImage.height
    }
}
