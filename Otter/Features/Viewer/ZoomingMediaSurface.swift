import SwiftUI
import UIKit

@MainActor
struct ZoomingMediaSurface: UIViewRepresentable {
    let surface: RenderSurface?
    let accessibilityLabel: String
    let accessibilityIdentifier: String
    var isAccessibilityActive = true
    let resetGeneration: Int
    let onZoomScaleChanged: (CGFloat) -> Void
    let onInteractionChanged: (ViewerInteractionState) -> Void
    var reduceMotion = false
    var onSingleTap: () -> Void = {}
    var onDrag: (ViewerDragEvent) -> Void = { _ in }

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
            view.resetToFit(animated: !reduceMotion)
        }
    }

    private func configure(_ view: ZoomingImageScrollView) {
        view.onZoomScaleChanged = onZoomScaleChanged
        view.onInteractionChanged = onInteractionChanged
        view.onSingleTap = onSingleTap
        view.onDrag = onDrag
        view.reduceMotion = reduceMotion
        view.accessibilityLabel = accessibilityLabel
        view.accessibilityIdentifier = accessibilityIdentifier
        view.isAccessibilityElement = isAccessibilityActive
        view.accessibilityElementsHidden = !isAccessibilityActive
        view.updateAccessibilityZoomValue()
    }

    final class Coordinator {
        var resetGeneration: Int

        init(resetGeneration: Int) {
            self.resetGeneration = resetGeneration
        }
    }
}

@MainActor
final class ZoomingImageScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onZoomScaleChanged: (CGFloat) -> Void = { _ in }
    var onInteractionChanged: (ViewerInteractionState) -> Void = { _ in }
    var onSingleTap: () -> Void = {}
    var onDrag: (ViewerDragEvent) -> Void = { _ in }
    var reduceMotion = false

    private let imageView = UIImageView()
    private var currentSurface: RenderSurface?
    private var lastViewportSize: CGSize = .zero
    private var isApplyingGeometry = false
    private lazy var interactionPan = UIPanGestureRecognizer(target: self, action: #selector(handleInteractionPan(_:)))
    private var lockedAxis: ViewerGestureAxis?
    private var dragStartOffset: CGPoint = .zero
    private var didBeginCustomDrag = false
    private var isHorizontalHandoffActive = false

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
        let replacement = UIImage(cgImage: surface.cgImage)
        let shouldCrossFade = currentSurface != nil
        currentSurface = surface
        if shouldCrossFade {
            UIView.transition(
                with: imageView,
                duration: 0.12,
                options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.imageView.image = replacement
            }
        } else {
            imageView.image = replacement
        }
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
        updateAccessibilityZoomValue()
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

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard isHorizontalHandoffActive else { return }
        targetContentOffset.pointee = contentOffset
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === interactionPan || otherGestureRecognizer === interactionPan
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        onInteractionChanged(.zooming)
        defer { onInteractionChanged(.idle) }
        if zoomScale > minimumZoomScale + 0.01 {
            resetToFit(animated: !reduceMotion)
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
            animated: !reduceMotion
        )
    }

    @objc private func handleSingleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        onSingleTap()
    }

    @objc private func handleInteractionPan(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        let velocity = recognizer.velocity(in: self)

        switch recognizer.state {
        case .began:
            lockedAxis = nil
            didBeginCustomDrag = false
            isHorizontalHandoffActive = false
            dragStartOffset = contentOffset
        case .changed:
            if lockedAxis == nil {
                lockedAxis = ZoomGeometry.resolvedAxis(translation: translation)
            }
            guard let lockedAxis else { return }
            switch lockedAxis {
            case .horizontal:
                let handoff = horizontalHandoff(for: translation.x)
                guard isAtFit || handoff != 0 || didBeginCustomDrag else { return }
                emitDrag(axis: .horizontal, translation: handoff, velocity: horizontalVelocity(velocity.x, handoff: handoff))
                isHorizontalHandoffActive = handoff != 0
            case .vertical:
                guard isAtFit, translation.y > 0 || didBeginCustomDrag else { return }
                emitDrag(axis: .vertical, translation: max(translation.y, 0), velocity: velocity.y)
            }
        case .ended:
            finishDrag(translation: translation, velocity: velocity, cancelled: false)
        case .cancelled, .failed:
            finishDrag(translation: translation, velocity: velocity, cancelled: true)
        default:
            break
        }
    }

    @objc private func performAccessibilityZoomIn() -> Bool {
        guard imageView.image != nil else { return false }
        onInteractionChanged(.zooming)
        defer { onInteractionChanged(.idle) }
        let targetScale = min(maximumZoomScale, max(zoomScale * 2, 2))
        zoom(
            to: ZoomGeometry.zoomRect(
                scale: targetScale,
                center: CGPoint(x: imageView.bounds.midX, y: imageView.bounds.midY),
                viewportSize: bounds.size,
                maximumScale: maximumZoomScale
            ),
            animated: !reduceMotion
        )
        return true
    }

    @objc private func performAccessibilityFit() -> Bool {
        onInteractionChanged(.zooming)
        defer { onInteractionChanged(.idle) }
        resetToFit(animated: !reduceMotion)
        return true
    }

    private func commonInit() {
        delegate = self
        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = false
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

        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap(_:)))
        singleTap.require(toFail: doubleTap)
        addGestureRecognizer(singleTap)

        interactionPan.delegate = self
        interactionPan.cancelsTouchesInView = false
        addGestureRecognizer(interactionPan)

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
        updateAccessibilityZoomValue()
    }

    private var isAtFit: Bool {
        zoomScale <= minimumZoomScale + 0.01
    }

    func updateAccessibilityZoomValue() {
        guard !isAtFit else {
            accessibilityValue = "Fit"
            return
        }
        let tenths = max(10, Int((zoomScale * 10).rounded()))
        accessibilityValue = "\(tenths / 10).\(tenths % 10)× zoom"
    }

    private func horizontalHandoff(for translation: CGFloat) -> CGFloat {
        guard !isAtFit else { return translation }
        let range = horizontalContentOffsetRange
        return ZoomGeometry.horizontalPageHandoff(
            fingerTranslation: translation,
            startingOffset: dragStartOffset.x,
            minimumOffset: range.lowerBound,
            maximumOffset: range.upperBound
        )
    }

    private var horizontalContentOffsetRange: ClosedRange<CGFloat> {
        let minimum = -contentInset.left
        let maximum = max(minimum, contentSize.width - bounds.width + contentInset.right)
        return minimum...maximum
    }

    private func horizontalVelocity(_ velocity: CGFloat, handoff: CGFloat) -> CGFloat {
        guard handoff != 0 else { return 0 }
        return velocity.sign == handoff.sign ? velocity : 0
    }

    private func emitDrag(axis: ViewerGestureAxis, translation: CGFloat, velocity: CGFloat) {
        if !didBeginCustomDrag {
            didBeginCustomDrag = true
            onInteractionChanged(axis == .horizontal ? .paging : .dismissing)
            onDrag(ViewerDragEvent(axis: axis, phase: .began, translation: translation, velocity: velocity))
        } else {
            onDrag(ViewerDragEvent(axis: axis, phase: .changed, translation: translation, velocity: velocity))
        }
    }

    private func finishDrag(translation: CGPoint, velocity: CGPoint, cancelled: Bool) {
        defer {
            lockedAxis = nil
            didBeginCustomDrag = false
            isHorizontalHandoffActive = false
        }
        guard didBeginCustomDrag, let lockedAxis else { return }
        let value: CGFloat
        let projectedVelocity: CGFloat
        switch lockedAxis {
        case .horizontal:
            value = horizontalHandoff(for: translation.x)
            projectedVelocity = horizontalVelocity(velocity.x, handoff: value)
        case .vertical:
            value = max(translation.y, 0)
            projectedVelocity = velocity.y
        }
        onDrag(
            ViewerDragEvent(
                axis: lockedAxis,
                phase: cancelled ? .cancelled : .ended,
                translation: value,
                velocity: projectedVelocity
            )
        )
        onInteractionChanged(.idle)
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
