import Foundation

enum MediaQuality: Int, Comparable, Hashable, Sendable {
    case placeholder = 0
    case thumbnail = 10
    case preview = 20
    case fullsize = 30
    case originalDownsample = 40

    static func < (lhs: MediaQuality, rhs: MediaQuality) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}
enum MediaSource: String, Hashable, Sendable {
    case generatedPlaceholder
    case memoryCache
    case diskCache
    case network
}

struct MediaFrame: Sendable {
    let surface: RenderSurface
    let quality: MediaQuality
    let source: MediaSource
    let isFinalForCurrentDemand: Bool

    var containsRealMedia: Bool {
        quality != .placeholder && source != .generatedPlaceholder
    }
}
