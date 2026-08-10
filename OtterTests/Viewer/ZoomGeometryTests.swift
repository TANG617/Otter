import CoreGraphics
import Testing
import UIKit
@testable import Otter

@Suite("Viewer zoom geometry")
struct ZoomGeometryTests {
    @Test("Aspect fit preserves dimensions")
    func aspectFit() {
        #expect(
            ZoomGeometry.aspectFitSize(
                imageSize: CGSize(width: 4_000, height: 3_000),
                viewportSize: CGSize(width: 1_000, height: 1_000)
            ) == CGSize(width: 1_000, height: 750)
        )
        #expect(ZoomGeometry.aspectFitSize(imageSize: .zero, viewportSize: .zero) == .zero)
    }

    @Test("Zoom is bounded and centered on the tap")
    func boundedZoomRect() {
        #expect(ZoomGeometry.clampedZoomScale(0.5) == 1)
        #expect(ZoomGeometry.clampedZoomScale(9) == 4)
        #expect(
            ZoomGeometry.zoomRect(
                scale: 2,
                center: CGPoint(x: 300, y: 400),
                viewportSize: CGSize(width: 200, height: 400)
            ) == CGRect(x: 250, y: 300, width: 100, height: 200)
        )
    }

    @Test("Normalized anchor clamps invalid edges")
    func normalizedAnchor() {
        #expect(NormalizedPhotoAnchor(x: -1, y: 2) == .init(x: 0, y: 1))
        #expect(NormalizedPhotoAnchor.center == .init(x: 0.5, y: 0.5))
    }

    @MainActor
    @Test("Size change preserves zoom instead of resetting to fit")
    func sizeChangePreservesZoom() {
        let view = ZoomingImageScrollView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        view.setSurface(viewerTestFrame(quality: .fullsize, width: 800, height: 600).surface)
        view.layoutIfNeeded()
        view.setZoomScale(2.25, animated: false)
        view.contentOffset = CGPoint(x: 120, y: 80)

        view.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        view.layoutIfNeeded()

        #expect(abs(view.zoomScale - 2.25) < 0.001)
        #expect(view.contentSize.width > view.bounds.width)
    }
}

@Suite("Viewer media identity")
struct ViewerMediaIdentityTests {
    @Test("Current and Original cannot share a byte cache identity")
    func currentAndOriginalAreDistinct() throws {
        let descriptor = viewerTestItems(count: 1)[0].descriptor
        let current = try ByteCacheKey(asset: descriptor, variant: .current, representation: .fullsize)
        let original = try ByteCacheKey(asset: descriptor, variant: .original, representation: .original)

        #expect(current != original)
        #expect(current.digest != original.digest)
    }
}
