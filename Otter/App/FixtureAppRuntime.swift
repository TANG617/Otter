import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct FixtureAppRuntime: Sendable {
    let accountNamespace: UUID
    let assetStore: FixtureAssetStore
    let mediaPipeline: FixtureMediaPipeline
    let exporter: FixtureAssetExporter

    static func make(configuration: FixtureLibraryConfiguration) -> FixtureAppRuntime {
        let library = FixtureLibraryGenerator.generate(configuration: configuration)
        let assets = library.items.map { item in
            TimelineAsset(
                accountNamespace: library.account.accountNamespace,
                id: item.id,
                ownerID: nil,
                mediaType: .image,
                localDateTime: item.capturedAt,
                fileCreatedAt: item.capturedAt,
                createdAt: item.capturedAt,
                updatedAt: item.capturedAt,
                width: item.pixelWidth,
                height: item.pixelHeight,
                thumbhash: nil,
                checksum: "fixture-\(item.ordinal)",
                originalFileName: "fixture-\(item.ordinal).png",
                originalMimeType: "image/png",
                isFavorite: false,
                isEdited: item.hasEdits,
                isArchived: false,
                isTrashed: false,
                visibility: "timeline",
                rating: item.rating.flatMap(AssetRating.init(rawValue:))
            )
        }
        return FixtureAppRuntime(
            accountNamespace: library.account.accountNamespace,
            assetStore: FixtureAssetStore(assets: assets),
            mediaPipeline: FixtureMediaPipeline(),
            exporter: FixtureAssetExporter()
        )
    }
}

actor FixtureAssetExporter: AssetExporting {
    private let root: URL
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        root = fileManager.temporaryDirectory.appendingPathComponent("OtterFixtureExports", isDirectory: true)
    }

    func prepare(asset: MediaAssetDescriptor, variant: ExportVariant) throws -> PreparedExport {
        let id = UUID()
        let directory = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = variant == .current ? "fixture-current.png" : "fixture-original.png"
        let url = directory.appendingPathComponent(filename)
        guard let context = CGContext(
            data: nil,
            width: 64,
            height: 64,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw AssetExportError.transport }
        context.setFillColor(red: 0.18, green: 0.42, blue: 0.64, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
              ) else { throw AssetExportError.transport }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw AssetExportError.transport }
        return PreparedExport(
            id: id,
            fileURL: url,
            filename: filename,
            mimeType: "image/png",
            variant: variant
        )
    }

    func cleanup(_ export: PreparedExport) {
        let directory = export.fileURL.deletingLastPathComponent().standardizedFileURL
        guard directory.deletingLastPathComponent() == root.standardizedFileURL else { return }
        try? fileManager.removeItem(at: directory)
    }
}

actor FixtureAssetStore: AssetStore {
    private var assets: [TimelineAsset]
    private var indexByID: [UUID: Int]

    init(assets: [TimelineAsset]) {
        self.assets = assets.sorted {
            if $0.timelineDate != $1.timelineDate { return $0.timelineDate > $1.timelineDate }
            return $0.id.uuidString.lowercased() > $1.id.uuidString.lowercased()
        }
        indexByID = Dictionary(uniqueKeysWithValues: self.assets.enumerated().map { ($0.element.id, $0.offset) })
    }

    func localPage(_ request: TimelinePageRequest) -> TimelineAssetPage {
        let start: Int
        if let cursor = request.after, let index = indexByID[cursor.assetID] {
            start = index + 1
        } else {
            start = 0
        }
        guard start < assets.count else { return .init(assets: [], nextCursor: nil) }
        let end = min(start + request.limit, assets.count)
        let page = Array(assets[start..<end])
        let next = end < assets.count ? page.last.map {
            TimelineCursor(date: $0.timelineDate, assetID: $0.id)
        } : nil
        return TimelineAssetPage(assets: page, nextCursor: next)
    }

    func localAsset(id: UUID, accountNamespace: UUID) -> TimelineAsset? {
        guard let index = indexByID[id], assets[index].accountNamespace == accountNamespace else { return nil }
        return assets[index]
    }

    func refresh(accountNamespace: UUID, mode: AssetRefreshMode) -> AssetRefreshResult {
        AssetRefreshResult(
            receivedCount: 0,
            storedCount: assets.count,
            deletedCount: 0,
            highestObservedUpdatedAt: assets.first?.updatedAt
        )
    }

    func setRating(_ rating: AssetRating?, assetID: UUID) -> TimelineAsset? {
        guard let index = indexByID[assetID] else { return nil }
        let old = assets[index]
        let updated = TimelineAsset(
            accountNamespace: old.accountNamespace,
            id: old.id,
            ownerID: old.ownerID,
            mediaType: old.mediaType,
            localDateTime: old.localDateTime,
            fileCreatedAt: old.fileCreatedAt,
            createdAt: old.createdAt,
            updatedAt: old.updatedAt,
            width: old.width,
            height: old.height,
            thumbhash: old.thumbhash,
            checksum: old.checksum,
            originalFileName: old.originalFileName,
            originalMimeType: old.originalMimeType,
            isFavorite: old.isFavorite,
            isEdited: old.isEdited,
            isArchived: old.isArchived,
            isTrashed: old.isTrashed,
            visibility: old.visibility,
            rating: rating
        )
        assets[index] = updated
        return updated
    }
}

final class FixtureMediaPipeline: MediaPipelineProtocol, @unchecked Sendable {
    private let cache = NSCache<FixtureRenderKey, RenderSurface>()
    private let renderQueue = DispatchQueue(label: "com.tang617.otter.fixture-render", qos: .userInitiated)

    init() {
        cache.countLimit = 256
        cache.totalCostLimit = 64 * 1_024 * 1_024
    }

    func peek(_ request: MediaRequest) -> MediaFrame? {
        let key = FixtureRenderKey(request: request)
        guard let surface = cache.object(forKey: key) else { return nil }
        return MediaFrame(
            surface: surface,
            quality: quality(for: request),
            source: .memoryCache,
            isFinalForCurrentDemand: true
        )
    }

    func frames(for request: MediaRequest) -> AsyncThrowingStream<MediaFrame, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    if let cached = self.peek(request) {
                        continuation.yield(cached)
                        continuation.finish()
                        return
                    }
                    let key = FixtureRenderKey(request: request)
                    let surface = try await self.makeSurface(
                        assetID: request.asset.id,
                        variant: request.variant,
                        pixelSize: key.pixelSize
                    )
                    try Task.checkCancellation()
                    self.cache.setObject(surface, forKey: key, cost: surface.estimatedByteCost)
                    continuation.yield(
                        MediaFrame(
                            surface: surface,
                            quality: self.quality(for: request),
                            source: .generatedPlaceholder,
                            isFinalForCurrentDemand: true
                        )
                    )
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    func prefetch(_ requests: [MediaRequest]) -> PrefetchToken {
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for request in requests.prefix(24) {
                    group.addTask {
                        do {
                            for try await _ in self.frames(for: request) { }
                        } catch { }
                    }
                }
            }
        }
        return PrefetchToken(task: task)
    }

    func invalidate(accountNamespace: UUID, assetID: UUID) async {
        cache.removeAllObjects()
    }

    func clearMemory() async { cache.removeAllObjects() }
    func clearDisk(accountNamespace: UUID) async throws { }
    func clearAllDisk() async throws { }

    private func quality(for request: MediaRequest) -> MediaQuality {
        switch request.purpose {
        case .timeline: .preview
        case .viewer: .fullsize
        case .zoom: request.variant == .original ? .originalDownsample : .fullsize
        }
    }

    private func makeSurface(
        assetID: UUID,
        variant: AssetVariant,
        pixelSize: Int
    ) async throws -> RenderSurface {
        try await withCheckedThrowingContinuation { continuation in
            renderQueue.async {
                do {
                    continuation.resume(
                        returning: try Self.renderSurface(
                            assetID: assetID,
                            variant: variant,
                            pixelSize: pixelSize
                        )
                    )
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func renderSurface(
        assetID: UUID,
        variant: AssetVariant,
        pixelSize: Int
    ) throws -> RenderSurface {
        let size = max(32, min(pixelSize, 1_024))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw MediaError.corruptMedia }
        let bytes = withUnsafeBytes(of: assetID.uuid) { Array($0) }
        let offset: CGFloat = variant == .original ? 0.10 : 0
        let red = min(CGFloat(bytes[0]) / 255 + offset, 1)
        let green = min(CGFloat(bytes[5]) / 255 + offset, 1)
        let blue = min(CGFloat(bytes[10]) / 255 + offset, 1)
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.22)
        let inset = CGFloat(size) * 0.18
        context.fillEllipse(in: CGRect(x: inset, y: inset, width: CGFloat(size) - 2 * inset, height: CGFloat(size) - 2 * inset))
        guard let image = context.makeImage() else { throw MediaError.corruptMedia }
        return RenderSurface(cgImage: image)
    }
}

private final class FixtureRenderKey: NSObject {
    let assetID: UUID
    let variant: AssetVariant
    let pixelSize: Int

    init(request: MediaRequest) {
        assetID = request.asset.id
        variant = request.variant
        pixelSize = PixelBucket.normalized(for: request.requiredPixels, purpose: request.purpose)
    }

    override var hash: Int { assetID.hashValue ^ variant.hashValue ^ pixelSize.hashValue }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? FixtureRenderKey else { return false }
        return assetID == other.assetID && variant == other.variant && pixelSize == other.pixelSize
    }
}
