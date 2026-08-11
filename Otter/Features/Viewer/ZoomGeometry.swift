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
    static let gestureHysteresis: CGFloat = 10

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

    static func resolvedAxis(
        translation: CGPoint,
        hysteresis: CGFloat = gestureHysteresis
    ) -> ViewerGestureAxis? {
        let distance = hypot(translation.x, translation.y)
        guard distance >= hysteresis else { return nil }
        return abs(translation.x) >= abs(translation.y) ? .horizontal : .vertical
    }

    static func horizontalPageHandoff(
        fingerTranslation: CGFloat,
        startingOffset: CGFloat,
        minimumOffset: CGFloat,
        maximumOffset: CGFloat
    ) -> CGFloat {
        if fingerTranslation > 0 {
            let availablePan = max(startingOffset - minimumOffset, 0)
            return max(fingerTranslation - availablePan, 0)
        }
        if fingerTranslation < 0 {
            let availablePan = max(maximumOffset - startingOffset, 0)
            return min(fingerTranslation + availablePan, 0)
        }
        return 0
    }

    static func rubberBanded(
        _ overshoot: CGFloat,
        dimension: CGFloat,
        constant: CGFloat = 0.55
    ) -> CGFloat {
        guard dimension > 0, overshoot != 0 else { return 0 }
        return (overshoot * dimension * constant)
            / (dimension + constant * abs(overshoot))
    }

    static func projectedDistance(
        velocity: CGFloat,
        decelerationRate: CGFloat = 0.998
    ) -> CGFloat {
        guard decelerationRate > 0, decelerationRate < 1 else { return 0 }
        return (velocity / 1_000) * decelerationRate / (1 - decelerationRate)
    }

    static func resolvePage(
        translation: CGFloat,
        velocity: CGFloat,
        pageWidth: CGFloat,
        canGoPrevious: Bool,
        canGoNext: Bool
    ) -> ViewerPageResolution {
        guard pageWidth > 0 else {
            return ViewerPageResolution(direction: nil, projectedTranslation: translation)
        }
        let projected = translation + projectedDistance(velocity: velocity)
        let threshold = min(pageWidth * 0.25, 120)
        let direction: ViewerPageDirection?
        if projected >= threshold, canGoPrevious {
            direction = .previous
        } else if projected <= -threshold, canGoNext {
            direction = .next
        } else {
            direction = nil
        }
        return ViewerPageResolution(direction: direction, projectedTranslation: projected)
    }

    static func pageTranslation(
        _ translation: CGFloat,
        pageWidth: CGFloat,
        canGoPrevious: Bool,
        canGoNext: Bool
    ) -> CGFloat {
        if translation > 0, !canGoPrevious {
            return rubberBanded(translation, dimension: pageWidth)
        }
        if translation < 0, !canGoNext {
            return rubberBanded(translation, dimension: pageWidth)
        }
        return translation
    }

    static func dismissalProgress(
        translation: CGFloat,
        viewportHeight: CGFloat
    ) -> CGFloat {
        guard viewportHeight > 0 else { return 0 }
        return min(max(translation / (viewportHeight * 0.45), 0), 1)
    }

    static func shouldCompleteDismissal(
        translation: CGFloat,
        velocity: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        guard viewportHeight > 0 else { return false }
        let projected = translation + projectedDistance(velocity: velocity, decelerationRate: 0.99)
        return translation >= viewportHeight * 0.18
            || projected >= viewportHeight * 0.32
            || velocity >= 900
    }
}
