import Foundation
import GRDB

struct StorageRecoveryNotice: Sendable, Equatable {
    let backupDirectory: URL
    let recoveredAt: Date
}

struct LauncherStoreOpenResult: Sendable {
    let store: LauncherStore?
    let recoveryNotice: StorageRecoveryNotice?
}

enum LauncherStoreError: Error, Sendable, Equatable {
    case invalidPersistedValue(table: String, column: String)
    case storeClosed
}

actor LauncherStore {
    private let databaseQueue: DatabaseQueue
    private var isClosed = false

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        databaseQueue = try DatabaseQueue(path: databaseURL.path)
        try Self.makeMigrator().migrate(databaseQueue)
        try Self.validatePersistedValues(in: databaseQueue)
    }

    static nonisolated func openRecovering(
        databaseURL: URL,
        fileManager: FileManager = .default
    ) -> LauncherStoreOpenResult {
        do {
            return LauncherStoreOpenResult(
                store: try LauncherStore(databaseURL: databaseURL),
                recoveryNotice: nil
            )
        } catch {
            guard shouldAttemptRecovery(after: error) else {
                return LauncherStoreOpenResult(store: nil, recoveryNotice: nil)
            }
        }

        guard migrationsAreValid() else {
            return LauncherStoreOpenResult(store: nil, recoveryNotice: nil)
        }

        let recoveredAt = Date()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime,
            .withFractionalSeconds,
        ]
        let directoryName = formatter.string(from: recoveredAt)
            .replacingOccurrences(of: ":", with: "-")
        let recoveryDirectory = databaseURL.deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)

        do {
            try fileManager.createDirectory(
                at: recoveryDirectory,
                withIntermediateDirectories: true
            )
            try moveDatabaseFiles(
                databaseURL: databaseURL,
                to: recoveryDirectory,
                fileManager: fileManager
            )
            let store = try LauncherStore(databaseURL: databaseURL)
            return LauncherStoreOpenResult(
                store: store,
                recoveryNotice: StorageRecoveryNotice(
                    backupDirectory: recoveryDirectory,
                    recoveredAt: recoveredAt
                )
            )
        } catch {
            return LauncherStoreOpenResult(store: nil, recoveryNotice: nil)
        }
    }

    static nonisolated func defaultDatabaseURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("com.yorozu.app", isDirectory: true)
            .appendingPathComponent("Yorozu.sqlite", isDirectory: false)
    }

    func close() throws {
        guard !isClosed else {
            return
        }
        isClosed = true
        try databaseQueue.close()
    }

    func loadApplications() throws -> [LaunchableApplication] {
        try ensureOpen()
        return try databaseQueue.read { database in
            let rows = try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        a.identity_key,
                        a.bundle_identifier,
                        a.canonical_path,
                        a.display_name,
                        a.localized_name,
                        a.version,
                        p.alias,
                        COALESCE(p.is_pinned, 0) AS is_pinned,
                        p.pinned_at,
                        COALESCE(p.launch_count, 0) AS launch_count,
                        p.last_launched_at
                    FROM launcher_app_cache a
                    LEFT JOIN launcher_preferences p
                      ON p.identity_key = a.identity_key
                    """
            )
            return rows.map(Self.application(from:))
        }
    }

    func replaceApplications(_ applications: [DiscoveredApplication], indexedAt: Date) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(sql: "DELETE FROM launcher_app_cache")
            for application in applications {
                try database.execute(
                    sql: """
                        INSERT INTO launcher_app_cache (
                            identity_key,
                            bundle_identifier,
                            canonical_path,
                            display_name,
                            localized_name,
                            version,
                            normalized_search_text,
                            last_seen_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        application.id.rawValue,
                        application.bundleIdentifier,
                        application.canonicalURL.path,
                        application.displayName,
                        application.localizedName,
                        application.version,
                        application.normalizedSearchText,
                        indexedAt.timeIntervalSince1970,
                    ]
                )
            }
        }
    }

    func savePreference(identity: ApplicationIdentity, preference: LauncherPreference) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO launcher_preferences (
                        identity_key,
                        alias,
                        is_pinned,
                        pinned_at,
                        launch_count,
                        last_launched_at,
                        updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(identity_key) DO UPDATE SET
                        alias = excluded.alias,
                        is_pinned = excluded.is_pinned,
                        pinned_at = excluded.pinned_at,
                        launch_count = excluded.launch_count,
                        last_launched_at = excluded.last_launched_at,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    identity.rawValue,
                    preference.alias,
                    preference.isPinned,
                    preference.pinnedAt?.timeIntervalSince1970,
                    preference.launchCount,
                    preference.lastLaunchedAt?.timeIntervalSince1970,
                    Date().timeIntervalSince1970,
                ]
            )
        }
    }

    func loadPreference(identity: ApplicationIdentity) throws -> LauncherPreference {
        try ensureOpen()
        return try databaseQueue.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT
                        alias,
                        is_pinned,
                        pinned_at,
                        launch_count,
                        last_launched_at
                    FROM launcher_preferences
                    WHERE identity_key = ?
                    """,
                arguments: [identity.rawValue]
            ) else {
                return .empty
            }
            return Self.preference(from: row)
        }
    }

    func loadClipboardItems() throws -> [ClipboardItem] {
        try ensureOpen()
        return try databaseQueue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT
                        id,
                        kind,
                        content_hash,
                        text_content,
                        file_paths_json,
                        NULL AS image_data,
                        length(image_data) AS image_byte_count,
                        image_width,
                        image_height,
                        normalized_search_text,
                        source_bundle_identifier,
                        source_application_name,
                        is_pinned,
                        pinned_at,
                        copied_at,
                        last_used_at,
                        updated_at
                    FROM clipboard_items
                    ORDER BY
                        is_pinned DESC,
                        CASE WHEN is_pinned = 1 THEN last_used_at END DESC,
                        pinned_at ASC,
                        MAX(copied_at, COALESCE(last_used_at, copied_at)) DESC
                    """
            ).map { try Self.clipboardItem(from: $0) }
        }
    }

    func loadClipboardImageData(id: UUID) throws -> Data? {
        try ensureOpen()
        return try databaseQueue.read { database in
            try Data.fetchOne(
                database,
                sql: """
                    SELECT image_data
                    FROM clipboard_items
                    WHERE id = ? AND kind = ?
                    """,
                arguments: [id.uuidString, ClipboardItemKind.image.rawValue]
            )
        }
    }

    func recordClipboardCapture(
        _ capture: ClipboardCapture,
        retentionDays: Int,
        maximumItems: Int,
        performsFullMaintenance: Bool = true
    ) throws -> ClipboardItem {
        try ensureOpen()
        return try databaseQueue.write { database in
            let latest = try Row.fetchOne(
                database,
                sql: """
                    SELECT id, content_hash
                    FROM clipboard_items
                    ORDER BY copied_at DESC
                    LIMIT 1
                    """
            )

            let itemID: UUID
            if let latest,
               let latestHash: String = latest["content_hash"],
               latestHash == capture.contentHash,
               let rawID: String = latest["id"],
               let existingID = UUID(uuidString: rawID) {
                itemID = existingID
                try database.execute(
                    sql: """
                        UPDATE clipboard_items
                        SET source_bundle_identifier = ?,
                            source_application_name = ?,
                            copied_at = ?,
                            updated_at = ?
                        WHERE id = ?
                        """,
                    arguments: [
                        capture.sourceBundleIdentifier,
                        capture.sourceApplicationName,
                        capture.copiedAt.timeIntervalSince1970,
                        capture.copiedAt.timeIntervalSince1970,
                        itemID.uuidString,
                    ]
                )
            } else {
                itemID = capture.id
                try database.execute(
                    sql: """
                        INSERT INTO clipboard_items (
                            id,
                            kind,
                            content_hash,
                            text_content,
                            file_paths_json,
                            image_data,
                            image_width,
                            image_height,
                            normalized_search_text,
                            source_bundle_identifier,
                            source_application_name,
                            is_pinned,
                            pinned_at,
                            copied_at,
                            updated_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, NULL, ?, ?)
                        """,
                    arguments: [
                        itemID.uuidString,
                        capture.kind.rawValue,
                        capture.contentHash,
                        capture.textContent,
                        try Self.encodedFilePaths(capture.filePaths),
                        capture.imageData,
                        capture.imageWidth,
                        capture.imageHeight,
                        capture.normalizedSearchText,
                        capture.sourceBundleIdentifier,
                        capture.sourceApplicationName,
                        capture.copiedAt.timeIntervalSince1970,
                        capture.copiedAt.timeIntervalSince1970,
                    ]
                )
            }

            if performsFullMaintenance {
                try Self.pruneClipboard(
                    database: database,
                    retentionDays: retentionDays,
                    maximumItems: maximumItems,
                    now: capture.copiedAt
                )
            }

            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT
                        id,
                        kind,
                        content_hash,
                        text_content,
                        file_paths_json,
                        NULL AS image_data,
                        length(image_data) AS image_byte_count,
                        image_width,
                        image_height,
                        normalized_search_text,
                        source_bundle_identifier,
                        source_application_name,
                        is_pinned,
                        pinned_at,
                        copied_at,
                        last_used_at,
                        updated_at
                    FROM clipboard_items
                    WHERE id = ?
                    """,
                arguments: [itemID.uuidString]
            ) else {
                throw LauncherError.commandNotSupported
            }
            return try Self.clipboardItem(from: row)
        }
    }

    func setClipboardPinned(id: UUID, isPinned: Bool, now: Date = Date()) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_items
                    SET is_pinned = ?, pinned_at = ?, updated_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    isPinned,
                    isPinned ? now.timeIntervalSince1970 : nil,
                    now.timeIntervalSince1970,
                    id.uuidString,
                ]
            )
        }
    }

    func recordClipboardUse(id: UUID, usedAt: Date = Date()) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    UPDATE clipboard_items
                    SET last_used_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    usedAt.timeIntervalSince1970,
                    id.uuidString,
                ]
            )
        }
    }

    func deleteClipboardItem(id: UUID) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(
                sql: "DELETE FROM clipboard_items WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func clearClipboardHistory(includePinned: Bool) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            if includePinned {
                try database.execute(sql: "DELETE FROM clipboard_items")
            } else {
                try database.execute(sql: "DELETE FROM clipboard_items WHERE is_pinned = 0")
            }
        }
    }

    func pruneClipboardHistory(
        retentionDays: Int,
        maximumItems: Int,
        now: Date = Date()
    ) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try Self.pruneClipboard(
                database: database,
                retentionDays: retentionDays,
                maximumItems: maximumItems,
                now: now
            )
        }
    }

    func loadSnippets() throws -> [Snippet] {
        try ensureOpen()
        return try databaseQueue.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT *
                    FROM snippets
                    ORDER BY last_used_at DESC, use_count DESC, name COLLATE NOCASE ASC
                    """
            ).map { try Self.snippet(from: $0) }
        }
    }

    func saveSnippet(_ snippet: Snippet) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO snippets (
                        id,
                        name,
                        keyword,
                        normalized_keyword,
                        content,
                        normalized_search_text,
                        use_count,
                        last_used_at,
                        created_at,
                        updated_at
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        name = excluded.name,
                        keyword = excluded.keyword,
                        normalized_keyword = excluded.normalized_keyword,
                        content = excluded.content,
                        normalized_search_text = excluded.normalized_search_text,
                        use_count = excluded.use_count,
                        last_used_at = excluded.last_used_at,
                        updated_at = excluded.updated_at
                    """,
                arguments: [
                    snippet.id.uuidString,
                    snippet.name,
                    snippet.keyword,
                    snippet.normalizedKeyword,
                    snippet.content,
                    snippet.normalizedSearchText,
                    snippet.useCount,
                    snippet.lastUsedAt?.timeIntervalSince1970,
                    snippet.createdAt.timeIntervalSince1970,
                    snippet.updatedAt.timeIntervalSince1970,
                ]
            )
        }
    }

    func deleteSnippet(id: UUID) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(
                sql: "DELETE FROM snippets WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    func recordSnippetUse(id: UUID, usedAt: Date = Date()) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    UPDATE snippets
                    SET use_count = use_count + 1,
                        last_used_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    usedAt.timeIntervalSince1970,
                    id.uuidString,
                ]
            )
        }
    }

    func loadURLPreview(url: String, newerThan cutoff: Date) throws -> URLPreviewCacheEntry? {
        try ensureOpen()
        return try databaseQueue.read { database in
            guard let row = try Row.fetchOne(
                database,
                sql: """
                    SELECT url, metadata_data, fetched_at
                    FROM url_preview_cache
                    WHERE url = ? AND fetched_at >= ?
                    """,
                arguments: [url, cutoff.timeIntervalSince1970]
            ) else {
                return nil
            }
            let fetchedAt: Double = row["fetched_at"]
            return URLPreviewCacheEntry(
                url: row["url"],
                metadataData: row["metadata_data"],
                fetchedAt: Date(timeIntervalSince1970: fetchedAt)
            )
        }
    }

    func saveURLPreview(_ entry: URLPreviewCacheEntry) throws {
        try ensureOpen()
        try databaseQueue.write { database in
            try database.execute(
                sql: """
                    INSERT INTO url_preview_cache (
                        url,
                        metadata_data,
                        fetched_at
                    ) VALUES (?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        metadata_data = excluded.metadata_data,
                        fetched_at = excluded.fetched_at
                    """,
                arguments: [
                    entry.url,
                    entry.metadataData,
                    entry.fetchedAt.timeIntervalSince1970,
                ]
            )
            try database.execute(
                sql: "DELETE FROM url_preview_cache WHERE fetched_at < ?",
                arguments: [entry.fetchedAt.addingTimeInterval(-30 * 86_400).timeIntervalSince1970]
            )
        }
    }

    private func ensureOpen() throws {
        guard !isClosed else {
            throw LauncherStoreError.storeClosed
        }
    }

    private nonisolated static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_launcher") { database in
            try database.execute(
                sql: """
                    CREATE TABLE launcher_app_cache (
                        identity_key TEXT PRIMARY KEY NOT NULL,
                        bundle_identifier TEXT,
                        canonical_path TEXT NOT NULL UNIQUE,
                        display_name TEXT NOT NULL,
                        localized_name TEXT,
                        version TEXT,
                        normalized_search_text TEXT NOT NULL,
                        last_seen_at REAL NOT NULL
                    );

                    CREATE TABLE launcher_preferences (
                        identity_key TEXT PRIMARY KEY NOT NULL,
                        alias TEXT,
                        is_pinned INTEGER NOT NULL DEFAULT 0,
                        pinned_at REAL,
                        launch_count INTEGER NOT NULL DEFAULT 0,
                        last_launched_at REAL,
                        updated_at REAL NOT NULL
                    );
                    """
            )
        }
        migrator.registerMigration("v2_clipboard_snippets") { database in
            try database.execute(
                sql: """
                    CREATE TABLE clipboard_items (
                        id TEXT PRIMARY KEY NOT NULL,
                        kind TEXT NOT NULL,
                        content_hash TEXT NOT NULL,
                        text_content TEXT,
                        file_paths_json TEXT,
                        normalized_search_text TEXT NOT NULL,
                        source_bundle_identifier TEXT,
                        source_application_name TEXT,
                        is_pinned INTEGER NOT NULL DEFAULT 0,
                        pinned_at REAL,
                        copied_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );

                    CREATE INDEX clipboard_items_copied_at
                    ON clipboard_items(copied_at DESC);

                    CREATE INDEX clipboard_items_content_hash
                    ON clipboard_items(content_hash);

                    CREATE TABLE snippets (
                        id TEXT PRIMARY KEY NOT NULL,
                        name TEXT NOT NULL,
                        keyword TEXT,
                        normalized_keyword TEXT,
                        content TEXT NOT NULL,
                        normalized_search_text TEXT NOT NULL,
                        use_count INTEGER NOT NULL DEFAULT 0,
                        last_used_at REAL,
                        created_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    );

                    CREATE UNIQUE INDEX snippets_normalized_keyword
                    ON snippets(normalized_keyword)
                    WHERE normalized_keyword IS NOT NULL;
                    """
            )
        }
        migrator.registerMigration("v3_clipboard_images") { database in
            try database.execute(
                sql: """
                    ALTER TABLE clipboard_items ADD COLUMN image_data BLOB;
                    ALTER TABLE clipboard_items ADD COLUMN image_width INTEGER;
                    ALTER TABLE clipboard_items ADD COLUMN image_height INTEGER;
                    """
            )
        }
        migrator.registerMigration("v4_url_preview_cache") { database in
            try database.execute(
                sql: """
                    CREATE TABLE url_preview_cache (
                        url TEXT PRIMARY KEY NOT NULL,
                        metadata_data BLOB NOT NULL,
                        fetched_at REAL NOT NULL
                    );
                """
            )
        }
        migrator.registerMigration("v5_clipboard_usage") { database in
            try database.execute(
                sql: """
                    ALTER TABLE clipboard_items ADD COLUMN last_used_at REAL;
                    """
            )
        }
        migrator.registerMigration("v6_safe_url_preview_cache") { database in
            // v4 stored NSKeyedArchiver payloads from LinkPresentation. The
            // safe preview pipeline uses bounded Codable documents instead.
            try database.execute(sql: "DELETE FROM url_preview_cache")
        }
        return migrator
    }

    private nonisolated static func validatePersistedValues(
        in databaseQueue: DatabaseQueue
    ) throws {
        try databaseQueue.read { database in
            let clipboardRows = try Row.fetchAll(
                database,
                sql: "SELECT id, kind, file_paths_json FROM clipboard_items"
            )
            for row in clipboardRows {
                let rawID: String = row["id"]
                guard UUID(uuidString: rawID) != nil else {
                    throw LauncherStoreError.invalidPersistedValue(
                        table: "clipboard_items",
                        column: "id"
                    )
                }
                let rawKind: String = row["kind"]
                guard ClipboardItemKind(rawValue: rawKind) != nil else {
                    throw LauncherStoreError.invalidPersistedValue(
                        table: "clipboard_items",
                        column: "kind"
                    )
                }
                let filePathsJSON: String? = row["file_paths_json"]
                _ = try decodedFilePaths(filePathsJSON)
            }

            let snippetIDs = try String.fetchAll(
                database,
                sql: "SELECT id FROM snippets"
            )
            guard snippetIDs.allSatisfy({ UUID(uuidString: $0) != nil }) else {
                throw LauncherStoreError.invalidPersistedValue(
                    table: "snippets",
                    column: "id"
                )
            }
        }
    }

    private nonisolated static func migrationsAreValid() -> Bool {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("yorozu-migration-\(UUID().uuidString)", isDirectory: true)
        let databaseURL = directory.appendingPathComponent("Yorozu.sqlite")
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            defer {
                try? fileManager.removeItem(at: directory)
            }
            let databaseQueue = try DatabaseQueue(path: databaseURL.path)
            try makeMigrator().migrate(databaseQueue)
            try validatePersistedValues(in: databaseQueue)
            try databaseQueue.close()
            return true
        } catch {
            return false
        }
    }

    private nonisolated static func shouldAttemptRecovery(after error: Error) -> Bool {
        if error is LauncherStoreError {
            return true
        }
        guard let databaseError = error as? DatabaseError else {
            return false
        }
        switch databaseError.resultCode.primaryResultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB, .SQLITE_SCHEMA, .SQLITE_ERROR:
            return true
        default:
            return false
        }
    }

    private nonisolated static func moveDatabaseFiles(
        databaseURL: URL,
        to recoveryDirectory: URL,
        fileManager: FileManager
    ) throws {
        let sourceURLs = [
            databaseURL,
            URL(fileURLWithPath: databaseURL.path + "-wal"),
            URL(fileURLWithPath: databaseURL.path + "-shm"),
        ]
        guard fileManager.fileExists(atPath: databaseURL.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        var moves: [(source: URL, destination: URL)] = []
        do {
            for sourceURL in sourceURLs where fileManager.fileExists(atPath: sourceURL.path) {
                let destinationURL = recoveryDirectory
                    .appendingPathComponent(sourceURL.lastPathComponent)
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
                moves.append((sourceURL, destinationURL))
            }
        } catch {
            for move in moves.reversed() where fileManager.fileExists(atPath: move.destination.path) {
                try? fileManager.moveItem(at: move.destination, to: move.source)
            }
            throw error
        }
    }

    private nonisolated static func application(from row: Row) -> LaunchableApplication {
        let identity: String = row["identity_key"]
        let bundleIdentifier: String? = row["bundle_identifier"]
        let path: String = row["canonical_path"]
        let displayName: String = row["display_name"]
        let localizedName: String? = row["localized_name"]
        let version: String? = row["version"]
        return LaunchableApplication(
            id: ApplicationIdentity(rawValue: identity),
            bundleIdentifier: bundleIdentifier,
            canonicalURL: URL(fileURLWithPath: path),
            displayName: displayName,
            localizedName: localizedName,
            version: version,
            preference: preference(from: row)
        )
    }

    private nonisolated static func preference(from row: Row) -> LauncherPreference {
        let alias: String? = row["alias"]
        let isPinned: Bool = row["is_pinned"]
        let pinnedAtTimestamp: Double? = row["pinned_at"]
        let launchCount: Int = row["launch_count"]
        let lastLaunchedAtTimestamp: Double? = row["last_launched_at"]
        return LauncherPreference(
            alias: alias,
            isPinned: isPinned,
            pinnedAt: pinnedAtTimestamp.map(Date.init(timeIntervalSince1970:)),
            launchCount: launchCount,
            lastLaunchedAt: lastLaunchedAtTimestamp.map(Date.init(timeIntervalSince1970:))
        )
    }

    private nonisolated static func clipboardItem(from row: Row) throws -> ClipboardItem {
        let rawID: String = row["id"]
        let rawKind: String = row["kind"]
        guard let id = UUID(uuidString: rawID) else {
            throw LauncherStoreError.invalidPersistedValue(
                table: "clipboard_items",
                column: "id"
            )
        }
        guard let kind = ClipboardItemKind(rawValue: rawKind) else {
            throw LauncherStoreError.invalidPersistedValue(
                table: "clipboard_items",
                column: "kind"
            )
        }
        let filePathsJSON: String? = row["file_paths_json"]
        let pinnedAt: Double? = row["pinned_at"]
        let copiedAt: Double = row["copied_at"]
        let lastUsedAt: Double? = row["last_used_at"]
        let updatedAt: Double = row["updated_at"]

        return ClipboardItem(
            id: id,
            kind: kind,
            contentHash: row["content_hash"],
            textContent: row["text_content"],
            filePaths: try decodedFilePaths(filePathsJSON),
            imageData: row["image_data"],
            imageByteCount: row["image_byte_count"],
            imageWidth: row["image_width"],
            imageHeight: row["image_height"],
            normalizedSearchText: row["normalized_search_text"],
            sourceBundleIdentifier: row["source_bundle_identifier"],
            sourceApplicationName: row["source_application_name"],
            isPinned: row["is_pinned"],
            pinnedAt: pinnedAt.map(Date.init(timeIntervalSince1970:)),
            copiedAt: Date(timeIntervalSince1970: copiedAt),
            lastUsedAt: lastUsedAt.map(Date.init(timeIntervalSince1970:)),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    private nonisolated static func snippet(from row: Row) throws -> Snippet {
        let rawID: String = row["id"]
        guard let id = UUID(uuidString: rawID) else {
            throw LauncherStoreError.invalidPersistedValue(
                table: "snippets",
                column: "id"
            )
        }
        let lastUsedAt: Double? = row["last_used_at"]
        let createdAt: Double = row["created_at"]
        let updatedAt: Double = row["updated_at"]
        return Snippet(
            id: id,
            name: row["name"],
            keyword: row["keyword"],
            content: row["content"],
            useCount: row["use_count"],
            lastUsedAt: lastUsedAt.map(Date.init(timeIntervalSince1970:)),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            normalizedSearchText: row["normalized_search_text"]
        )
    }

    private nonisolated static func encodedFilePaths(_ paths: [String]) throws -> String? {
        guard !paths.isEmpty else { return nil }
        let data = try JSONEncoder().encode(paths)
        return String(data: data, encoding: .utf8)
    }

    private nonisolated static func decodedFilePaths(_ value: String?) throws -> [String] {
        guard let value else { return [] }
        guard let data = value.data(using: .utf8),
              let paths = try? JSONDecoder().decode([String].self, from: data) else {
            throw LauncherStoreError.invalidPersistedValue(
                table: "clipboard_items",
                column: "file_paths_json"
            )
        }
        return paths
    }

    private nonisolated static func pruneClipboard(
        database: Database,
        retentionDays: Int,
        maximumItems: Int,
        now: Date
    ) throws {
        let retentionCutoff = now.addingTimeInterval(
            -Double(max(1, retentionDays)) * 86_400
        )
        try database.execute(
            sql: """
                DELETE FROM clipboard_items
                WHERE is_pinned = 0 AND copied_at < ?
                """,
            arguments: [retentionCutoff.timeIntervalSince1970]
        )
        try database.execute(
            sql: """
                DELETE FROM clipboard_items
                WHERE is_pinned = 0
                  AND id NOT IN (
                      SELECT id
                      FROM clipboard_items
                      WHERE is_pinned = 0
                      ORDER BY copied_at DESC
                      LIMIT ?
                  )
            """,
            arguments: [max(1, maximumItems)]
        )

        let imageRows = try Row.fetchAll(
            database,
            sql: """
                SELECT id, length(image_data) AS byte_count
                FROM clipboard_items
                WHERE is_pinned = 0
                  AND kind = ?
                  AND image_data IS NOT NULL
                ORDER BY copied_at DESC
                """,
            arguments: [ClipboardItemKind.image.rawValue]
        )
        var retainedImageBytes = 0
        for row in imageRows {
            let byteCount: Int = row["byte_count"]
            if retainedImageBytes + byteCount <= ClipboardStoragePolicy.maximumUnpinnedImageBytes {
                retainedImageBytes += byteCount
            } else {
                let id: String = row["id"]
                try database.execute(
                    sql: "DELETE FROM clipboard_items WHERE id = ?",
                    arguments: [id]
                )
            }
        }
    }
}
