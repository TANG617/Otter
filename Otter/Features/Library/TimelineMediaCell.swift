import SwiftUI

@MainActor
struct TimelineMediaCell: View {
    let asset: TimelineAsset
    let index: Int
    let mediaClient: TimelineMediaClient
    let onSelect: @MainActor (TimelineAsset, MediaFrame?) -> Void
    let onVisible: @MainActor (Int, Double, Double) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var frame: MediaFrame?
    @State private var loadFailed = false

    private let accessibilityLabel: String

    init(
        asset: TimelineAsset,
        index: Int,
        mediaClient: TimelineMediaClient,
        calendar: Calendar,
        onSelect: @escaping @MainActor (TimelineAsset, MediaFrame?) -> Void,
        onVisible: @escaping @MainActor (Int, Double, Double) -> Void
    ) {
        self.asset = asset
        self.index = index
        self.mediaClient = mediaClient
        self.onSelect = onSelect
        self.onVisible = onVisible
        accessibilityLabel = TimelineAccessibilityLabel.asset(asset, calendar: calendar)
    }

    var body: some View {
        GeometryReader { proxy in
            let side = max(proxy.size.width, 1)
            let request = TimelineMediaDemand.request(
                for: asset,
                cellSide: side,
                displayScale: displayScale,
                priority: .visible
            )

            Button {
                onSelect(asset, frame)
            } label: {
                ZStack {
                    Color.secondary.opacity(0.12)

                    if let frame {
                        Image(decorative: frame.surface.cgImage, scale: displayScale)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else if loadFailed {
                        Image(systemName: "photo")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    if let rating = asset.rating {
                        ratingBadge(rating)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .clipped()
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(TimelineAccessibilityID.asset(asset.id))
            .task(id: request) {
                onVisible(index, side, displayScale)
                await load(request)
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder
    private func ratingBadge(_ rating: AssetRating) -> some View {
        VStack {
            HStack {
                Spacer()
                Image(systemName: rating == .rejected ? "xmark" : "star.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(5)
                    .background(.black.opacity(0.62), in: Circle())
                    .padding(5)
            }
            Spacer()
        }
        .accessibilityHidden(true)
    }

    private func load(_ request: MediaRequest) async {
        loadFailed = false
        if let cached = mediaClient.peek(request) {
            accept(cached)
        }

        do {
            for try await nextFrame in mediaClient.frames(request) {
                try Task.checkCancellation()
                accept(nextFrame)
            }
        } catch is CancellationError {
            return
        } catch {
            loadFailed = frame == nil
        }
    }

    private func accept(_ candidate: MediaFrame) {
        guard frame.map({ candidate.quality >= $0.quality }) ?? true else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            frame = candidate
        }
    }
}
