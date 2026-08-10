import Foundation

enum DiagnosticsConnectionStatus: Equatable, Sendable {
    case connected
    case degraded
    case offline
    case signedOut

    var title: String {
        switch self {
        case .connected:
            "Connected"
        case .degraded:
            "Degraded"
        case .offline:
            "Offline"
        case .signedOut:
            "Signed Out"
        }
    }

    var systemImage: String {
        switch self {
        case .connected:
            "checkmark.circle.fill"
        case .degraded:
            "exclamationmark.triangle.fill"
        case .offline:
            "network.slash"
        case .signedOut:
            "person.crop.circle.badge.xmark"
        }
    }
}

struct DiagnosticsSnapshot: Equatable, Sendable {
    let appVersion: String
    let buildNumber: String
    let serverVersion: String?
    let connectionStatus: DiagnosticsConnectionStatus
    let assetCount: Int
    let lastMetadataRefresh: Date?
    let mediaCacheBytes: Int64
    let memoryCacheBytes: Int64
    let inFlightMediaRequests: Int
    let queuedDecodeCount: Int
    let ratingWriteStatus: String
    let originalPermissionStatus: String
    let currentExportStatus: String
    let thumbnailObservation: RepresentationObservation?
    let previewObservation: RepresentationObservation?
    let fullsizeObservation: RepresentationObservation?
    let usesFixtures: Bool

    var safeTextSummary: String {
        let serverVersionText = serverVersion ?? "Unavailable"
        let lastRefreshText = lastMetadataRefresh?.formatted(.iso8601) ?? "Never"

        return """
        Otter Diagnostics
        App: \(appVersion) (\(buildNumber))
        Connection: \(connectionStatus.title)
        Server version: \(serverVersionText)
        Assets: \(assetCount)
        Last metadata refresh: \(lastRefreshText)
        Media cache bytes: \(mediaCacheBytes)
        Memory cache bytes: \(memoryCacheBytes)
        In-flight media requests: \(inFlightMediaRequests)
        Queued decodes: \(queuedDecodeCount)
        Rating write: \(ratingWriteStatus)
        Original permission: \(originalPermissionStatus)
        Current export: \(currentExportStatus)
        Thumbnail: \(Self.observationText(thumbnailObservation))
        Preview: \(Self.observationText(previewObservation))
        Fullsize: \(Self.observationText(fullsizeObservation))
        Fixture mode: \(usesFixtures ? "Yes" : "No")
        """
    }

    static func observationText(_ observation: RepresentationObservation?) -> String {
        guard let observation else { return "Not observed" }
        return "\(observation.mimeType), \(observation.maximumObservedDimension) px"
    }

    static let fixture = DiagnosticsSnapshot(
        appVersion: "1.0",
        buildNumber: "1",
        serverVersion: FixtureAccount.standard.serverVersion,
        connectionStatus: .connected,
        assetCount: FixtureLibraryScale.standard.rawValue,
        lastMetadataRefresh: FixtureLibraryGenerator.referenceDate,
        mediaCacheBytes: 0,
        memoryCacheBytes: 0,
        inFlightMediaRequests: 0,
        queuedDecodeCount: 0,
        ratingWriteStatus: "Available",
        originalPermissionStatus: "Available",
        currentExportStatus: "Available",
        thumbnailObservation: RepresentationObservation(
            mimeType: "image/webp",
            maximumObservedDimension: 250,
            byteCount: 12_000,
            redirectsCrossOrigin: false
        ),
        previewObservation: nil,
        fullsizeObservation: nil,
        usesFixtures: true
    )
}

enum DiagnosticsRefreshOutcome: Equatable, Sendable {
    case updated(DiagnosticsSnapshot)
    case failure(PresentationFailure)
}
