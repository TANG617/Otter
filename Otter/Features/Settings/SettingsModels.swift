import Foundation

enum SettingsCacheLimit: Int64, CaseIterable, Identifiable, Sendable {
    case mebibytes512 = 536_870_912
    case gibibyte1 = 1_073_741_824
    case gibibytes2 = 2_147_483_648
    case gibibytes5 = 5_368_709_120
    case gibibytes10 = 10_737_418_240

    var id: Int64 { rawValue }

    var title: String {
        ByteCountFormatter.string(fromByteCount: rawValue, countStyle: .binary)
    }
}

struct SettingsSnapshot: Equatable, Sendable {
    let accountDisplayName: String
    let serverDisplayName: String
    let cacheUsageBytes: Int64
    let cacheLimit: SettingsCacheLimit
    let appVersion: String
    let usesFixtures: Bool

    static let fixture = SettingsSnapshot(
        accountDisplayName: FixtureAccount.standard.accountDisplayName,
        serverDisplayName: FixtureAccount.standard.serverURL.host() ?? "Fixture Server",
        cacheUsageBytes: 0,
        cacheLimit: .gibibytes2,
        appVersion: "1.0",
        usesFixtures: true
    )
}

enum SettingsPendingAction: Equatable, Sendable {
    case clearCache
    case signOut
}

enum SettingsConfirmation: String, Equatable, Identifiable {
    case clearCache
    case signOut

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clearCache:
            "Clear Media Cache?"
        case .signOut:
            "Sign Out?"
        }
    }

    var message: String {
        switch self {
        case .clearCache:
            "Cached media will be removed. Otter can download it again when needed."
        case .signOut:
            "The active account will be removed from this device."
        }
    }

    var confirmationTitle: String {
        switch self {
        case .clearCache:
            "Clear Cache"
        case .signOut:
            "Sign Out"
        }
    }
}
