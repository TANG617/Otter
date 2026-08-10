import Foundation

struct LiveAppRuntime: @unchecked Sendable {
    let account: Account
    let serverURL: NormalizedServerURL
    let capabilities: ServerCapabilities
    let client: ImmichClient
    let database: AssetDatabase
    let assetStore: LocalFirstAssetStore
    let ratingRepository: RatingRepository
    let diskCache: ByteDiskCache
    let mediaPipeline: MediaPipeline
    let exporter: AssetExporter
    let authenticationInvalidations: AsyncStream<Void>
}

final class AuthenticationInvalidationSource: @unchecked Sendable {
    let events: AsyncStream<Void>

    private let lock = NSLock()
    private let continuation: AsyncStream<Void>.Continuation

    init() {
        let pair = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        continuation = pair.continuation
    }

    func invalidate() {
        _ = lock.withLock { continuation.yield() }
    }

    deinit { continuation.finish() }
}

enum LiveAppRuntimeFactory {
    static func make(
        record: ActiveAccountRecord,
        apiKey: APIKey,
        fileManager: FileManager = .default
    ) throws -> LiveAppRuntime {
        let serverURL = try NormalizedServerURL(record.serverURL.absoluteString)
        let directories = try RuntimeDirectories(fileManager: fileManager)
        let database = try AssetDatabase(path: directories.metadataDatabase.path)
        let account = Account(
            namespace: record.namespace,
            serverURL: serverURL.url,
            userID: nil,
            serverVersion: record.serverVersion.description,
            createdAt: Date()
        )
        try database.saveAccount(account)

        let authenticationSource = AuthenticationInvalidationSource()
        let client = ImmichClient(
            accountNamespace: record.namespace,
            serverURL: serverURL,
            apiKey: apiKey,
            onAuthenticationInvalid: { authenticationSource.invalidate() }
        )
        let assetStore = LocalFirstAssetStore(database: database, remote: client)
        let ratingAvailability: RatingWriteAvailability = record.serverVersion.major == 3
            ? .unverified
            : .unavailable
        let ratingRepository = RatingRepository(
            database: database,
            remote: client,
            writeAvailability: ratingAvailability
        )

        let diskCache = try ByteDiskCache(
            rootDirectory: directories.mediaCache,
            byteLimit: record.cacheLimitBytes
        )
        let memoryCache = RenderMemoryCache()
        let scheduler = WorkScheduler()
        let coordinator = RequestCoordinator(scheduler: scheduler)
        let mediaRequestBuilder = ImmichMediaEndpointBuilder(serverURL: serverURL, apiKey: apiKey)
        let mediaTransport = try URLSessionMediaTransport(
            stagingDirectory: directories.mediaTransfers,
            onAuthenticationInvalid: { authenticationSource.invalidate() }
        )
        let profileStore = DatabaseServerMediaProfileStore(database: database)
        let mediaPipeline = MediaPipeline(
            profileStore: profileStore,
            memoryCache: memoryCache,
            diskCache: diskCache,
            coordinator: coordinator,
            scheduler: scheduler,
            requestBuilder: mediaRequestBuilder,
            transport: mediaTransport,
            onAuthenticationInvalid: { authenticationSource.invalidate() }
        )

        let exportConfiguration = URLSessionMediaTransport.mediaConfiguration()
        exportConfiguration.httpMaximumConnectionsPerHost = 1
        let exportTransport = try URLSessionMediaTransport(
            configuration: exportConfiguration,
            stagingDirectory: directories.exportTransfers,
            onAuthenticationInvalid: { authenticationSource.invalidate() }
        )
        let exporter = try AssetExporter(
            requestBuilder: mediaRequestBuilder,
            transport: exportTransport,
            exportDirectory: directories.preparedExports,
            currentExportAvailable: record.serverVersion.major == 3
        )

        return LiveAppRuntime(
            account: account,
            serverURL: serverURL,
            capabilities: ImmichCapabilityProbe.capabilities(for: record.serverVersion),
            client: client,
            database: database,
            assetStore: assetStore,
            ratingRepository: ratingRepository,
            diskCache: diskCache,
            mediaPipeline: mediaPipeline,
            exporter: exporter,
            authenticationInvalidations: authenticationSource.events
        )
    }
}

private struct RuntimeDirectories {
    let metadataDatabase: URL
    let mediaCache: URL
    let mediaTransfers: URL
    let exportTransfers: URL
    let preparedExports: URL

    init(fileManager: FileManager) throws {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Otter", isDirectory: true)
        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Otter", isDirectory: true)
        try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: caches, withIntermediateDirectories: true)

        metadataDatabase = applicationSupport.appendingPathComponent("metadata.sqlite")
        mediaCache = caches.appendingPathComponent("Media", isDirectory: true)
        mediaTransfers = caches.appendingPathComponent("MediaTransfers", isDirectory: true)
        exportTransfers = caches.appendingPathComponent("ExportTransfers", isDirectory: true)
        preparedExports = fileManager.temporaryDirectory
            .appendingPathComponent("OtterPreparedExports", isDirectory: true)
    }
}
