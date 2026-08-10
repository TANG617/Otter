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
    let inFlightMediaRequests: Int
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
        In-flight media requests: \(inFlightMediaRequests)
        Fixture mode: \(usesFixtures ? "Yes" : "No")
        """
    }

    static let fixture = DiagnosticsSnapshot(
        appVersion: "1.0",
        buildNumber: "1",
        serverVersion: FixtureAccount.standard.serverVersion,
        connectionStatus: .connected,
        assetCount: FixtureLibraryScale.standard.rawValue,
        lastMetadataRefresh: FixtureLibraryGenerator.referenceDate,
        mediaCacheBytes: 0,
        inFlightMediaRequests: 0,
        usesFixtures: true
    )
}

enum DiagnosticsRefreshOutcome: Equatable, Sendable {
    case updated(DiagnosticsSnapshot)
    case failure(PresentationFailure)
}
