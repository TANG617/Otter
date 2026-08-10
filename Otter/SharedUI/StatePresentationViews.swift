import SwiftUI

struct LoadingStateView: View {
    let title: String
    let message: String?
    let accessibilityIdentifier: String

    init(
        _ title: String = "Loading",
        message: String? = nil,
        accessibilityIdentifier: String = AccessibilityID.State.loading
    ) {
        self.title = title
        self.message = message
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)

            Text(title)
                .font(.headline)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String
    let accessibilityIdentifier: String

    init(
        _ title: String,
        systemImage: String,
        message: String,
        accessibilityIdentifier: String = AccessibilityID.State.empty
    ) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.accessibilityIdentifier = accessibilityIdentifier
    }

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text(message)
        )
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

struct FailureStateView: View {
    let failure: PresentationFailure
    let retryTitle: String?
    let accessibilityIdentifier: String
    let onRetry: (() -> Void)?

    init(
        failure: PresentationFailure,
        retryTitle: String? = nil,
        accessibilityIdentifier: String = AccessibilityID.State.failure,
        onRetry: (() -> Void)? = nil
    ) {
        self.failure = failure
        self.retryTitle = retryTitle
        self.accessibilityIdentifier = accessibilityIdentifier
        self.onRetry = onRetry
    }

    var body: some View {
        ContentUnavailableView {
            Label(failure.title, systemImage: failure.systemImage)
        } description: {
            Text(failure.message)
        } actions: {
            if let retryTitle, let onRetry {
                Button(retryTitle, action: onRetry)
                    .accessibilityIdentifier(AccessibilityID.State.retry)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

#Preview("Loading") {
    LoadingStateView("Loading Library", message: "Preparing your timeline.")
}

#Preview("Empty") {
    EmptyStateView(
        "No Photos",
        systemImage: "photo.stack",
        message: "Photos from your Immich library will appear here."
    )
}

#Preview("Failure") {
    FailureStateView(
        failure: PresentationFailure(
            title: "Library Unavailable",
            message: "Check your connection and try again."
        ),
        retryTitle: "Retry",
        onRetry: {}
    )
}
