import Foundation

struct RepresentationPlanStep: Equatable, Hashable, Sendable {
    let representation: RemoteRepresentation
    let renderSpecification: RenderSpecification
    let quality: MediaQuality
}
enum CoverageDecision: Equatable, Sendable {
    case upgrade
    case hold
    case sufficient
}

struct RepresentationPlanner: Sendable {
    func coverageDecision(availablePixels: Int, requiredPixels: Double) -> CoverageDecision {
        guard requiredPixels > 0 else { return .sufficient }
        let coverage = Double(availablePixels) / requiredPixels
        if coverage >= 1 { return .sufficient }
        if coverage < 0.85 { return .upgrade }
        return .hold
    }

    func plan(for request: MediaRequest, profile: ServerMediaProfile) throws -> [RepresentationPlanStep] {
        if request.purpose == .timeline, request.variant == .original {
            throw MediaError.timelineOriginalForbidden
        }

        let bucket = PixelBucket.normalized(for: request.requiredPixels, purpose: request.purpose)
        let spec = RenderSpecification(
            pixelBucket: bucket,
            dynamicRange: request.dynamicRange,
            contentMode: request.contentMode
        )

        if request.variant == .original {
            guard profile.supportsOriginal else {
                throw MediaError.unavailableRepresentation(.original)
            }
            return [.init(representation: .original, renderSpecification: spec, quality: .originalDownsample)]
        }

        switch request.purpose {
        case .timeline:
            var steps = [step(.thumbnail, .thumbnail, spec)]
            let observedThumbnail = profile.thumbnail?.maximumObservedDimension
            if observedThumbnail == nil || coverageDecision(
                availablePixels: observedThumbnail ?? 0,
                requiredPixels: request.requiredPixels
            ) == .upgrade {
                steps.append(step(.preview, .preview, spec))
            }
            return steps

        case .viewer:
            var steps = [step(.preview, .preview, spec)]
            if profile.supportsFullsize,
               shouldAppendUpgrade(observation: profile.preview, requiredPixels: request.requiredPixels) {
                steps.append(step(.fullsize, .fullsize, spec))
            }
            return steps

        case .zoom:
            var steps = [step(.preview, .preview, spec)]
            if profile.supportsFullsize {
                steps.append(step(.fullsize, .fullsize, spec))
            }
            return steps
        }
    }

    private func shouldAppendUpgrade(
        observation: RepresentationObservation?,
        requiredPixels: Double
    ) -> Bool {
        guard let observation else { return true }
        return coverageDecision(
            availablePixels: observation.maximumObservedDimension,
            requiredPixels: requiredPixels
        ) == .upgrade
    }

    private func step(
        _ representation: RemoteRepresentation,
        _ quality: MediaQuality,
        _ specification: RenderSpecification
    ) -> RepresentationPlanStep {
        .init(representation: representation, renderSpecification: specification, quality: quality)
    }
}
