import Foundation

struct RepresentationObservation: Codable, Equatable, Hashable, Sendable {
    let mimeType: String
    let maximumObservedDimension: Int
    let byteCount: Int?
    let redirectsCrossOrigin: Bool

    func merging(_ newer: RepresentationObservation) -> RepresentationObservation {
        let newerHasLargerDimension = newer.maximumObservedDimension > maximumObservedDimension
        return RepresentationObservation(
            // MIME describes the highest-resolution observation retained. Equal-sized
            // observations keep the established value instead of oscillating by asset.
            mimeType: newerHasLargerDimension ? newer.mimeType : mimeType,
            maximumObservedDimension: max(maximumObservedDimension, newer.maximumObservedDimension),
            // The largest observed payload is the conservative server-level cost signal.
            byteCount: [byteCount, newer.byteCount].compactMap { $0 }.max(),
            redirectsCrossOrigin: redirectsCrossOrigin || newer.redirectsCrossOrigin
        )
    }
}

enum FullsizeSupport: String, Codable, Equatable, Hashable, Sendable {
    case unknown
    case supported
    case unsupported

    func merging(_ newer: FullsizeSupport) -> FullsizeSupport {
        switch (self, newer) {
        case (.unsupported, _), (_, .unsupported): .unsupported
        case (.supported, _), (_, .supported): .supported
        case (.unknown, .unknown): .unknown
        }
    }
}

struct ServerMediaProfile: Codable, Equatable, Hashable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case thumbnail
        case preview
        case fullsize
        case fullsizeSupport
        case supportsFullsize
        case supportsOriginal
    }

    var thumbnail: RepresentationObservation?
    var preview: RepresentationObservation?
    var fullsize: RepresentationObservation?
    var fullsizeSupport: FullsizeSupport
    var supportsOriginal: Bool

    init(
        thumbnail: RepresentationObservation? = nil,
        preview: RepresentationObservation? = nil,
        fullsize: RepresentationObservation? = nil,
        fullsizeSupport: FullsizeSupport = .unknown,
        supportsOriginal: Bool = true
    ) {
        self.thumbnail = thumbnail
        self.preview = preview
        self.fullsize = fullsize
        self.fullsizeSupport = fullsizeSupport
        self.supportsOriginal = supportsOriginal
    }

    var shouldProbeFullsize: Bool { fullsizeSupport != .unsupported }

    mutating func merge(
        _ observation: RepresentationObservation,
        for representation: RemoteRepresentation
    ) {
        switch representation {
        case .thumbnail:
            thumbnail = thumbnail?.merging(observation) ?? observation
        case .preview:
            preview = preview?.merging(observation) ?? observation
        case .fullsize:
            fullsize = fullsize?.merging(observation) ?? observation
            fullsizeSupport = fullsizeSupport.merging(.supported)
        case .original:
            break
        }
    }

    mutating func markFullsizeUnsupported() {
        fullsizeSupport = fullsizeSupport.merging(.unsupported)
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thumbnail = try container.decodeIfPresent(RepresentationObservation.self, forKey: .thumbnail)
        preview = try container.decodeIfPresent(RepresentationObservation.self, forKey: .preview)
        fullsize = try container.decodeIfPresent(RepresentationObservation.self, forKey: .fullsize)
        if let support = try container.decodeIfPresent(FullsizeSupport.self, forKey: .fullsizeSupport) {
            fullsizeSupport = support
        } else if let legacy = try container.decodeIfPresent(Bool.self, forKey: .supportsFullsize) {
            fullsizeSupport = legacy ? .supported : .unsupported
        } else {
            fullsizeSupport = .unknown
        }
        supportsOriginal = try container.decodeIfPresent(Bool.self, forKey: .supportsOriginal) ?? true
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(thumbnail, forKey: .thumbnail)
        try container.encodeIfPresent(preview, forKey: .preview)
        try container.encodeIfPresent(fullsize, forKey: .fullsize)
        try container.encode(fullsizeSupport, forKey: .fullsizeSupport)
        try container.encode(supportsOriginal, forKey: .supportsOriginal)
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
