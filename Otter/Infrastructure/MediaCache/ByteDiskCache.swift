import Foundation
import GRDB

struct ByteDiskCacheStats: Equatable, Sendable {
    let entryCount: Int
    let byteCount: Int64
    let byteLimit: Int64
    let activeLeaseCount: Int
}

struct CachedByteFile: Sendable {
    let key: ByteCacheKey
    let fileURL: URL
    let byteCount: Int64
    let mimeType: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

final class ByteCacheFileLease: @unchecked Sendable {
    let file: CachedByteFile

    private let lock = NSLock()
    private var releaseAction: (@Sendable () -> Void)?

    init(file: CachedByteFile, releaseAction: @escaping @Sendable () -> Void) {
        self.file = file
        self.releaseAction = releaseAction
    }

    func release() {
        let action = lock.withLock { () -> (@Sendable () -> Void)? in
            defer { releaseAction = nil }
            return releaseAction
        }
        action?()
    }

    deinit { release() }
}

actor ByteDiskCache {
    static let defaultByteLimit: Int64 = 2 * 1_024 * 1_024 * 1_024

    private let rootDirectory: URL
    private let database: DatabaseQueue
    private let fileManager: FileManager
    private var byteLimit: Int64
    private var pendingTouches: Set<String> = []
    private var activeLeases: [String: Int] = [:]

    init(
        rootDirectory: URL,
        byteLimit: Int64 = ByteDiskCache.defaultByteLimit,
        fileManager: FileManager = .default
    ) throws {
        self.rootDirectory = rootDirectory
        self.byteLimit = max(byteLimit, 0)
        self.fileManager = fileManager
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        database = try DatabaseQueue(path: rootDirectory.appendingPathComponent("cache.sqlite").path)
        try Self.migrate(database)
        try Self.removeOrphanedTempFiles(in: rootDirectory, fileManager: fileManager)
    }

    func file(for key: ByteCacheKey) async throws -> CachedByteFile? {
        guard let entry = try fetchEntry(key.digest) else { return nil }
        let url = rootDirectory.appendingPathComponent(entry.filePath)
        guard fileManager.fileExists(atPath: url.path) else {
            try deleteIndexEntry(key.digest)
            return nil
        }
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let actualSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        guard actualSize == entry.byteCount else {
            try remove(key)
            return nil
        }
        pendingTouches.insert(key.digest)
        return entry.asCachedFile(key: key, root: rootDirectory)
    }

    func acquireFile(for key: ByteCacheKey) async throws -> ByteCacheFileLease? {
        guard let cached = try await file(for: key) else { return nil }
        activeLeases[key.digest, default: 0] += 1
        return ByteCacheFileLease(file: cached) { [weak self] in
            Task { await self?.releaseLease(digest: key.digest) }
        }
    }

    @discardableResult
    func storeDownloadedFile(
        at sourceURL: URL,
        for key: ByteCacheKey,
        mimeType: String? = nil,
        pixelWidth: Int? = nil,
        pixelHeight: Int? = nil
    ) async throws -> CachedByteFile {
        let attributes = try fileManager.attributesOfItem(atPath: sourceURL.path)
        guard let number = attributes[.size] as? NSNumber, number.int64Value > 0 else {
            throw MediaError.corruptMedia
        }
        let byteCount = number.int64Value
        let relativePath = relativeFilePath(for: key)
        let destination = rootDirectory.appendingPathComponent(relativePath)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: destination.path) {
            let staging = directory.appendingPathComponent(".\(key.digest).\(UUID().uuidString).tmp")
            do {
                try fileManager.copyItem(at: sourceURL, to: staging)
                try fileManager.moveItem(at: staging, to: destination)
            } catch {
                try? fileManager.removeItem(at: staging)
                throw error
            }
        }

        let now = Date().timeIntervalSince1970
        try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_cache_entry
                    (cache_key, account_namespace, asset_id, variant, representation, file_path,
                     byte_count, content_type, pixel_width, pixel_height, created_at, last_access_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(cache_key) DO UPDATE SET
                    file_path = excluded.file_path,
                    byte_count = excluded.byte_count,
                    content_type = excluded.content_type,
                    pixel_width = excluded.pixel_width,
                    pixel_height = excluded.pixel_height,
                    last_access_at = excluded.last_access_at
                """,
                arguments: [
                    key.digest,
                    key.accountNamespace.uuidString.lowercased(),
                    key.assetID.uuidString.lowercased(),
                    key.variant.rawValue,
                    key.representation.rawValue,
                    relativePath,
                    byteCount,
                    mimeType,
                    pixelWidth,
                    pixelHeight,
                    now,
                    now,
                ]
            )
        }
        activeLeases[key.digest, default: 0] += 1
        defer { releaseLease(digest: key.digest) }
        try await evictIfNeeded()
        return CachedByteFile(
            key: key,
            fileURL: destination,
            byteCount: byteCount,
            mimeType: mimeType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }

    func remove(_ key: ByteCacheKey) throws {
        guard activeLeases[key.digest, default: 0] == 0 else { return }
        if let entry = try fetchEntry(key.digest) {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(entry.filePath))
        }
        try deleteIndexEntry(key.digest)
        pendingTouches.remove(key.digest)
    }

    func clear(accountNamespace: UUID) async throws {
        try flushTouches()
        let account = accountNamespace.uuidString.lowercased()
        let entries = try await database.read { db in
            try CacheEntry.fetchAll(
                db,
                sql: "SELECT * FROM media_cache_entry WHERE account_namespace = ?",
                arguments: [account]
            )
        }
        for entry in entries where activeLeases[entry.cacheKey, default: 0] == 0 {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(entry.filePath))
            try deleteIndexEntry(entry.cacheKey)
        }
    }

    func remove(accountNamespace: UUID, assetID: UUID) async throws {
        try flushTouches()
        let account = accountNamespace.uuidString.lowercased()
        let asset = assetID.uuidString.lowercased()
        let entries = try await database.read { db in
            try CacheEntry.fetchAll(
                db,
                sql: """
                SELECT * FROM media_cache_entry
                WHERE account_namespace = ? AND asset_id = ?
                """,
                arguments: [account, asset]
            )
        }
        for entry in entries where activeLeases[entry.cacheKey, default: 0] == 0 {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(entry.filePath))
            try deleteIndexEntry(entry.cacheKey)
        }
    }

    func clearAll() async throws {
        try flushTouches()
        let entries = try allEntriesByAccess()
        for entry in entries where activeLeases[entry.cacheKey, default: 0] == 0 {
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(entry.filePath))
            try deleteIndexEntry(entry.cacheKey)
        }
    }

    func setByteLimit(_ value: Int64) async throws {
        byteLimit = max(value, 0)
        try await evictIfNeeded()
    }

    func trimIfNeeded() async throws { try await evictIfNeeded() }

    func flushTouches() throws {
        guard !pendingTouches.isEmpty else { return }
        let touched = pendingTouches
        pendingTouches.removeAll(keepingCapacity: true)
        let now = Date().timeIntervalSince1970
        try database.write { db in
            for digest in touched {
                try db.execute(
                    sql: "UPDATE media_cache_entry SET last_access_at = ? WHERE cache_key = ?",
                    arguments: [now, digest]
                )
            }
        }
    }

    func stats() async throws -> ByteDiskCacheStats {
        try flushTouches()
        let summary = try await database.read { db -> (Int, Int64) in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT COUNT(*) AS count, COALESCE(SUM(byte_count), 0) AS bytes FROM media_cache_entry"
            )!
            return (row["count"], row["bytes"])
        }
        return .init(
            entryCount: summary.0,
            byteCount: summary.1,
            byteLimit: byteLimit,
            activeLeaseCount: activeLeases.values.reduce(0, +)
        )
    }

    private func releaseLease(digest: String) {
        guard let count = activeLeases[digest] else { return }
        if count <= 1 { activeLeases.removeValue(forKey: digest) }
        else { activeLeases[digest] = count - 1 }
    }

    private func evictIfNeeded() async throws {
        try flushTouches()
        var current = try totalBytes()
        guard current > byteLimit else { return }
        let target = Int64(Double(byteLimit) * 0.8)
        for entry in try allEntriesByAccess() {
            guard current > target else { break }
            guard activeLeases[entry.cacheKey, default: 0] == 0 else { continue }
            try? fileManager.removeItem(at: rootDirectory.appendingPathComponent(entry.filePath))
            try deleteIndexEntry(entry.cacheKey)
            current -= entry.byteCount
        }
    }

    private func fetchEntry(_ digest: String) throws -> CacheEntry? {
        try database.read { db in
            try CacheEntry.fetchOne(
                db,
                sql: "SELECT * FROM media_cache_entry WHERE cache_key = ?",
                arguments: [digest]
            )
        }
    }

    private func allEntriesByAccess() throws -> [CacheEntry] {
        try database.read { db in
            try CacheEntry.fetchAll(db, sql: "SELECT * FROM media_cache_entry ORDER BY last_access_at ASC")
        }
    }

    private func totalBytes() throws -> Int64 {
        try database.read { db in
            try Int64.fetchOne(db, sql: "SELECT COALESCE(SUM(byte_count), 0) FROM media_cache_entry") ?? 0
        }
    }

    private func deleteIndexEntry(_ digest: String) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM media_cache_entry WHERE cache_key = ?", arguments: [digest])
        }
    }

    private func relativeFilePath(for key: ByteCacheKey) -> String {
        let digest = key.digest
        return [
            key.accountNamespace.uuidString.lowercased(),
            key.variant.rawValue,
            key.representation.rawValue,
            String(digest.prefix(2)),
            String(digest.dropFirst(2).prefix(2)),
            "\(digest).media",
        ].joined(separator: "/")
    }

    private static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createMediaCache") { db in
            try db.create(table: "media_cache_entry") { table in
                table.column("cache_key", .text).primaryKey()
                table.column("account_namespace", .text).notNull().indexed()
                table.column("asset_id", .text).notNull().indexed()
                table.column("variant", .text).notNull()
                table.column("representation", .text).notNull()
                table.column("file_path", .text).notNull()
                table.column("byte_count", .integer).notNull()
                table.column("content_type", .text)
                table.column("pixel_width", .integer)
                table.column("pixel_height", .integer)
                table.column("created_at", .double).notNull()
                table.column("last_access_at", .double).notNull().indexed()
            }
        }
        try migrator.migrate(database)
    }

    private static func removeOrphanedTempFiles(in root: URL, fileManager: FileManager) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return }
        while let url = enumerator.nextObject() as? URL {
            if url.pathExtension == "tmp" { try? fileManager.removeItem(at: url) }
        }
    }
}

private struct CacheEntry: FetchableRecord {
    let cacheKey: String
    let accountNamespace: String
    let assetID: String
    let variant: String
    let representation: String
    let filePath: String
    let byteCount: Int64
    let contentType: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
    let createdAt: Double
    let lastAccessAt: Double

    init(row: Row) throws {
        cacheKey = row["cache_key"]
        accountNamespace = row["account_namespace"]
        assetID = row["asset_id"]
        variant = row["variant"]
        representation = row["representation"]
        filePath = row["file_path"]
        byteCount = row["byte_count"]
        contentType = row["content_type"]
        pixelWidth = row["pixel_width"]
        pixelHeight = row["pixel_height"]
        createdAt = row["created_at"]
        lastAccessAt = row["last_access_at"]
    }

    func asCachedFile(key: ByteCacheKey, root: URL) -> CachedByteFile {
        .init(
            key: key,
            fileURL: root.appendingPathComponent(filePath),
            byteCount: byteCount,
            mimeType: contentType,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
    }
}
