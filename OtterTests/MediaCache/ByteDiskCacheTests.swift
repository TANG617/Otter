import Foundation
import Testing
@testable import Otter

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
}
