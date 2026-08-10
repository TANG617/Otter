import Foundation

struct PixelSize: Hashable, Sendable {
    let width: Double
    let height: Double

    var longestDimension: Double { max(width, height) }
}
enum DynamicRangePolicy: String, Hashable, Sendable {
    case standard
    case displayP3
}

enum MediaContentMode: String, Hashable, Sendable {
    case aspectFit
    case aspectFill
}

struct RenderSpecification: Hashable, Sendable {
    let pixelBucket: Int
    let dynamicRange: DynamicRangePolicy
    let contentMode: MediaContentMode
}

enum MediaPurpose: String, Hashable, Sendable {
    case timeline
    case viewer
    case zoom
}

enum QualityPolicy: String, Hashable, Sendable {
    case fast
    case balanced
    case maximum
}

enum MediaPriority: Int, Comparable, Codable, Hashable, Sendable {
    case speculative = 10
    case prefetch = 30
    case neighbor = 60
    case visible = 80
    case interactive = 100

    static func < (lhs: MediaPriority, rhs: MediaPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MediaRequest: Hashable, Sendable {
    let asset: MediaAssetDescriptor
    let variant: AssetVariant
    let purpose: MediaPurpose
    let viewport: PixelSize
    let displayScale: Double
    let zoomScale: Double
    let qualityPolicy: QualityPolicy
    let dynamicRange: DynamicRangePolicy
    let contentMode: MediaContentMode
    let priority: MediaPriority

    init(
        asset: MediaAssetDescriptor,
        variant: AssetVariant = .current,
        purpose: MediaPurpose,
        viewport: PixelSize,
        displayScale: Double,
        zoomScale: Double = 1,
        qualityPolicy: QualityPolicy = .balanced,
        dynamicRange: DynamicRangePolicy = .standard,
        contentMode: MediaContentMode = .aspectFit,
        priority: MediaPriority
    ) {
        self.asset = asset
        self.variant = variant
        self.purpose = purpose
        self.viewport = viewport
        self.displayScale = displayScale
        self.zoomScale = zoomScale
        self.qualityPolicy = qualityPolicy
        self.dynamicRange = dynamicRange
        self.contentMode = contentMode
        self.priority = priority
    }

    var requiredPixels: Double {
        viewport.longestDimension * max(displayScale, 1) * max(zoomScale, 1) * 1.15
    }
}
