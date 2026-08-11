import Observation
import SwiftUI

@MainActor
struct ViewerFilmstrip: View {
    let items: [ViewerItem]
    let currentIndex: Int
    let frame: (UUID) -> MediaFrame?
    let pipeline: any MediaPipelineProtocol
    let onSelect: (Int) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var prefetchToken: PrefetchToken?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        ViewerFilmstripCell(
                            item: item,
                            index: index,
                            count: items.count,
                            isCurrent: index == currentIndex,
                            existingFrame: frame(item.id),
                            request: ViewerFilmstripDemand.request(
                                for: item,
                                displayScale: displayScale,
                                priority: priority(for: index)
                            ),
                            pipeline: pipeline,
                            onSelect: { onSelect(index) }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 4)
                .frame(minHeight: 60)
            }
            .frame(maxWidth: 760)
            .accessibilityIdentifier(ViewerAccessibilityID.filmstrip)
            .onChange(of: currentIndex, initial: true) { _, index in
                guard items.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(items[index].id, anchor: .center)
                }
                updatePrefetch(around: index)
            }
            .onChange(of: items.count) { _, _ in
                updatePrefetch(around: currentIndex)
            }
            .onDisappear {
                prefetchToken?.cancel()
                prefetchToken = nil
            }
        }
    }

    private func priority(for index: Int) -> MediaPriority {
        if index == currentIndex { return .visible }
        return abs(index - currentIndex) <= 2 ? .neighbor : .visible
    }

    private func updatePrefetch(around index: Int) {
        prefetchToken?.cancel()
        let requests = ViewerFilmstripDemand.prefetchRequests(
            items: items,
            currentIndex: index,
            displayScale: displayScale
        )
        prefetchToken = requests.isEmpty ? nil : pipeline.prefetch(requests)
    }
}

@MainActor
private struct ViewerFilmstripCell: View {
    let item: ViewerItem
    let index: Int
    let count: Int
    let isCurrent: Bool
    let existingFrame: MediaFrame?
    let request: MediaRequest
    let pipeline: any MediaPipelineProtocol
    let onSelect: () -> Void

    @State private var thumbnail = ViewerFilmstripThumbnailState()

    var body: some View {
        Button(action: onSelect) {
            thumbnailContent
                .frame(width: isCurrent ? 56 : 52, height: isCurrent ? 56 : 52)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    if isCurrent {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(Color.accentColor, lineWidth: 3)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Photo \(index + 1) of \(count)")
        .accessibilityValue(thumbnail.frame == nil ? "Loading thumbnail" : "Thumbnail loaded")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier("viewer.filmstrip.photo.\(index + 1)")
        .task(id: request) {
            await thumbnail.load(
                existingFrame: existingFrame,
                request: request,
                pipeline: pipeline
            )
        }
        .onDisappear { thumbnail.cancel() }
    }

    @ViewBuilder
    private var thumbnailContent: some View {
        if let surface = thumbnail.frame?.surface ?? existingFrame?.surface {
            Image(decorative: surface.cgImage, scale: 1)
                .resizable()
                .scaledToFill()
                .transition(.opacity)
        } else {
            ZStack {
                Color(uiColor: .quaternarySystemFill)
                Image(systemName: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor
@Observable
final class ViewerFilmstripThumbnailState {
    private(set) var frame: MediaFrame?
    private var requestToken: UUID?

    func load(
        existingFrame: MediaFrame?,
        request: MediaRequest,
        pipeline: any MediaPipelineProtocol
    ) async {
        let token = UUID()
        requestToken = token
        accept(existingFrame, token: token)
        accept(pipeline.peek(request), token: token)

        do {
            for try await candidate in pipeline.frames(for: request) {
                try Task.checkCancellation()
                accept(candidate, token: token)
            }
        } catch is CancellationError {
            return
        } catch {
            return
        }
    }

    func cancel() {
        requestToken = nil
    }

    private func accept(_ candidate: MediaFrame?, token: UUID) {
        guard requestToken == token, let candidate else { return }
        guard frame.map({ candidate.quality >= $0.quality }) ?? true else { return }
        frame = candidate
    }
}

enum ViewerFilmstripDemand {
    static let minimumPixels = 128
    static let maximumPixels = 192
    static let maximumPrefetchCount = 8

    static func request(
        for item: ViewerItem,
        displayScale: Double,
        priority: MediaPriority
    ) -> MediaRequest {
        let scale = max(displayScale, 1)
        let pixelDemand = min(max(56 * scale, Double(minimumPixels)), Double(maximumPixels))
        let logicalSide = pixelDemand / scale / 1.15
        return MediaRequest(
            asset: item.descriptor,
            variant: .current,
            purpose: .timeline,
            viewport: PixelSize(width: logicalSide, height: logicalSide),
            displayScale: scale,
            qualityPolicy: priority >= .neighbor ? .balanced : .fast,
            dynamicRange: .standard,
            contentMode: .aspectFill,
            priority: priority
        )
    }

    static func prefetchRequests(
        items: [ViewerItem],
        currentIndex: Int,
        displayScale: Double
    ) -> [MediaRequest] {
        guard items.indices.contains(currentIndex) else { return [] }
        return items.indices
            .filter { $0 != currentIndex }
            .sorted {
                let lhsDistance = abs($0 - currentIndex)
                let rhsDistance = abs($1 - currentIndex)
                return lhsDistance == rhsDistance ? $0 < $1 : lhsDistance < rhsDistance
            }
            .prefix(maximumPrefetchCount)
            .map { index in
                request(
                    for: items[index],
                    displayScale: displayScale,
                    priority: abs(index - currentIndex) <= 2 ? .neighbor : .prefetch
                )
            }
    }
}
