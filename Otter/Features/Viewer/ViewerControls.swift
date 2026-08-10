import SwiftUI

struct ViewerPage: View {
    let item: ViewerItem
    let pageIndex: Int
    let pageCount: Int
    let frame: MediaFrame?
    let resetGeneration: Int
    let isCurrent: Bool
    let onZoomScaleChanged: (CGFloat) -> Void
    let onInteractionChanged: (ViewerInteractionState) -> Void

    var body: some View {
        ZoomingMediaSurface(
            surface: frame?.surface,
            accessibilityLabel: ViewerAccessibilityID.pageLabel(
                item: item,
                index: pageIndex,
                count: pageCount
            ),
            accessibilityIdentifier: ViewerAccessibilityID.media(assetID: item.id),
            resetGeneration: resetGeneration,
            onZoomScaleChanged: isCurrent ? onZoomScaleChanged : { _ in },
            onInteractionChanged: isCurrent ? onInteractionChanged : { _ in }
        )
        .background(Color.black)
    }
}

struct ViewerBottomControls: View {
    @Binding var selectedVariant: AssetVariant
    @Binding var rating: AssetRating?

    let canGoPrevious: Bool
    let canGoNext: Bool
    let isLoadingVariant: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onFit: () -> Void
    let onDownload: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Picker("Photo Version", selection: $selectedVariant) {
                    Text("Current").tag(AssetVariant.current)
                    Text("Original").tag(AssetVariant.original)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier(ViewerAccessibilityID.variantPicker)

                if isLoadingVariant {
                    ProgressView()
                        .tint(.white)
                        .accessibilityLabel("Loading selected version")
                }
            }

            HStack(spacing: 10) {
                ViewerIconButton(
                    title: "Previous Photo",
                    systemImage: "chevron.left",
                    accessibilityIdentifier: ViewerAccessibilityID.previous,
                    isEnabled: canGoPrevious,
                    action: onPrevious
                )

                ViewerIconButton(
                    title: "Fit Photo",
                    systemImage: "arrow.down.right.and.arrow.up.left",
                    accessibilityIdentifier: ViewerAccessibilityID.fit,
                    action: onFit
                )

                ratingPicker

                ViewerIconButton(
                    title: "Download Photo",
                    systemImage: "square.and.arrow.down",
                    accessibilityIdentifier: ViewerAccessibilityID.download,
                    action: onDownload
                )

                ViewerIconButton(
                    title: "Next Photo",
                    systemImage: "chevron.right",
                    accessibilityIdentifier: ViewerAccessibilityID.next,
                    isEnabled: canGoNext,
                    action: onNext
                )
            }
        }
        .padding(10)
        .frame(maxWidth: 430)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var ratingPicker: some View {
        Picker("Rating", selection: $rating) {
            Text("Unrated").tag(nil as AssetRating?)
            Text("Reject").tag(AssetRating.rejected as AssetRating?)
            Text("1 Star").tag(AssetRating.one as AssetRating?)
            Text("2 Stars").tag(AssetRating.two as AssetRating?)
            Text("3 Stars").tag(AssetRating.three as AssetRating?)
            Text("4 Stars").tag(AssetRating.four as AssetRating?)
            Text("5 Stars").tag(AssetRating.five as AssetRating?)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 44, height: 44)
        .foregroundStyle(.white)
        .background(.thinMaterial, in: Circle())
        .accessibilityLabel("Rating, \(ViewerRatingLabel.text(for: rating))")
        .accessibilityIdentifier(ViewerAccessibilityID.rate)
    }
}

struct ViewerIconButton: View {
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .background(.thinMaterial, in: Circle())
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
