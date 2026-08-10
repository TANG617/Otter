import SwiftUI

struct AppRootView: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .signedOut, .connecting, .authenticationInvalid:
                OnboardingPlaceholderView()
            case .active, .fixture:
                LibraryPlaceholderView()
            }
        }
    }
}

private struct OnboardingPlaceholderView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Otter", systemImage: "photo.on.rectangle.angled")
        } description: {
            Text("Native Photos for Immich")
        }
        .accessibilityIdentifier("onboarding.placeholder")
    }
}

private struct LibraryPlaceholderView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView(
                "Fixture Library",
                systemImage: "photo.stack",
                description: Text("The deterministic fixture environment is ready.")
            )
            .navigationTitle("Library")
            .accessibilityIdentifier("library.placeholder")
        }
    }
}

