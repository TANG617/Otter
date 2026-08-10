import SwiftUI
import UIKit

@MainActor
struct ZoomingMediaSurface: UIViewRepresentable {
    let surface: RenderSurface?
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    let resetGeneration: Int
    let onZoomScaleChanged: (CGFloat) -> Void
    let onInteractionChanged: (ViewerInteractionState) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(resetGeneration: resetGeneration)
    }

    func makeUIView(context: Context) -> ZoomingImageScrollView {
        let view = ZoomingImageScrollView()
        configure(view)
        if let surface {
            view.setSurface(surface)
        }
        return view
    }

    func updateUIView(_ view: ZoomingImageScrollView, context: Context) {
        configure(view)
        if let surface {
            view.setSurface(surface)
        } else {
            view.clearSurface()
        }
        if context.coordinator.resetGeneration != resetGeneration {
            context.coordinator.resetGeneration = resetGeneration
            view.resetToFit(animated: true)
        }
    }

    private func configure(_ view: ZoomingImageScrollView) {
        view.onZoomScaleChanged = onZoomScaleChanged
        view.onInteractionChanged = onInteractionChanged
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = accessibilityIdentifier
    }

    final class Coordinator {
        var resetGeneration: Int

        init(resetGeneration: Int) {
            self.resetGeneration = resetGeneration
        }
    }
}

@MainActor
final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate {
    var onZoomScaleChanged: (CGFloat) -> Void = { _ in }
    var onInteractionChanged: (ViewerInteractionState) -> Void = { _ in }

    private let imageView = UIImageView()
    private var currentSurface: RenderSurface?
    private var lastViewportSize: CGSize = .zero
    private var isApplyingGeometry = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    override func layoutSubviews() {
        let previousSize = lastViewportSize
        let needsLayout = bounds.size != previousSize && currentSurface != nil
        let snapshot = needsLayout ? captureSnapshot(viewportSize: previousSize) : nil
        super.layoutSubviews()
        guard needsLayout, !isApplyingGeometry else {
            centerContent()
            return
        }
        applyGeometry(snapshot: snapshot ?? ZoomViewportSnapshot(zoomScale: 1, anchor: .center))
    }

    func setSurface(_ surface: RenderSurface) {
        guard currentSurface !== surface else { return }
        let snapshot = captureSnapshot(viewportSize: bounds.size)
        currentSurface = surface
        imageView.image = UIImage(cgImage: surface.cgImage)
        applyGeometry(snapshot: snapshot)
    }

    func clearSurface() {
        currentSurface = nil
        imageView.image = nil
        imageView.frame = .zero
        contentSize = .zero
        zoomScale = 1
    }

    func resetToFit(animated: Bool) {
        setZoomScale(minimumZoomScale, animated: animated)
        if !animated {
            centerContent()
        }
        onZoomScaleChanged(minimumZoomScale)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        imageView.image == nil ? nil : imageView
    }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        guard !isApplyingGeometry else { return }
        onInteractionChanged(.zooming)
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        guard !isApplyingGeometry else { return }
        onZoomScaleChanged(zoomScale)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        guard !isApplyingGeometry else { return }
        onZoomScaleChanged(scale)
        onInteractionChanged(.idle)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !isApplyingGeometry else { return }
        onInteractionChanged(.panning)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard !decelerate, !isApplyingGeometry else { return }
        onInteractionChanged(.idle)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard !isApplyingGeometry else { return }
        onInteractionChanged(.idle)
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        onInteractionChanged(.zooming)
        if zoomScale > minimumZoomScale + 0.01 {
            resetToFit(animated: true)
            return
        }
        let targetScale = min(maximumZoomScale, 2.5)
        let center = recognizer.location(in: imageView)
        zoom(
            to: ZoomGeometry.zoomRect(
                scale: targetScale,
                center: center,
                viewportSize: bounds.size,
                maximumScale: maximumZoomScale
            ),
            animated: true
        )
    }

    @objc private func performAccessibilityZoomIn() -> Bool {
        guard imageView.image != nil else { return false }
        onInteractionChanged(.zooming)
        let targetScale = min(maximumZoomScale, max(zoomScale * 2, 2))
        zoom(
            to: ZoomGeometry.zoomRect(
                scale: targetScale,
                center: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY),
                viewportSize: bounds.size,
                maximumScale: maximumZoomScale
            ),
            animated: true
        )
        return true
    }

    @objc private func performAccessibilityFit() -> Bool {
        resetToFit(animated: true)
        return true
    }

    private func commonInit() {
        delegate = self
        backgroundColor = .black
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        minimumZoomScale = 1
        maximumZoomScale = 4
        contentInsetAdjustmentBehavior = .never

        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)

        isAccessibilityElement = true
        accessibilityTraits = .image
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(
                name: "Zoom In",
                target: self,
                selector: #selector(performAccessibilityZoomIn)
            ),
            UIAccessibilityCustomAction(
                name: "Fit Photo",
                target: self,
                selector: #selector(performAccessibilityFit)
            ),
        ]
    }

    private func captureSnapshot(viewportSize: CGSize) -> ZoomViewportSnapshot {
        guard imageView.bounds.width > 0,
              imageView.bounds.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else {
            return ZoomViewportSnapshot(zoomScale: max(zoomScale, 1), anchor: .center)
        }
        let visibleCenter = CGPoint(
            x: bounds.origin.x + viewportSize.width / 2,
            y: bounds.origin.y + viewportSize.height / 2
        )
        let point = imageView.convert(visibleCenter, from: self)
        return ZoomViewportSnapshot(
            zoomScale: ZoomGeometry.clampedZoomScale(zoomScale),
            anchor: NormalizedPhotoAnchor(
                x: point.x / imageView.bounds.width,
                y: point.y / imageView.bounds.height
            )
        )
    }

    private func applyGeometry(snapshot: ZoomViewportSnapshot) {
        guard let surface = currentSurface, bounds.width > 0, bounds.height > 0 else { return }
        isApplyingGeometry = true
        defer { isApplyingGeometry = false }

        setZoomScale(1, animated: false)
        imageView.transform = .identity
        let fitted = ZoomGeometry.aspectFitSize(
            imageSize: CGSize(width: surface.pixelWidth, height: surface.pixelHeight),
            viewportSize: bounds.size
        )
        imageView.frame = CGRect(origin: .zero, size: fitted)
        contentSize = fitted
        minimumZoomScale = 1
        maximumZoomScale = 4
        setZoomScale(
            ZoomGeometry.clampedZoomScale(snapshot.zoomScale, minimum: minimumZoomScale, maximum: maximumZoomScale),
            animated: false
        )
        centerContent()
        restore(anchor: snapshot.anchor)
        lastViewportSize = bounds.size
        onZoomScaleChanged(zoomScale)
    }

    private func centerContent() {
        let horizontal = max((bounds.width - contentSize.width) / 2, 0)
        let vertical = max((bounds.height - contentSize.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    private func restore(anchor: NormalizedPhotoAnchor) {
        guard imageView.bounds.width > 0, imageView.bounds.height > 0 else { return }
        let imagePoint = CGPoint(
            x: imageView.bounds.width * anchor.x,
            y: imageView.bounds.height * anchor.y
        )
        let projected = imageView.convert(imagePoint, to: self)
        let visibleCenter = CGPoint(x: bounds.midX, y: bounds.midY)
        let targetOffset = CGPoint(
            x: contentOffset.x + projected.x - visibleCenter.x,
            y: contentOffset.y + projected.y - visibleCenter.y
        )
        setContentOffset(targetOffset, animated: false)
    }
}
