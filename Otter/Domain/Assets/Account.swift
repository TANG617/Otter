import Foundation

struct Account: Codable, Hashable, Sendable {
    let namespace: UUID
    let serverURL: URL
    let userID: UUID?
    let serverVersion: String?
    let createdAt: Date
}

struct SyncState: Codable, Equatable, Sendable {
    let accountNamespace: UUID
    var lastIncrementalRefreshAt: Date?
    var lastFullReconciliationAt: Date?
    var highestObservedUpdatedAt: Date?
}

enum ServerMediaRepresentation: String, Codable, CaseIterable, Sendable {
    case thumbnail
    case preview
    case fullsize
}

struct RepresentationObservation: Codable, Equatable, Sendable {
    let mimeType: String
    let maximumObservedDimension: Int
    let byteCount: Int?
}

struct ServerMediaProfile: Codable, Equatable, Sendable {
    let accountNamespace: UUID
    var thumbnail: RepresentationObservation?
    var preview: RepresentationObservation?
    var fullsize: RepresentationObservation?

    subscript(representation: ServerMediaRepresentation) -> RepresentationObservation? {
        get {
            switch representation {
            case .thumbnail: thumbnail
            case .preview: preview
            case .fullsize: fullsize
            }
        }
        set {
            switch representation {
            case .thumbnail: thumbnail = newValue
            case .preview: preview = newValue
            case .fullsize: fullsize = newValue
            }
        }
    }
}
