import CoreGraphics
import Foundation

struct NormalizedPhotoAnchor: Equatable, Sendable {
    let x: CGFloat
    let y: CGFloat

    init(x: CGFloat, y: CGFloat) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    static let center = NormalizedPhotoAnchor(x: 0.5, y: 0.5)
}

struct ZoomViewportSnapshot: Equatable, Sendable {
    let zoomScale: CGFloat
    let anchor: NormalizedPhotoAnchor
}

enum ZoomGeometry {
    static func aspectFitSize(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return .zero
        }
        let scale = min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    static func clampedZoomScale(_ scale: CGFloat, minimum: CGFloat = 1, maximum: CGFloat = 4) -> CGFloat {
        min(max(scale, minimum), maximum)
    }

    static func zoomRect(
        scale: CGFloat,
        center: CGPoint,
        viewportSize: CGSize,
        maximumScale: CGFloat = 4
    ) -> CGRect {
        let scale = clampedZoomScale(scale, maximum: maximumScale)
        let size = CGSize(
            width: viewportSize.width / scale,
            height: viewportSize.height / scale
        )
        return CGRect(
            x: center.x - size.width / 2,
            y: center.y - size.height / 2,
            width: size.width,
            height: size.height
        )
    }
}
