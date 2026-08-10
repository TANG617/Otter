import Foundation

enum AppRoute: Hashable, Sendable {
    case library
    case viewer(assetID: UUID)
    case settings
    case diagnostics
}

