import Foundation
import GRDB

enum AssetDatabaseError: Error, Equatable {
    case wrongAccount
    case corruptRecord
}

final class AssetDatabase: @unchecked Sendable {
    private let database: DatabaseQueue

    init(path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        database = try DatabaseQueue(path: path, configuration: configuration)
        try Self.migrator.migrate(database)
    }

    private init(database: DatabaseQueue) throws {
        self.database = database
        try Self.migrator.migrate(database)
    }

    static func inMemory() throws -> AssetDatabase {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }
        return try AssetDatabase(database: DatabaseQueue(configuration: configuration))
    }

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1.metadata") { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    namespace TEXT PRIMARY KEY NOT NULL,
                    serverURL TEXT NOT NULL,
                    userID TEXT,
                    serverVersion TEXT,
                    createdAt DOUBLE NOT NULL
                );

                CREATE TABLE assets (
                    accountNamespace TEXT NOT NULL REFERENCES accounts(namespace) ON DELETE CASCADE,
                    id TEXT NOT NULL,
                    ownerID TEXT,
                    mediaType TEXT NOT NULL,
                    localDateTime DOUBLE,
                    fileCreatedAt DOUBLE,
                    createdAt DOUBLE NOT NULL,
                    updatedAt DOUBLE NOT NULL,
                    timelineDate DOUBLE NOT NULL,
                    width INTEGER,
                    height INTEGER,
                    thumbhash TEXT,
                    checksum TEXT,
                    originalFileName TEXT,
                    originalMimeType TEXT,
                    isFavorite INTEGER NOT NULL,
                    isEdited INTEGER NOT NULL,
                    isArchived INTEGER NOT NULL,
                    isTrashed INTEGER NOT NULL,
                    visibility TEXT,
                    rating INTEGER,
                    reconciliationGeneration INTEGER,
                    PRIMARY KEY (accountNamespace, id)
                ) WITHOUT ROWID;

                CREATE TABLE syncStates (
                    accountNamespace TEXT PRIMARY KEY NOT NULL REFERENCES accounts(namespace) ON DELETE CASCADE,
                    lastIncrementalRefreshAt DOUBLE,
                    lastFullReconciliationAt DOUBLE,
                    highestObservedUpdatedAt DOUBLE,
                    reconciliationGeneration INTEGER NOT NULL DEFAULT 0
                ) WITHOUT ROWID;

                CREATE TABLE serverMediaProfiles (
                    accountNamespace TEXT PRIMARY KEY NOT NULL REFERENCES accounts(namespace) ON DELETE CASCADE,
                    profileJSON BLOB NOT NULL
                ) WITHOUT ROWID;
                """)
        }
        migrator.registerMigration("v2.timeline-indexes") { db in
            try db.execute(sql: """
                CREATE INDEX assets_timeline_window
                ON assets(accountNamespace, timelineDate DESC, id DESC)
                WHERE mediaType = 'IMAGE' AND isArchived = 0 AND isTrashed = 0;

                CREATE INDEX assets_updated
                ON assets(accountNamespace, updatedAt DESC, id DESC);
                """)
        }
        return migrator
    }

    func saveAccount(_ account: Account) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO accounts(namespace, serverURL, userID, serverVersion, createdAt)
                    VALUES (:namespace, :serverURL, :userID, :serverVersion, :createdAt)
                    ON CONFLICT(namespace) DO UPDATE SET
                        serverURL = excluded.serverURL,
                        userID = excluded.userID,
                        serverVersion = excluded.serverVersion
                    """,
                arguments: [
                    "namespace": Self.id(account.namespace),
                    "serverURL": account.serverURL.absoluteString,
                    "userID": account.userID.map(Self.id),
                    "serverVersion": account.serverVersion,
                    "createdAt": account.createdAt.timeIntervalSince1970,
                ]
            )
            try db.execute(
                sql: "INSERT INTO syncStates(accountNamespace) VALUES (?) ON CONFLICT DO NOTHING",
                arguments: [Self.id(account.namespace)]
            )
        }
    }

    func account(namespace: UUID) throws -> Account? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM accounts WHERE namespace = ?",
                arguments: [Self.id(namespace)]
            ) else {
                return nil
            }
            guard let id = UUID(uuidString: row["namespace"]),
                  let url = URL(string: row["serverURL"]) else {
                throw AssetDatabaseError.corruptRecord
            }
            let userID: String? = row["userID"]
            let createdAt: Double = row["createdAt"]
            return Account(
                namespace: id,
                serverURL: url,
                userID: userID.flatMap(UUID.init(uuidString:)),
                serverVersion: row["serverVersion"],
                createdAt: Date(timeIntervalSince1970: createdAt)
            )
        }
    }

    func deleteAccount(namespace: UUID) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE namespace = ?", arguments: [Self.id(namespace)])
        }
    }

    @discardableResult
    func upsertAssets(
        _ assets: [TimelineAsset],
        accountNamespace: UUID,
        reconciliationGeneration: Int64? = nil
    ) throws -> Int {
        guard assets.allSatisfy({ $0.accountNamespace == accountNamespace }) else {
            throw AssetDatabaseError.wrongAccount
        }
        guard !assets.isEmpty else { return 0 }
        return try database.write { db in
            let statement = try db.cachedStatement(sql: """
                INSERT INTO assets(
                    accountNamespace, id, ownerID, mediaType,
                    localDateTime, fileCreatedAt, createdAt, updatedAt, timelineDate,
                    width, height, thumbhash, checksum, originalFileName, originalMimeType,
                    isFavorite, isEdited, isArchived, isTrashed, visibility, rating,
                    reconciliationGeneration
                ) VALUES (
                    :accountNamespace, :id, :ownerID, :mediaType,
                    :localDateTime, :fileCreatedAt, :createdAt, :updatedAt, :timelineDate,
                    :width, :height, :thumbhash, :checksum, :originalFileName, :originalMimeType,
                    :isFavorite, :isEdited, :isArchived, :isTrashed, :visibility, :rating,
                    :reconciliationGeneration
                )
                ON CONFLICT(accountNamespace, id) DO UPDATE SET
                    ownerID = excluded.ownerID,
                    mediaType = excluded.mediaType,
                    localDateTime = excluded.localDateTime,
                    fileCreatedAt = excluded.fileCreatedAt,
                    createdAt = excluded.createdAt,
                    updatedAt = excluded.updatedAt,
                    timelineDate = excluded.timelineDate,
                    width = excluded.width,
                    height = excluded.height,
                    thumbhash = excluded.thumbhash,
                    checksum = excluded.checksum,
                    originalFileName = excluded.originalFileName,
                    originalMimeType = excluded.originalMimeType,
                    isFavorite = excluded.isFavorite,
                    isEdited = excluded.isEdited,
                    isArchived = excluded.isArchived,
                    isTrashed = excluded.isTrashed,
                    visibility = excluded.visibility,
                    rating = excluded.rating,
                    reconciliationGeneration = COALESCE(
                        excluded.reconciliationGeneration,
                        assets.reconciliationGeneration
                    )
                """)
            for asset in assets {
                try statement.execute(arguments: Self.arguments(
                    for: asset,
                    reconciliationGeneration: reconciliationGeneration
                ))
            }
            return assets.count
        }
    }

    func asset(id: UUID, accountNamespace: UUID) throws -> TimelineAsset? {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM assets WHERE accountNamespace = ? AND id = ?",
                arguments: [Self.id(accountNamespace), Self.id(id)]
            ) else {
                return nil
            }
            return try Self.asset(from: row)
        }
    }

    func timelinePage(_ request: TimelinePageRequest) throws -> TimelineAssetPage {
        try database.read { db in
            var arguments: StatementArguments = [Self.id(request.accountNamespace)]
            var window = ""
            if let cursor = request.after {
                window = "AND (timelineDate < ? OR (timelineDate = ? AND id < ?))"
                arguments += [
                    cursor.date.timeIntervalSince1970,
                    cursor.date.timeIntervalSince1970,
                    Self.id(cursor.assetID),
                ]
            }
            arguments += [request.limit + 1]
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM assets
                    WHERE accountNamespace = ?
                      AND mediaType = 'IMAGE'
                      AND isArchived = 0
                      AND isTrashed = 0
                      AND (visibility IS NULL OR visibility = 'timeline')
                      \(window)
                    ORDER BY timelineDate DESC, id DESC
                    LIMIT ?
                    """,
                arguments: arguments
            )
            let hasMore = rows.count > request.limit
            let assets = try rows.prefix(request.limit).map(Self.asset(from:))
            let cursor = hasMore ? assets.last.map { TimelineCursor(date: $0.timelineDate, assetID: $0.id) } : nil
            return TimelineAssetPage(assets: assets, nextCursor: cursor)
        }
    }

    func updateRating(
        _ rating: AssetRating?,
        assetID: UUID,
        accountNamespace: UUID
    ) throws {
        try database.write { db in
            try db.execute(
                sql: "UPDATE assets SET rating = ? WHERE accountNamespace = ? AND id = ?",
                arguments: [rating?.rawValue, Self.id(accountNamespace), Self.id(assetID)]
            )
        }
    }

    func beginReconciliation(accountNamespace: UUID) throws -> Int64 {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO syncStates(accountNamespace, reconciliationGeneration)
                    VALUES (?, 1)
                    ON CONFLICT(accountNamespace) DO UPDATE SET
                        reconciliationGeneration = reconciliationGeneration + 1
                    """,
                arguments: [Self.id(accountNamespace)]
            )
            return try Int64.fetchOne(
                db,
                sql: "SELECT reconciliationGeneration FROM syncStates WHERE accountNamespace = ?",
                arguments: [Self.id(accountNamespace)]
            ) ?? 1
        }
    }

    func deleteAssetsNotSeen(accountNamespace: UUID, generation: Int64) throws -> Int {
        try database.write { db in
            try db.execute(
                sql: """
                    DELETE FROM assets
                    WHERE accountNamespace = ?
                      AND COALESCE(reconciliationGeneration, 0) != ?
                    """,
                arguments: [Self.id(accountNamespace), generation]
            )
            return db.changesCount
        }
    }

    func removeAllAssets(accountNamespace: UUID) throws {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM assets WHERE accountNamespace = ?",
                arguments: [Self.id(accountNamespace)]
            )
        }
    }

    func syncState(accountNamespace: UUID) throws -> SyncState {
        try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM syncStates WHERE accountNamespace = ?",
                arguments: [Self.id(accountNamespace)]
            ) else {
                return SyncState(accountNamespace: accountNamespace)
            }
            let incremental: Double? = row["lastIncrementalRefreshAt"]
            let reconciliation: Double? = row["lastFullReconciliationAt"]
            let highest: Double? = row["highestObservedUpdatedAt"]
            return SyncState(
                accountNamespace: accountNamespace,
                lastIncrementalRefreshAt: incremental.map(Date.init(timeIntervalSince1970:)),
                lastFullReconciliationAt: reconciliation.map(Date.init(timeIntervalSince1970:)),
                highestObservedUpdatedAt: highest.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    func updateSyncState(
        accountNamespace: UUID,
        incrementalAt: Date? = nil,
        reconciliationAt: Date? = nil,
        highestObservedUpdatedAt: Date?
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO syncStates(
                        accountNamespace, lastIncrementalRefreshAt,
                        lastFullReconciliationAt, highestObservedUpdatedAt
                    ) VALUES (?, ?, ?, ?)
                    ON CONFLICT(accountNamespace) DO UPDATE SET
                        lastIncrementalRefreshAt = COALESCE(
                            excluded.lastIncrementalRefreshAt,
                            syncStates.lastIncrementalRefreshAt
                        ),
                        lastFullReconciliationAt = COALESCE(
                            excluded.lastFullReconciliationAt,
                            syncStates.lastFullReconciliationAt
                        ),
                        highestObservedUpdatedAt = CASE
                            WHEN excluded.highestObservedUpdatedAt IS NULL
                                THEN syncStates.highestObservedUpdatedAt
                            WHEN syncStates.highestObservedUpdatedAt IS NULL
                                THEN excluded.highestObservedUpdatedAt
                            ELSE MAX(
                                excluded.highestObservedUpdatedAt,
                                syncStates.highestObservedUpdatedAt
                            )
                        END
                    """,
                arguments: [
                    Self.id(accountNamespace),
                    incrementalAt?.timeIntervalSince1970,
                    reconciliationAt?.timeIntervalSince1970,
                    highestObservedUpdatedAt?.timeIntervalSince1970,
                ]
            )
        }
    }

    func saveServerMediaProfile(_ profile: ServerMediaProfile) throws {
        let data = try JSONEncoder().encode(profile)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO serverMediaProfiles(accountNamespace, profileJSON)
                    VALUES (?, ?)
                    ON CONFLICT(accountNamespace) DO UPDATE SET profileJSON = excluded.profileJSON
                    """,
                arguments: [Self.id(profile.accountNamespace), data]
            )
        }
    }

    func serverMediaProfile(accountNamespace: UUID) throws -> ServerMediaProfile? {
        try database.read { db in
            guard let data = try Data.fetchOne(
                db,
                sql: "SELECT profileJSON FROM serverMediaProfiles WHERE accountNamespace = ?",
                arguments: [Self.id(accountNamespace)]
            ) else {
                return nil
            }
            return try JSONDecoder().decode(ServerMediaProfile.self, from: data)
        }
    }

    func count(accountNamespace: UUID) throws -> Int {
        try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM assets WHERE accountNamespace = ?",
                arguments: [Self.id(accountNamespace)]
            ) ?? 0
        }
    }

    func schemaObjects() throws -> [String] {
        try database.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type IN ('table', 'index') ORDER BY name"
            )
        }
    }

    private static func id(_ id: UUID) -> String {
        id.uuidString.lowercased()
    }

    private static func arguments(
        for asset: TimelineAsset,
        reconciliationGeneration: Int64?
    ) -> StatementArguments {
        [
            "accountNamespace": id(asset.accountNamespace),
            "id": id(asset.id),
            "ownerID": asset.ownerID.map(id),
            "mediaType": asset.mediaType.rawValue,
            "localDateTime": asset.localDateTime?.timeIntervalSince1970,
            "fileCreatedAt": asset.fileCreatedAt?.timeIntervalSince1970,
            "createdAt": asset.createdAt.timeIntervalSince1970,
            "updatedAt": asset.updatedAt.timeIntervalSince1970,
            "timelineDate": asset.timelineDate.timeIntervalSince1970,
            "width": asset.width,
            "height": asset.height,
            "thumbhash": asset.thumbhash,
            "checksum": asset.checksum,
            "originalFileName": asset.originalFileName,
            "originalMimeType": asset.originalMimeType,
            "isFavorite": asset.isFavorite,
            "isEdited": asset.isEdited,
            "isArchived": asset.isArchived,
            "isTrashed": asset.isTrashed,
            "visibility": asset.visibility,
            "rating": asset.rating?.rawValue,
            "reconciliationGeneration": reconciliationGeneration,
        ]
    }

    private static func asset(from row: Row) throws -> TimelineAsset {
        let account: String = row["accountNamespace"]
        let id: String = row["id"]
        let owner: String? = row["ownerID"]
        let type: String = row["mediaType"]
        let createdAt: Double = row["createdAt"]
        let updatedAt: Double = row["updatedAt"]
        guard let accountNamespace = UUID(uuidString: account),
              let assetID = UUID(uuidString: id),
              let mediaType = TimelineAssetMediaType(rawValue: type) else {
            throw AssetDatabaseError.corruptRecord
        }
        let localDateTime: Double? = row["localDateTime"]
        let fileCreatedAt: Double? = row["fileCreatedAt"]
        let ratingValue: Int? = row["rating"]
        return TimelineAsset(
            accountNamespace: accountNamespace,
            id: assetID,
            ownerID: owner.flatMap(UUID.init(uuidString:)),
            mediaType: mediaType,
            localDateTime: localDateTime.map(Date.init(timeIntervalSince1970:)),
            fileCreatedAt: fileCreatedAt.map(Date.init(timeIntervalSince1970:)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            width: row["width"],
            height: row["height"],
            thumbhash: row["thumbhash"],
            checksum: row["checksum"],
            originalFileName: row["originalFileName"],
            originalMimeType: row["originalMimeType"],
            isFavorite: row["isFavorite"],
            isEdited: row["isEdited"],
            isArchived: row["isArchived"],
            isTrashed: row["isTrashed"],
            visibility: row["visibility"],
            rating: ratingValue.flatMap(AssetRating.init(rawValue:))
        )
    }
}
