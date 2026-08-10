import SwiftUI

@main
struct OtterApp: App {
    @State private var environment = AppEnvironment.makeDefault()

    var body: some Scene {
        WindowGroup {
            AppRootView()
                .environment(environment)
                .environment(environment.session)
        }
    }
}

