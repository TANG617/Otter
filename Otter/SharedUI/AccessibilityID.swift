import Foundation

enum AccessibilityID {
    enum Onboarding {
        static let screen = "onboarding.screen"
        static let serverURL = "onboarding.serverURL"
        static let serverURLError = "onboarding.serverURL.error"
        static let apiKey = "onboarding.apiKey"
        static let apiKeyError = "onboarding.apiKey.error"
        static let connect = "onboarding.connect"
        static let connectionStatus = "onboarding.connection.status"
    }

    enum Settings {
        static let screen = "settings.screen"
        static let cacheLimit = "settings.cache.limit"
        static let clearCache = "settings.cache.clear"
        static let actionStatus = "settings.action.status"
        static let diagnostics = "settings.diagnostics"
        static let signOut = "settings.signOut"
    }

    enum Diagnostics {
        static let screen = "diagnostics.screen"
        static let connectionStatus = "diagnostics.connection.status"
        static let assetCount = "diagnostics.assetCount"
        static let refresh = "diagnostics.refresh"
        static let copySummary = "diagnostics.copySummary"
        static let actionStatus = "diagnostics.action.status"
    }

    enum State {
        static let loading = "state.loading"
        static let empty = "state.empty"
        static let failure = "state.failure"
        static let retry = "state.retry"
    }
}
