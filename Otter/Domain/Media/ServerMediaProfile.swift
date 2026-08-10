import Foundation

struct RepresentationObservation: Codable, Equatable, Hashable, Sendable {
    let mimeType: String
    let maximumObservedDimension: Int
    let byteCount: Int?
    let redirectsCrossOrigin: Bool
}
struct ServerMediaProfile: Codable, Equatable, Hashable, Sendable {
    var thumbnail: RepresentationObservation?
    var preview: RepresentationObservation?
    var fullsize: RepresentationObservation?
    var supportsFullsize: Bool
    var supportsOriginal: Bool

    init(
        thumbnail: RepresentationObservation? = nil,
        preview: RepresentationObservation? = nil,
        fullsize: RepresentationObservation? = nil,
        supportsFullsize: Bool = true,
        supportsOriginal: Bool = true
    ) {
        self.thumbnail = thumbnail
        self.preview = preview
        self.fullsize = fullsize
        self.supportsFullsize = supportsFullsize
        self.supportsOriginal = supportsOriginal
    }

    func observation(for representation: RemoteRepresentation) -> RepresentationObservation? {
        switch representation {
        case .thumbnail: thumbnail
        case .preview: preview
        case .fullsize: fullsize
        case .original: nil
        }
    }
}
