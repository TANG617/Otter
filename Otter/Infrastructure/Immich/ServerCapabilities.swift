import Foundation

struct SemanticVersion: Codable, Hashable, Sendable, Comparable, CustomStringConvertible {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: String?

    init(major: Int, minor: Int, patch: Int, prerelease: String? = nil) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    var description: String {
        let base = "\(major).\(minor).\(patch)"
        return prerelease.map { base + "-" + $0 } ?? base
    }

    static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (lhs?, rhs?): return lhs < rhs
        }
    }
}

enum CapabilityUnavailableReason: Equatable, Sendable {
    case apiKeyAuthenticationUnsupported
    case serverVersionReadOnly
    case renditionUnsupported
}

enum CapabilityAvailability: Equatable, Sendable {
    case available
    case unverified
    case unavailable(CapabilityUnavailableReason)
}

struct ServerCapabilities: Equatable, Sendable {
    let metadataSearch: CapabilityAvailability
    let currentDownload: CapabilityAvailability
    let originalDownload: CapabilityAvailability
    let ratingWrite: CapabilityAvailability
    let syncStream: CapabilityAvailability
}

struct ServerProbeResult: Equatable, Sendable {
    let version: SemanticVersion
    let capabilities: ServerCapabilities
}

enum ImmichCapabilityProbe {
    static func capabilities(for version: SemanticVersion) -> ServerCapabilities {
        if version.major < 3 {
            return ServerCapabilities(
                metadataSearch: .unverified,
                currentDownload: .unverified,
                originalDownload: .unverified,
                ratingWrite: .unavailable(.serverVersionReadOnly),
                syncStream: .unavailable(.apiKeyAuthenticationUnsupported)
            )
        }
        return ServerCapabilities(
            metadataSearch: version.major == 3 ? .available : .unverified,
            currentDownload: version.major == 3 ? .available : .unverified,
            originalDownload: .unverified,
            ratingWrite: .unverified,
            syncStream: .unavailable(.apiKeyAuthenticationUnsupported)
        )
    }
}
