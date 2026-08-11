import SwiftUI

struct ViewerBottomToolbar: ToolbarContent {
    @Binding var selectedVariant: AssetVariant
    @Binding var rating: AssetRating?
    @Binding var isFavorite: Bool

    let isLoadingVariant: Bool
    let downloadState: ViewerDownloadState
    let onInfo: () -> Void
    let onDownload: () -> Void

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            ViewerDownloadButton(
                state: downloadState,
                action: onDownload
            )

            ViewerRatingMenu(
                rating: $rating,
                isFavorite: $isFavorite
            )

            Spacer()

            Button(action: onInfo) {
                Image(systemName: "info.circle")
            }
            .accessibilityLabel("Photo Info")
            .accessibilityIdentifier(ViewerAccessibilityID.info)

            ViewerMoreMenu(
                selectedVariant: $selectedVariant,
                isLoadingVariant: isLoadingVariant
            )
        }
    }
}

struct ViewerTopMoreMenu: View {
    @Binding var selectedVariant: AssetVariant
    let isLoadingVariant: Bool
    let onInfo: () -> Void

    var body: some View {
        Menu {
            Button("Info", systemImage: "info.circle", action: onInfo)
            Divider()
            variantPicker
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More options")
    }

    private var variantPicker: some View {
        Picker("Photo Version", selection: $selectedVariant) {
            Label("Current Version", systemImage: "photo")
                .tag(AssetVariant.current)
            Label("Original", systemImage: "photo.badge.arrow.down")
                .tag(AssetVariant.original)
        }
    }
}

private struct ViewerDownloadButton: View {
    let state: ViewerDownloadState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(state.isWorking)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(accessibilityValue)
        .accessibilityIdentifier(ViewerAccessibilityID.download)
    }

    private var systemImage: String {
        switch state {
        case .idle: "square.and.arrow.down"
        case .working: "arrow.down.circle.dotted"
        case .completed: "checkmark.circle.fill"
        case .failed: "arrow.clockwise.circle"
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .idle: "Download Photo"
        case .working: "Downloading Photo"
        case .completed: "Photo Saved"
        case .failed: "Retry Download"
        }
    }

    private var accessibilityValue: String {
        switch state {
        case .idle: ""
        case .working: "In progress"
        case .completed: "Complete"
        case let .failed(failure): failure.message
        }
    }
}

private struct ViewerRatingMenu: View {
    @Binding var rating: AssetRating?
    @Binding var isFavorite: Bool

    var body: some View {
        Menu {
            ForEach(ViewerRatingChoice.stars.reversed()) { choice in
                ratingButton(
                    title: choice.title,
                    value: choice.value,
                    systemImage: "star.fill"
                )
            }

            ratingButton(
                title: "Unrated",
                value: nil,
                systemImage: "star.slash"
            )

            Divider()

            Toggle(isOn: $isFavorite) {
                Label("Favourite", systemImage: isFavorite ? "heart.fill" : "heart")
            }
            .accessibilityIdentifier(ViewerAccessibilityID.favorite)
        } label: {
            Image(systemName: controlSymbol)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel("Rating, \(ViewerRatingLabel.text(for: rating))")
        .accessibilityValue(isFavorite ? "Favourite" : "")
        .accessibilityHint("Press and slide to choose Favourite, Unrated, or one to five stars")
        .accessibilityIdentifier(ViewerAccessibilityID.rate)
    }

    private var controlSymbol: String {
        if isFavorite { return "heart.fill" }
        return rating == nil ? "star" : "star.fill"
    }

    private func ratingButton(
        title: String,
        value: AssetRating?,
        systemImage: String
    ) -> some View {
        Button {
            rating = value
        } label: {
            Label(title, systemImage: rating == value ? "checkmark" : systemImage)
        }
        .accessibilityIdentifier(value.map { "viewer.rating.\($0.rawValue)" } ?? "viewer.rating.unrated")
    }
}

private struct ViewerMoreMenu: View {
    @Binding var selectedVariant: AssetVariant
    let isLoadingVariant: Bool

    var body: some View {
        Menu {
            Picker("Photo Version", selection: $selectedVariant) {
                Label("Current Version", systemImage: "photo")
                    .tag(AssetVariant.current)
                Label("Original", systemImage: "photo.badge.arrow.down")
                    .tag(AssetVariant.original)
            }

            if isLoadingVariant {
                Label("Loading selected version", systemImage: "progress.indicator")
                    .disabled(true)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .accessibilityLabel("More options")
        .accessibilityValue("\(variantTitle)\(isLoadingVariant ? ", loading" : "")")
        .accessibilityIdentifier(ViewerAccessibilityID.variantPicker)
    }

    private var variantTitle: String {
        selectedVariant == .current ? "Current Version" : "Original"
    }
}

struct ViewerRatingChoice: Identifiable, Equatable, Sendable {
    let value: AssetRating
    let title: String

    var id: Int { value.rawValue }
    var accessibilityIdentifier: String { "viewer.rating.\(value.rawValue)" }

    static let stars = [
        ViewerRatingChoice(value: .one, title: "1 Star"),
        ViewerRatingChoice(value: .two, title: "2 Stars"),
        ViewerRatingChoice(value: .three, title: "3 Stars"),
        ViewerRatingChoice(value: .four, title: "4 Stars"),
        ViewerRatingChoice(value: .five, title: "5 Stars")
    ]
}
