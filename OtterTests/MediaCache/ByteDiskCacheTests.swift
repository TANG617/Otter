import Foundation
import Testing
@testable import Otter

private actor StoreCommitBarrier {
    private let entered = AsyncTestGate()
    private let release = AsyncTestGate()
    private var shouldBlock = true

    func pauseFirstCommit() async {
        guard shouldBlock else { return }
        shouldBlock = false
        await entered.open()
        await release.wait()
    }

    func waitUntilEntered() async { await entered.wait() }
    func releaseCommit() async { await release.open() }
}

private struct CacheRaceRequestBuilder: MediaRequestBuilding {
    func urlRequest(
        for asset: MediaAssetDescriptor,
        variant: AssetVariant,
        representation: RemoteRepresentation
    ) throws -> URLRequest {
        URLRequest(url: URL(string: "https://fixture.invalid/\(representation.rawValue)")!)
    }
}

private actor CacheRaceTransport: MediaTransporting {
    private let source: URL
    private let directory: URL
    private var requestCount = 0

    init(source: URL, directory: URL) {
        self.source = source
        self.directory = directory
    }

    func download(_ request: URLRequest) throws -> TransportedMediaFile {
        requestCount += 1
        let destination = directory.appendingPathComponent("\(UUID().uuidString).jpg")
        try FileManager.default.copyItem(at: source, to: destination)
        let size = ((try FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)?.int64Value
        return TransportedMediaFile(
            fileURL: destination,
            mimeType: "image/jpeg",
            byteCount: size,
            statusCode: 200
        )
    }

    func count() -> Int { requestCount }
}

@Suite("Byte disk cache")
struct ByteDiskCacheTests {
    @Test("Stores atomically and preserves account isolation")
    func atomicStoreAndAccountIsolation() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeBytes(count: 64, to: root, name: "source")
        let cache = try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache"), byteLimit: 1_024)
        let asset = UUID()
        let accountA = UUID()
        let accountB = UUID()
        let keyA = try mediaTestKey(account: accountA, asset: asset)
        let keyB = try mediaTestKey(account: accountB, asset: asset)

        let stored = try await cache.storeDownloadedFile(at: source, for: keyA, mimeType: "image/jpeg")
        #expect(FileManager.default.fileExists(atPath: stored.fileURL.path))
        #expect(try await cache.file(for: keyA) != nil)
        #expect(try await cache.file(for: keyB) == nil)
    }

    @Test("Corrupt length removes entry")
    func corruption() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeBytes(count: 64, to: root, name: "source")
        let cache = try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache"), byteLimit: 1_024)
        let key = try mediaTestKey()
        let stored = try await cache.storeDownloadedFile(at: source, for: key)
        try Data([1, 2]).write(to: stored.fileURL)

        #expect(try await cache.file(for: key) == nil)
        #expect(try await cache.stats().entryCount == 0)
    }

    @Test("Evicts to the lower watermark")
    func lowerWatermark() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeBytes(count: 60, to: root, name: "first")
        let second = try writeBytes(count: 60, to: root, name: "second")
        let cache = try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache"), byteLimit: 100)

        try await cache.storeDownloadedFile(at: first, for: mediaTestKey(asset: UUID()))
        try await cache.storeDownloadedFile(at: second, for: mediaTestKey(asset: UUID()))
        let stats = try await cache.stats()
        #expect(stats.byteCount <= 80)
        #expect(stats.entryCount == 1)
    }

    @Test("Active lease protects a file from eviction")
    func leaseProtection() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try writeBytes(count: 60, to: root, name: "first")
        let second = try writeBytes(count: 60, to: root, name: "second")
        let cache = try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache"), byteLimit: 100)
        let protectedKey = try mediaTestKey(asset: UUID())
        try await cache.storeDownloadedFile(at: first, for: protectedKey)
        let lease = try #require(try await cache.acquireFile(for: protectedKey))
        try await cache.storeDownloadedFile(at: second, for: mediaTestKey(asset: UUID()))

        #expect(FileManager.default.fileExists(atPath: lease.file.fileURL.path))
        #expect(try await cache.file(for: protectedKey) != nil)
        lease.release()
    }

    @Test("Clear account does not clear another account")
    func clearAccount() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeBytes(count: 20, to: root)
        let cache = try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache"), byteLimit: 1_024)
        let a = UUID()
        let b = UUID()
        let keyA = try mediaTestKey(account: a)
        let keyB = try mediaTestKey(account: b)
        try await cache.storeDownloadedFile(at: source, for: keyA)
        try await cache.storeDownloadedFile(at: source, for: keyB)

        try await cache.clear(accountNamespace: a)
        #expect(try await cache.file(for: keyA) == nil)
        #expect(try await cache.file(for: keyB) != nil)
    }

    @Test("Clear removes a leased entry when its final lease is released")
    func clearDefersLeasedEntryDeletion() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try writeBytes(count: 20, to: root)
        let cache = try ByteDiskCache(rootDirectory: root.appendingPathComponent("cache"), byteLimit: 1_024)
        let account = UUID()
        let key = try mediaTestKey(account: account)
        try await cache.storeDownloadedFile(at: source, for: key)
        let lease = try #require(try await cache.acquireFile(for: key))

        try await cache.clear(accountNamespace: account)
        #expect(FileManager.default.fileExists(atPath: lease.file.fileURL.path))
        lease.release()
        for _ in 0..<8 { await Task.yield() }

        #expect(!FileManager.default.fileExists(atPath: lease.file.fileURL.path))
        #expect(try await cache.file(for: key) == nil)
    }

    @Test("Account clear waits for old cache commits and permits a new generation")
    func accountClearIsQuiescent() async throws {
        let root = try temporaryTestDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        try makeTestJPEG(width: 320, height: 240, at: source)
        let account = UUID()
        let descriptor = MediaAssetDescriptor(
            accountNamespace: account,
            id: UUID(),
            revisions: .init(thumbnail: "t", preview: "p", fullsize: "f", original: "o"),
            originalWidth: 320,
            originalHeight: 240,
            originalMimeType: "image/jpeg"
        )
        let request = MediaRequest(
            asset: descriptor,
            purpose: .timeline,
            viewport: .init(width: 100, height: 100),
            displayScale: 2,
            priority: .visible
        )
        let commitBarrier = StoreCommitBarrier()
        let cacheRoot = root.appendingPathComponent("cache")
        let cache = try ByteDiskCache(
            rootDirectory: cacheRoot,
            byteLimit: 1_024 * 1_024,
            testHooks: .init(beforeIndexCommit: { _ in
                await commitBarrier.pauseFirstCommit()
            })
        )
        let scheduler = WorkScheduler()
        let coordinator = RequestCoordinator(scheduler: scheduler)
        let transport = CacheRaceTransport(source: source, directory: root)
        let profile = ServerMediaProfile(
            thumbnail: .init(
                mimeType: "image/jpeg",
                maximumObservedDimension: 4_096,
                byteCount: nil,
                redirectsCrossOrigin: false
            )
        )
        let pipeline = MediaPipeline(
            profileStore: InMemoryServerMediaProfileStore(profiles: [account: profile]),
            memoryCache: RenderMemoryCache(),
            diskCache: cache,
            coordinator: coordinator,
            scheduler: scheduler,
            requestBuilder: CacheRaceRequestBuilder(),
            transport: transport
        )

        let oldRequest = Task {
            do {
                for try await _ in pipeline.frames(for: request) { }
            } catch { }
        }
        await commitBarrier.waitUntilEntered()

        let clear = Task { try await pipeline.clearDisk(accountNamespace: account) }
        #expect(await waitForTestCondition {
            (await coordinator.stats()).byteRequests == 0
        })
        await commitBarrier.releaseCommit()
        try await clear.value
        await oldRequest.value

        let cleared = try await cache.stats()
        #expect(cleared.entryCount == 0)
        #expect(cleared.byteCount == 0)
        #expect(mediaPayloadFiles(in: cacheRoot).isEmpty)

        var newFrames: [MediaFrame] = []
        for try await frame in pipeline.frames(for: request) {
            newFrames.append(frame)
        }
        let repopulated = try await cache.stats()
        #expect(newFrames.last?.quality == .thumbnail)
        #expect(newFrames.last?.isFinalForCurrentDemand == true)
        #expect(repopulated.entryCount == 1)
        #expect(repopulated.byteCount > 0)
        #expect(mediaPayloadFiles(in: cacheRoot).count == 1)
        #expect(await transport.count() == 2)
    }
}

private func mediaPayloadFiles(in root: URL) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter {
        $0.pathExtension == "media" || $0.pathExtension == "tmp"
    }
}
