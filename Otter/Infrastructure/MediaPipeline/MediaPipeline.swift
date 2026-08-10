import Foundation

protocol ServerMediaProfileProviding: Sendable {
    func profile(accountNamespace: UUID) async -> ServerMediaProfile
    func record(
        _ observation: RepresentationObservation,
        for representation: RemoteRepresentation,
        accountNamespace: UUID
    ) async
}

actor InMemoryServerMediaProfileStore: ServerMediaProfileProviding {
    private var profiles: [UUID: ServerMediaProfile]

    init(profiles: [UUID: ServerMediaProfile] = [:]) {
        self.profiles = profiles
    }

    func profile(accountNamespace: UUID) -> ServerMediaProfile {
        profiles[accountNamespace] ?? .init()
    }

    func record(
        _ observation: RepresentationObservation,
        for representation: RemoteRepresentation,
        accountNamespace: UUID
    ) {
        var profile = profiles[accountNamespace] ?? .init()
        switch representation {
        case .thumbnail: profile.thumbnail = observation
        case .preview: profile.preview = observation
        case .fullsize: profile.fullsize = observation
        case .original: break
        }
        profiles[accountNamespace] = profile
    }
}

struct CompleteMediaPipelineStats: Sendable {
    let pipeline: MediaPipelineStats
    let memory: RenderMemoryCacheStats
    let disk: ByteDiskCacheStats
    let inFlightByteRequests: Int
    let inFlightRenderRequests: Int
    let scheduler: WorkSchedulerStats
}

protocol MediaPipelineProtocol: Sendable {
    func peek(_ request: MediaRequest) -> MediaFrame?
    func frames(for request: MediaRequest) -> AsyncThrowingStream<MediaFrame, Error>
    func prefetch(_ requests: [MediaRequest]) -> PrefetchToken
    func invalidate(accountNamespace: UUID, assetID: UUID) async
    func clearMemory() async
    func clearDisk(accountNamespace: UUID) async throws
    func clearAllDisk() async throws
}

final class MediaPipeline: MediaPipelineProtocol, @unchecked Sendable {
    private let planner: RepresentationPlanner
    private let profileStore: any ServerMediaProfileProviding
    private let memoryCache: RenderMemoryCache
    private let diskCache: ByteDiskCache
    private let coordinator: RequestCoordinator
    private let scheduler: WorkScheduler
    private let requestBuilder: any MediaRequestBuilding
    private let transport: any MediaTransporting
    private let decoder: any MediaDecoding
    private let thumbHashDecoder: ThumbHashDecoder
    private let negativeCache: NegativeMediaCache
    private let retryPolicy: MediaRetryPolicy
    private let metrics: MediaMetrics
    private let fileManager: FileManager
    private let onAuthenticationInvalid: @Sendable () -> Void

    init(
        planner: RepresentationPlanner = .init(),
        profileStore: any ServerMediaProfileProviding,
        memoryCache: RenderMemoryCache,
        diskCache: ByteDiskCache,
        coordinator: RequestCoordinator,
        scheduler: WorkScheduler,
        requestBuilder: any MediaRequestBuilding,
        transport: any MediaTransporting,
        decoder: any MediaDecoding = ImageIODecoder(),
        thumbHashDecoder: ThumbHashDecoder = .init(),
        negativeCache: NegativeMediaCache = .init(),
        retryPolicy: MediaRetryPolicy = .init(),
        metrics: MediaMetrics = .init(),
        fileManager: FileManager = .default,
        onAuthenticationInvalid: @escaping @Sendable () -> Void = { }
    ) {
        self.planner = planner
        self.profileStore = profileStore
        self.memoryCache = memoryCache
        self.diskCache = diskCache
        self.coordinator = coordinator
        self.scheduler = scheduler
        self.requestBuilder = requestBuilder
        self.transport = transport
        self.decoder = decoder
        self.thumbHashDecoder = thumbHashDecoder
        self.negativeCache = negativeCache
        self.retryPolicy = retryPolicy
        self.metrics = metrics
        self.fileManager = fileManager
        self.onAuthenticationInvalid = onAuthenticationInvalid
    }

    func peek(_ request: MediaRequest) -> MediaFrame? {
        let bucket = PixelBucket.normalized(for: request.requiredPixels, purpose: request.purpose)
        let spec = RenderSpecification(
            pixelBucket: bucket,
            dynamicRange: request.dynamicRange,
            contentMode: request.contentMode
        )
        let representations: [RemoteRepresentation]
        if request.variant == .original {
            representations = request.purpose == .timeline ? [] : [.original]
        } else {
            switch request.purpose {
            case .timeline: representations = [.preview, .thumbnail]
            case .viewer, .zoom: representations = [.fullsize, .preview]
            }
        }
        for representation in representations {
            guard let byteKey = try? ByteCacheKey(
                asset: request.asset,
                variant: request.variant,
                representation: representation
            ) else { continue }
            let renderKey = RenderCacheKey(byteKey: byteKey, specification: spec, transformVersion: 1)
            if let surface = memoryCache.value(for: renderKey) {
                return MediaFrame(
                    surface: surface,
                    quality: quality(for: representation),
                    source: .memoryCache,
                    isFinalForCurrentDemand: true
                )
            }
        }
        return nil
    }

    func frames(for request: MediaRequest) -> AsyncThrowingStream<MediaFrame, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    try await self.produceFrames(for: request, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    await self.metrics.emit(.requestCancelled, priority: request.priority)
                    continuation.finish()
                } catch {
                    if let mediaError = error as? MediaError,
                       case .httpStatus(401, _) = mediaError {
                        self.onAuthenticationInvalid()
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in producer.cancel() }
        }
    }

    func prefetch(_ requests: [MediaRequest]) -> PrefetchToken {
        let task = Task {
            await withTaskGroup(of: Void.self) { group in
                for request in requests {
                    group.addTask {
                        do {
                            for try await _ in self.frames(for: request) {
                                if Task.isCancelled { break }
                            }
                        } catch { }
                    }
                }
            }
        }
        return PrefetchToken(task: task)
    }

    func invalidate(accountNamespace: UUID, assetID: UUID) async {
        memoryCache.invalidate(accountNamespace: accountNamespace, assetID: assetID)
        await coordinator.invalidate(accountNamespace: accountNamespace, assetID: assetID)
        await negativeCache.remove(accountNamespace: accountNamespace, assetID: assetID)
        try? await diskCache.remove(accountNamespace: accountNamespace, assetID: assetID)
    }

    func clearMemory() async { memoryCache.removeAll() }

    func handleMemoryPressure() async { memoryCache.removeAll(keepingPinned: true) }

    func clearDisk(accountNamespace: UUID) async throws {
        await coordinator.invalidate(accountNamespace: accountNamespace)
        await Task.yield()
        try await diskCache.clear(accountNamespace: accountNamespace)
    }

    func clearAllDisk() async throws { try await diskCache.clearAll() }

    func stats() async throws -> CompleteMediaPipelineStats {
        let pipelineStats = await metrics.stats()
        let diskStats = try await diskCache.stats()
        let coordinatorStats = await coordinator.stats()
        let schedulerStats = await scheduler.stats()
        return .init(
            pipeline: pipelineStats,
            memory: memoryCache.stats(),
            disk: diskStats,
            inFlightByteRequests: coordinatorStats.byteRequests,
            inFlightRenderRequests: coordinatorStats.renderRequests,
            scheduler: schedulerStats
        )
    }

    private func produceFrames(
        for request: MediaRequest,
        continuation: AsyncThrowingStream<MediaFrame, Error>.Continuation
    ) async throws {
        let profile = await profileStore.profile(accountNamespace: request.asset.accountNamespace)
        let plan = try planner.plan(for: request, profile: profile)
        await metrics.emit(.requestCreated, priority: request.priority)
        var bestFrame: MediaFrame?
        var lastRecoverableError: Error?

        if request.variant == .current, let hash = request.asset.thumbhash {
            if let placeholder = try? await scheduler.run(
                lane: .thumbHash,
                priority: .speculative,
                operation: { try self.thumbHashDecoder.decode(base64: hash) }
            ) {
                let frame = MediaFrame(
                    surface: placeholder,
                    quality: .placeholder,
                    source: .generatedPlaceholder,
                    isFinalForCurrentDemand: false
                )
                if case .terminated = continuation.yield(frame) { return }
                bestFrame = frame
                await metrics.emit(.firstFrameDelivered, priority: request.priority)
            }
        }

        for (index, step) in plan.enumerated() {
            try Task.checkCancellation()
            let candidate: MediaFrame
            do {
                candidate = try await frame(for: step, request: request, allowCorruptRecovery: true)
            } catch let error as MediaError where Self.isRepresentationLocal(error) {
                lastRecoverableError = error
                continue
            }
            guard bestFrame == nil || bestFrame!.quality < candidate.quality else { continue }
            let delivered = MediaFrame(
                surface: candidate.surface,
                quality: candidate.quality,
                source: candidate.source,
                isFinalForCurrentDemand: index == plan.indices.last
            )
            if case .terminated = continuation.yield(delivered) { return }
            if bestFrame == nil { await metrics.emit(.firstFrameDelivered, priority: request.priority) }
            bestFrame = delivered
            if delivered.isFinalForCurrentDemand {
                await metrics.emit(.finalFrameDelivered, priority: request.priority)
            }
        }
        if let bestFrame, !bestFrame.isFinalForCurrentDemand {
            let final = MediaFrame(
                surface: bestFrame.surface,
                quality: bestFrame.quality,
                source: bestFrame.source,
                isFinalForCurrentDemand: true
            )
            if case .terminated = continuation.yield(final) { return }
            await metrics.emit(.finalFrameDelivered, priority: request.priority)
        } else if bestFrame == nil, let lastRecoverableError {
            throw lastRecoverableError
        }
    }

    private static func isRepresentationLocal(_ error: MediaError) -> Bool {
        switch error {
        case .unavailableRepresentation, .corruptMedia, .cacheEntryMissing, .httpStatus(404, _):
            true
        default:
            false
        }
    }

    private func frame(
        for step: RepresentationPlanStep,
        request: MediaRequest,
        allowCorruptRecovery: Bool
    ) async throws -> MediaFrame {
        let byteKey = try ByteCacheKey(
            asset: request.asset,
            variant: request.variant,
            representation: step.representation
        )
        let renderKey = RenderCacheKey(
            byteKey: byteKey,
            specification: step.renderSpecification,
            transformVersion: 1
        )

        if let cached = memoryCache.value(for: renderKey) {
            await metrics.emit(.memoryLookup, key: byteKey, priority: request.priority)
            return .init(surface: cached, quality: step.quality, source: .memoryCache, isFinalForCurrentDemand: false)
        }

        if await negativeCache.contains(byteKey) {
            throw MediaError.unavailableRepresentation(step.representation)
        }

        let diskHit = try await diskCache.file(for: byteKey)
        if diskHit != nil {
            await metrics.emit(.diskLookup, key: byteKey, priority: request.priority)
        }
        do {
            let bytes = if let diskHit {
                diskHit
            } else {
                try await fetchBytes(for: byteKey, asset: request.asset, priority: request.priority)
            }
            let surface = try await render(
                bytes: bytes,
                renderKey: renderKey,
                priority: request.priority
            )
            return .init(
                surface: surface,
                quality: step.quality,
                source: diskHit == nil ? .network : .diskCache,
                isFinalForCurrentDemand: false
            )
        } catch let error as MediaError
            where allowCorruptRecovery && diskHit != nil
                && (error == .corruptMedia || error == .cacheEntryMissing) {
            try await diskCache.remove(byteKey)
            return try await frame(for: step, request: request, allowCorruptRecovery: false)
        }
    }

    private func fetchBytes(
        for key: ByteCacheKey,
        asset: MediaAssetDescriptor,
        priority: MediaPriority
    ) async throws -> CachedByteFile {
        let lease = await coordinator.leaseBytes(for: key, priority: priority) { workID in
            if let cached = try await self.diskCache.file(for: key) { return cached }
            let request = try self.requestBuilder.urlRequest(
                for: asset,
                variant: key.variant,
                representation: key.representation
            )
            var attempt = 0
            while true {
                try Task.checkCancellation()
                do {
                    var effectivePriority = await self.coordinator.effectiveBytePriority(for: key) ?? priority
                    await self.metrics.emit(.networkStart, key: key, priority: effectivePriority)
                    await self.metrics.emit(.queueWait, key: key, priority: effectivePriority)
                    let downloaded = try await self.scheduler.run(
                        id: workID,
                        lane: self.lane(for: key.representation),
                        priority: effectivePriority,
                        operation: { try await self.transport.download(request) }
                    )
                    defer { try? self.fileManager.removeItem(at: downloaded.fileURL) }
                    try Task.checkCancellation()
                    effectivePriority = await self.coordinator.effectiveBytePriority(for: key) ?? effectivePriority
                    let properties = try await self.scheduler.run(
                        id: workID,
                        lane: .decode,
                        priority: effectivePriority,
                        operation: { try await self.decoder.inspect(fileURL: downloaded.fileURL, mimeType: downloaded.mimeType) }
                    )
                    try Task.checkCancellation()
                    effectivePriority = await self.coordinator.effectiveBytePriority(for: key) ?? effectivePriority
                    let observation = RepresentationObservation(
                        mimeType: properties.mimeType ?? "application/octet-stream",
                        maximumObservedDimension: max(properties.pixelWidth, properties.pixelHeight),
                        byteCount: downloaded.byteCount.map(Int.init),
                        redirectsCrossOrigin: false
                    )
                    await self.profileStore.record(
                        observation,
                        for: key.representation,
                        accountNamespace: key.accountNamespace
                    )
                    let cached = try await self.scheduler.run(
                        id: workID,
                        lane: .diskIO,
                        priority: effectivePriority,
                        operation: {
                            try await self.diskCache.storeDownloadedFile(
                                at: downloaded.fileURL,
                                for: key,
                                mimeType: properties.mimeType,
                                pixelWidth: properties.pixelWidth,
                                pixelHeight: properties.pixelHeight
                            )
                        }
                    )
                    await self.metrics.emit(.diskCommit, key: key, priority: effectivePriority, byteCount: cached.byteCount)
                    await self.metrics.emit(.networkEnd, key: key, priority: effectivePriority, byteCount: cached.byteCount)
                    return cached
                } catch {
                    if let mediaError = error as? MediaError,
                       case .httpStatus(404, _) = mediaError {
                        await self.negativeCache.insert(key, ttl: self.retryPolicy.negativeCacheTTL)
                    }
                    guard let delay = self.retryPolicy.delay(for: error, attempt: attempt, priority: priority) else {
                        throw error
                    }
                    attempt += 1
                    try await Task.sleep(for: .seconds(delay))
                }
            }
        }
        defer { lease.release() }
        return try await lease.value()
    }

    private func render(
        bytes: CachedByteFile,
        renderKey: RenderCacheKey,
        priority: MediaPriority
    ) async throws -> RenderSurface {
        if let cached = memoryCache.value(for: renderKey) { return cached }
        let lease = await coordinator.leaseRender(for: renderKey, priority: priority) { workID in
            guard let fileLease = try await self.diskCache.acquireFile(for: bytes.key) else {
                throw MediaError.cacheEntryMissing
            }
            defer { fileLease.release() }
            let surface = try await self.scheduler.run(
                id: workID,
                lane: .decode,
                priority: priority,
                operation: {
                    await self.metrics.emit(.decodeStart, key: bytes.key, priority: priority)
                    return try await self.decoder.decode(
                        fileURL: fileLease.file.fileURL,
                        maxPixelSize: renderKey.specification.pixelBucket
                    )
                }
            )
            await self.metrics.emit(.decodeEnd, key: bytes.key, priority: priority)
            self.memoryCache.insert(surface, for: renderKey)
            try? await self.diskCache.trimIfNeeded()
            return surface
        }
        defer { lease.release() }
        return try await lease.value()
    }

    private func lane(for representation: RemoteRepresentation) -> WorkLane {
        switch representation {
        case .thumbnail: .thumbnail
        case .preview: .preview
        case .fullsize, .original: .fullsize
        }
    }

    private func quality(for representation: RemoteRepresentation) -> MediaQuality {
        switch representation {
        case .thumbnail: .thumbnail
        case .preview: .preview
        case .fullsize: .fullsize
        case .original: .originalDownsample
        }
    }
}
