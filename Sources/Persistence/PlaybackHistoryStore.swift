import Darwin
import CryptoKit
import Foundation
import GRDB

/// Owns durable media identity, resume history, and their schema migrations.
actor PlaybackHistoryStore: MediaLibraryPersisting {
    private let database: DatabaseQueue
    private let migrationBackup: DatabaseMigrationBackup?
    private var closingScanIDs: Set<String> = []
    private var failedScanFinalizations: [String: ScanFinalization] = [:]

    private struct ScanFinalization: Sendable {
        let scan: MediaLibraryScanSession
        let discoveredCount: Int
        let indexedCount: Int
        let skippedCount: Int
        let cancelled: Bool

        var interruptedStatus: String { cancelled ? "cancelled" : "partial" }
    }

    init(path: String) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        database = try DatabaseQueue(path: path, configuration: configuration)
        migrationBackup = DatabaseMigrationBackup(databasePath: path)
        if let migrationBackup {
            try migrationBackup.migrate(database, using: Self.makeMigrator())
        } else {
            try Self.makeMigrator().migrate(database)
        }
        // A privacy migration can purge historical rows. Retaining its pre-upgrade
        // snapshot would make those rows recoverable despite the existing exclusion.
        let hasPrivacyRules = try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM private_media_roots)") == true
        }
        if hasPrivacyRules { try migrationBackup?.discard() }
        try database.write { db in
            try db.execute(
                sql: """
                UPDATE media_scan_runs
                SET status = 'cancelled', completed_at = COALESCE(completed_at, ?)
                WHERE status = 'running'
                """,
                arguments: [Date.now.timeIntervalSince1970]
            )
        }
    }

    static func applicationStore(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> PlaybackHistoryStore {
        let databaseDirectory: URL
        #if DEBUG
        if let acceptanceDirectory = try debugAcceptanceDirectory(environment: environment) {
            databaseDirectory = acceptanceDirectory
        } else {
            databaseDirectory = try defaultDatabaseDirectory()
        }
        #else
        databaseDirectory = try defaultDatabaseDirectory()
        #endif
        return try PlaybackHistoryStore(path: databaseDirectory.appending(path: "playback.sqlite").path)
    }

    private static func defaultDatabaseDirectory() throws -> URL {
        let supportDirectory = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = supportDirectory.appending(path: "Bomu", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    #if DEBUG
    /// A visible empty-library run uses a disposable directory without moving the user's database.
    /// Invalid opt-in is an error; silently falling back would expose real library data to the test.
    static func debugAcceptanceDirectory(environment: [String: String]) throws -> URL? {
        guard let path = environment["BOMU_ACCEPTANCE_LIBRARY_DIRECTORY"] else { return nil }
        let temporaryRoot = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let directory = URL(fileURLWithPath: path, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        guard (path as NSString).isAbsolutePath,
              directory.path.hasPrefix(temporaryRoot.path + "/"),
              let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey]),
              directoryValues.isDirectory == true else {
            throw AcceptanceStorageError.invalidDirectory
        }
        let marker = directory.appending(path: ".bomu-acceptance-library")
        guard let markerValues = try? marker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              markerValues.isRegularFile == true, markerValues.isSymbolicLink != true,
              (try? String(contentsOf: marker, encoding: .utf8)) == "Bomu isolated acceptance library\n" else {
            throw AcceptanceStorageError.invalidDirectory
        }
        return directory
    }

    private enum AcceptanceStorageError: LocalizedError {
        case invalidDirectory

        var errorDescription: String? { String(localized: "library.unavailable") }
    }
    #endif

    func openHistory(for url: URL) async throws -> PlaybackHistorySession {
        let identity = try Self.identity(for: url)
        let history: Result<PlaybackHistory?, any Error>
        do {
            let saved: PlaybackHistory? = try await database.write { db in
                let mediaFileID = try Self.resolve(identity, in: db)
                try Self.migrateLegacyHistory(for: url, mediaFileID: mediaFileID, in: db)
                if try Self.isHistoryExcluded(volumeID: identity.volumeID,
                                              relativePath: identity.relativePath, in: db) {
                    try db.execute(sql: "DELETE FROM playback_history WHERE media_file_id = ?", arguments: [mediaFileID])
                    return nil
                }
                guard let row = try Row.fetchOne(
                    db,
                    sql: """
                    SELECT media_file_id, relative_path, position, audio_track_id,
                           subtitle_track_id, volume, updated_at
                    FROM playback_history
                    JOIN media_files ON media_files.id = playback_history.media_file_id
                    WHERE media_file_id = ?
                    """,
                    arguments: [mediaFileID]
                ) else { return nil }
                return PlaybackHistory(
                    mediaFileID: row["media_file_id"],
                    relativePath: row["relative_path"],
                    position: row["position"],
                    audioTrackID: row["audio_track_id"],
                    subtitleTrackID: row["subtitle_track_id"],
                    volume: row["volume"],
                    updatedAt: Date(timeIntervalSince1970: row["updated_at"])
                )
            }
            history = .success(saved)
        } catch {
            history = .failure(error)
        }
        return PlaybackHistorySession(binding: PlaybackHistoryBinding(url: url, identity: identity),
                                      history: history)
    }

    func history(for url: URL) async throws -> PlaybackHistory? {
        try await openHistory(for: url).history.get()
    }

    /// Makes a discovered file queryable before metadata extraction or thumbnail work begins.
    func indexMediaFile(at url: URL) async throws -> Int64 {
        let identity = try Self.identity(for: url)
        return try await database.write { db in
            let mediaFileID = try Self.resolve(identity, in: db)
            try Self.migrateLegacyHistory(for: url, mediaFileID: mediaFileID, in: db)
            if try Self.isHistoryExcluded(volumeID: identity.volumeID,
                                          relativePath: identity.relativePath, in: db) {
                try db.execute(sql: "DELETE FROM playback_history WHERE media_file_id = ?", arguments: [mediaFileID])
                return mediaFileID
            }
            return mediaFileID
        }
    }

    func beginScan(folder: URL, includingSubfolders: Bool) async throws -> MediaLibraryScanSession {
        let source = try Self.sourceIdentity(for: folder)
        let scanID = UUID().uuidString
        let interrupted = failedScanFinalizations.values.filter { !closingScanIDs.contains($0.scan.id) }
        let session = try await database.write { db in
            try db.execute(
                sql: """
                INSERT INTO media_sources (volume_id, display_name, updated_at)
                VALUES (?, ?, ?)
                ON CONFLICT(volume_id) DO UPDATE SET
                    display_name = excluded.display_name,
                    updated_at = excluded.updated_at
                """,
                arguments: [source.volumeID, source.volumeName, Date.now.timeIntervalSince1970]
            )
            try db.execute(
                sql: """
                INSERT INTO media_source_roots
                    (volume_id, relative_path, display_name, including_subfolders)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(volume_id, relative_path) DO UPDATE SET
                    display_name = excluded.display_name,
                    including_subfolders = excluded.including_subfolders
                """,
                arguments: [source.volumeID, source.relativePath, source.displayName, includingSubfolders]
            )
            guard let rootID = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM media_source_roots WHERE volume_id = ? AND relative_path = ?",
                arguments: [source.volumeID, source.relativePath]
            ) else {
                throw PlaybackHistoryError.missingSourceRoot
            }
            for finalization in interrupted where finalization.scan.sourceRootID == rootID {
                _ = try Self.writeScanFinalization(finalization, status: finalization.interruptedStatus, in: db)
            }
            let activeScan = try Int64.fetchOne(
                db,
                sql: "SELECT 1 FROM media_scan_runs WHERE source_root_id = ? AND status = 'running' LIMIT 1",
                arguments: [rootID]
            )
            guard activeScan == nil else { throw PlaybackHistoryError.scanAlreadyRunning }
            try db.execute(
                sql: """
                INSERT INTO media_scan_runs (id, source_root_id, started_at, status)
                VALUES (?, ?, ?, 'running')
                """,
                arguments: [scanID, rootID, Date.now.timeIntervalSince1970]
            )
            try db.execute(sql: """
                INSERT INTO media_source_directories
                    (source_root_id, relative_path, display_name, last_seen_scan_id, is_present)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(source_root_id, relative_path) DO UPDATE SET
                    display_name = excluded.display_name,
                    last_seen_scan_id = excluded.last_seen_scan_id,
                    is_present = 1
                """, arguments: [rootID, source.relativePath, source.displayName, scanID])
            return MediaLibraryScanSession(id: scanID, sourceRootID: rootID)
        }
        for finalization in interrupted where finalization.scan.sourceRootID == session.sourceRootID {
            failedScanFinalizations.removeValue(forKey: finalization.scan.id)
        }
        return session
    }

    func indexDirectory(at folder: URL, in scan: MediaLibraryScanSession) async throws {
        try requireWritableScan(scan)
        let source = try Self.sourceIdentity(for: folder)
        try await database.write { db in
            try Self.requireActiveScan(scan, in: db)
            try db.execute(sql: """
                INSERT INTO media_source_directories
                    (source_root_id, relative_path, display_name, last_seen_scan_id, is_present)
                VALUES (?, ?, ?, ?, 1)
                ON CONFLICT(source_root_id, relative_path) DO UPDATE SET
                    display_name = excluded.display_name,
                    last_seen_scan_id = excluded.last_seen_scan_id,
                    is_present = 1
                """, arguments: [scan.sourceRootID, source.relativePath, source.displayName, scan.id])
        }
    }

    func libraryDirectories(in sourceRootID: Int64) async throws -> [MediaLibraryDirectory] {
        try await database.read { db in
            try Self.fetchLibraryDirectories(in: db, sourceRootID: sourceRootID)
        }
    }

    func indexMediaFile(at url: URL, in scan: MediaLibraryScanSession) async throws -> Int64 {
        try requireWritableScan(scan)
        let identity = try Self.identity(for: url)
        return try await database.write { db in
            try Self.requireActiveScan(scan, in: db)
            let mediaFileID = try Self.resolve(identity, in: db)
            try Self.migrateLegacyHistory(for: url, mediaFileID: mediaFileID, in: db)
            if try Self.isHistoryExcluded(volumeID: identity.volumeID,
                                          relativePath: identity.relativePath, in: db) {
                try db.execute(sql: "DELETE FROM playback_history WHERE media_file_id = ?", arguments: [mediaFileID])
            }
            let now = Date.now.timeIntervalSince1970
            try db.execute(
                sql: """
                INSERT INTO media_source_files
                    (source_root_id, media_file_id, last_seen_scan_id, is_present, last_seen_at, added_at)
                VALUES (?, ?, ?, 1, ?, ?)
                ON CONFLICT(source_root_id, media_file_id) DO UPDATE SET
                    last_seen_scan_id = excluded.last_seen_scan_id,
                    is_present = 1,
                    last_seen_at = excluded.last_seen_at
                """,
                arguments: [scan.sourceRootID, mediaFileID, scan.id, now, now]
            )
            return mediaFileID
        }
    }

    func finishScan(
        _ scan: MediaLibraryScanSession,
        reconcileDeletions: Bool,
        discoveredCount: Int,
        indexedCount: Int,
        skippedCount: Int,
        cancelled: Bool = false
    ) async throws {
        guard closingScanIDs.insert(scan.id).inserted else { throw PlaybackHistoryError.unknownScan(scan.id) }
        defer { closingScanIDs.remove(scan.id) }
        let finalization = ScanFinalization(scan: scan, discoveredCount: discoveredCount,
                                            indexedCount: indexedCount, skippedCount: skippedCount,
                                            cancelled: cancelled)
        let status: String
        if cancelled { status = "cancelled" }
        else if reconcileDeletions { status = "completed" }
        else { status = "partial" }
        do {
            try await database.write { db in
                guard try Self.writeScanFinalization(finalization, status: status, in: db) else {
                    throw PlaybackHistoryError.unknownScan(scan.id)
                }
                guard reconcileDeletions, !cancelled else { return }
                try db.execute(sql: """
                    UPDATE media_source_files SET is_present = 0
                    WHERE source_root_id = ? AND last_seen_scan_id != ?
                    """, arguments: [scan.sourceRootID, scan.id])
                try db.execute(sql: "UPDATE media_source_roots SET last_successful_scan_at = ? WHERE id = ?",
                               arguments: [Date.now.timeIntervalSince1970, scan.sourceRootID])
                try db.execute(sql: """
                    UPDATE media_source_directories SET is_present = 0
                    WHERE source_root_id = ? AND last_seen_scan_id != ?
                    """, arguments: [scan.sourceRootID, scan.id])
            }
            failedScanFinalizations.removeValue(forKey: scan.id)
        } catch PlaybackHistoryError.unknownScan {
            failedScanFinalizations.removeValue(forKey: scan.id)
            throw PlaybackHistoryError.unknownScan(scan.id)
        } catch {
            // The producer has ended even if its terminal transaction could not commit.
            failedScanFinalizations[scan.id] = finalization
            throw error
        }
    }

    func sourceRoots(mountedVolumeIDs: Set<String>) async throws -> [MediaSourceRoot] {
        try await database.read { db in
            try Self.fetchSourceRoots(in: db, mountedVolumeIDs: mountedVolumeIDs)
        }
    }

    func librarySnapshot(mountedVolumeIDs: Set<String>) async throws -> MediaLibrarySnapshot {
        try await database.read { db in
            let roots = try Self.fetchSourceRoots(in: db, mountedVolumeIDs: mountedVolumeIDs)

            var itemsByRoot = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, [MediaLibraryItem]()) })
            for item in try Self.fetchLibraryItems(in: db) {
                itemsByRoot[item.sourceRootID, default: []].append(item)
            }

            var directoriesByRoot = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, [MediaLibraryDirectory]()) })
            for directory in try Self.fetchLibraryDirectories(in: db) {
                directoriesByRoot[directory.sourceRootID, default: []].append(directory)
            }

            return MediaLibrarySnapshot(roots: roots, itemsByRoot: itemsByRoot,
                                        directoriesByRoot: directoriesByRoot)
        }
    }

    func libraryItems(in sourceRootID: Int64) async throws -> [MediaLibraryItem] {
        try await database.read { db in
            try Self.fetchLibraryItems(in: db, sourceRootID: sourceRootID)
        }
    }

    private func requireWritableScan(_ scan: MediaLibraryScanSession) throws {
        guard !closingScanIDs.contains(scan.id), failedScanFinalizations[scan.id] == nil else {
            throw PlaybackHistoryError.unknownScan(scan.id)
        }
    }

    private static func writeScanFinalization(_ finalization: ScanFinalization, status: String,
                                              in db: Database) throws -> Bool {
        try db.execute(sql: """
            UPDATE media_scan_runs
            SET completed_at = ?, discovered_count = ?, indexed_count = ?, skipped_count = ?, status = ?
            WHERE id = ? AND source_root_id = ? AND status = 'running'
            """, arguments: [Date.now.timeIntervalSince1970, finalization.discoveredCount,
                             finalization.indexedCount, finalization.skippedCount, status,
                             finalization.scan.id, finalization.scan.sourceRootID])
        return db.changesCount == 1
    }

    /** 会话校验与写入属于同一事务，已结束或清除的扫描不能修改后续扫描的事实。 */
    private static func requireActiveScan(_ scan: MediaLibraryScanSession, in db: Database) throws {
        let active = try Int.fetchOne(db, sql: """
            SELECT 1 FROM media_scan_runs
            WHERE id = ? AND source_root_id = ? AND status = 'running'
            """, arguments: [scan.id, scan.sourceRootID])
        guard active != nil else { throw PlaybackHistoryError.unknownScan(scan.id) }
    }

    private static func fetchSourceRoots(
        in db: Database,
        mountedVolumeIDs: Set<String>
    ) throws -> [MediaSourceRoot] {
        try Row.fetchAll(db, sql: """
            SELECT media_source_roots.id, volume_id, media_sources.display_name AS volume_name,
                   relative_path, media_source_roots.display_name AS root_name,
                   including_subfolders, last_successful_scan_at
            FROM media_source_roots
            JOIN media_sources USING (volume_id)
            ORDER BY media_sources.display_name COLLATE NOCASE, relative_path COLLATE NOCASE
            """).map { row in
                MediaSourceRoot(
                    id: row["id"],
                    volumeID: row["volume_id"],
                    volumeName: row["volume_name"],
                    relativePath: row["relative_path"],
                    displayName: row["root_name"],
                    includingSubfolders: row["including_subfolders"],
                    lastSuccessfulScanAt: (row["last_successful_scan_at"] as Double?)
                        .map(Date.init(timeIntervalSince1970:)),
                    isOnline: mountedVolumeIDs.contains(row["volume_id"])
                )
            }
    }

    private static func fetchLibraryItems(
        in db: Database,
        sourceRootID: Int64? = nil
    ) throws -> [MediaLibraryItem] {
        let rows: [Row]
        if let sourceRootID {
            rows = try Row.fetchAll(db, sql: """
                WITH ambiguous_identities AS (
                    SELECT volume_id, file_number FROM media_files
                    WHERE file_number IS NOT NULL
                    GROUP BY volume_id, file_number HAVING COUNT(*) > 1
                )
                SELECT media_files.id, media_source_files.source_root_id, media_files.volume_id,
                       media_files.relative_path, media_files.byte_count, media_files.content_revision,
                       media_source_files.is_present, media_file_preferences.is_favorite,
                       media_file_preferences.is_watched, media_file_preferences.manual_category,
                       ambiguous_identities.file_number IS NOT NULL AS history_conflict,
                       CASE WHEN ambiguous_identities.file_number IS NULL
                            THEN playback_history.position END AS position,
                       CASE WHEN ambiguous_identities.file_number IS NULL
                            THEN playback_history.updated_at END AS updated_at,
                       media_source_files.added_at
                FROM media_source_files
                JOIN media_files ON media_files.id = media_source_files.media_file_id
                LEFT JOIN media_file_preferences ON media_file_preferences.media_file_id = media_files.id
                LEFT JOIN playback_history ON playback_history.media_file_id = media_files.id
                LEFT JOIN ambiguous_identities ON ambiguous_identities.volume_id = media_files.volume_id
                    AND ambiguous_identities.file_number = media_files.file_number
                WHERE media_source_files.source_root_id = ?
                ORDER BY media_files.relative_path COLLATE NOCASE
                """, arguments: [sourceRootID])
        } else {
            rows = try Row.fetchAll(db, sql: """
                WITH ambiguous_identities AS (
                    SELECT volume_id, file_number FROM media_files
                    WHERE file_number IS NOT NULL
                    GROUP BY volume_id, file_number HAVING COUNT(*) > 1
                )
                SELECT media_files.id, media_source_files.source_root_id, media_files.volume_id,
                       media_files.relative_path, media_files.byte_count, media_files.content_revision,
                       media_source_files.is_present, media_file_preferences.is_favorite,
                       media_file_preferences.is_watched, media_file_preferences.manual_category,
                       ambiguous_identities.file_number IS NOT NULL AS history_conflict,
                       CASE WHEN ambiguous_identities.file_number IS NULL
                            THEN playback_history.position END AS position,
                       CASE WHEN ambiguous_identities.file_number IS NULL
                            THEN playback_history.updated_at END AS updated_at,
                       media_source_files.added_at
                FROM media_source_files
                JOIN media_files ON media_files.id = media_source_files.media_file_id
                LEFT JOIN media_file_preferences ON media_file_preferences.media_file_id = media_files.id
                LEFT JOIN playback_history ON playback_history.media_file_id = media_files.id
                LEFT JOIN ambiguous_identities ON ambiguous_identities.volume_id = media_files.volume_id
                    AND ambiguous_identities.file_number = media_files.file_number
                ORDER BY media_source_files.source_root_id, media_files.relative_path COLLATE NOCASE
                """)
        }
        return rows.map(Self.makeLibraryItem)
    }

    private static func fetchLibraryDirectories(
        in db: Database,
        sourceRootID: Int64? = nil
    ) throws -> [MediaLibraryDirectory] {
        let rows: [Row]
        if let sourceRootID {
            rows = try Row.fetchAll(db, sql: """
                SELECT source_root_id, relative_path, display_name
                FROM media_source_directories
                WHERE source_root_id = ? AND is_present = 1
                ORDER BY relative_path COLLATE NOCASE
                """, arguments: [sourceRootID])
        } else {
            rows = try Row.fetchAll(db, sql: """
                SELECT source_root_id, relative_path, display_name
                FROM media_source_directories
                WHERE is_present = 1
                ORDER BY source_root_id, relative_path COLLATE NOCASE
                """)
        }
        return rows.map { row in
            MediaLibraryDirectory(
                sourceRootID: row["source_root_id"],
                relativePath: row["relative_path"],
                displayName: row["display_name"]
            )
        }
    }

    private static func makeLibraryItem(from row: Row) -> MediaLibraryItem {
        let relativePath: String = row["relative_path"]
        /** 已持久化的卷相对路径按 POSIX 分隔符取名，不构造会解析当前工作目录的文件 URL。 */
        let nameStart = relativePath.lastIndex(of: "/").map { relativePath.index(after: $0) }
            ?? relativePath.startIndex
        return MediaLibraryItem(
            id: row["id"],
            sourceRootID: row["source_root_id"],
            volumeID: row["volume_id"],
            relativePath: relativePath,
            displayName: String(relativePath[nameStart...]),
            byteCount: row["byte_count"],
            contentRevision: row["content_revision"],
            isPresent: row["is_present"],
            isFavorite: row["is_favorite"] ?? false,
            isWatched: row["is_watched"] ?? false,
            hasPlaybackHistoryConflict: row["history_conflict"] ?? false,
            manualCategory: (row["manual_category"] as String?).flatMap(MediaManualCategory.init(rawValue:)),
            playbackPosition: row["position"] ?? 0,
            lastPlayedAt: (row["updated_at"] as Double?).map(Date.init(timeIntervalSince1970:)),
            addedAt: Date(timeIntervalSince1970: row["added_at"])
        )
    }

    func setFavorite(_ isFavorite: Bool, for mediaFileID: Int64) async throws {
        try await setPreference("is_favorite", value: isFavorite, for: mediaFileID)
    }

    func setWatched(_ isWatched: Bool, for mediaFileID: Int64) async throws {
        try await setPreference("is_watched", value: isWatched, for: mediaFileID)
    }

    @discardableResult
    func toggleFavorite(for mediaFileID: Int64) async throws -> Bool {
        try await togglePreference("is_favorite", for: mediaFileID)
    }

    @discardableResult
    func toggleWatched(for mediaFileID: Int64) async throws -> Bool {
        try await togglePreference("is_watched", for: mediaFileID)
    }

    func setManualCategory(_ category: MediaManualCategory?, for mediaFileID: Int64) async throws {
        try await database.write { db in
            guard try Int64.fetchOne(db, sql: "SELECT id FROM media_files WHERE id = ?", arguments: [mediaFileID]) != nil else {
                throw PlaybackHistoryError.missingMediaFile(mediaFileID)
            }
            try db.execute(
                sql: """
                INSERT INTO media_file_preferences (media_file_id, manual_category) VALUES (?, ?)
                ON CONFLICT(media_file_id) DO UPDATE SET manual_category = excluded.manual_category
                """,
                arguments: [mediaFileID, category?.rawValue]
            )
        }
    }

    private func setPreference(_ column: String, value: Bool, for mediaFileID: Int64) async throws {
        guard column == "is_favorite" || column == "is_watched" else {
            throw PlaybackHistoryError.invalidLibraryPreference
        }
        try await database.write { db in
            guard try Int64.fetchOne(db, sql: "SELECT id FROM media_files WHERE id = ?", arguments: [mediaFileID]) != nil else {
                throw PlaybackHistoryError.missingMediaFile(mediaFileID)
            }
            try db.execute(
                sql: """
                INSERT INTO media_file_preferences (media_file_id, \(column)) VALUES (?, ?)
                ON CONFLICT(media_file_id) DO UPDATE SET \(column) = excluded.\(column)
                """,
                arguments: [mediaFileID, value]
            )
        }
    }

    private func togglePreference(_ column: String, for mediaFileID: Int64) async throws -> Bool {
        guard column == "is_favorite" || column == "is_watched" else {
            throw PlaybackHistoryError.invalidLibraryPreference
        }
        return try await database.write { db in
            guard try Int64.fetchOne(db, sql: "SELECT id FROM media_files WHERE id = ?",
                                     arguments: [mediaFileID]) != nil else {
                throw PlaybackHistoryError.missingMediaFile(mediaFileID)
            }
            let currentValue = try Bool.fetchOne(
                db,
                sql: "SELECT \(column) FROM media_file_preferences WHERE media_file_id = ?",
                arguments: [mediaFileID]
            ) ?? false
            let nextValue = !currentValue
            try db.execute(
                sql: """
                INSERT INTO media_file_preferences (media_file_id, \(column)) VALUES (?, ?)
                ON CONFLICT(media_file_id) DO UPDATE SET \(column) = excluded.\(column)
                """,
                arguments: [mediaFileID, nextValue]
            )
            return nextValue
        }
    }

    func save(
        for binding: PlaybackHistoryBinding,
        position: Double,
        audioTrackID: Int? = nil,
        subtitleTrackID: Int? = nil,
        volume: Double,
        updatedAt: Date = .now
    ) async throws {
        guard position.isFinite, position >= 0 else {
            throw PlaybackHistoryError.invalidPosition
        }
        guard volume.isFinite, (0...100).contains(volume) else {
            throw PlaybackHistoryError.invalidVolume
        }
        let url = binding.url
        let identity = try Self.identity(for: url)
        let expected = binding.identity
        guard identity.volumeID == expected.volumeID,
              identity.fileNumber == expected.fileNumber,
              identity.contentRevision == expected.contentRevision,
              identity.contentFingerprint == expected.contentFingerprint else {
            throw PlaybackHistoryError.mediaFileChanged
        }
        try await database.write { db in
            // A scan may already have recorded another version while this write
            // waited for SQLite. Never let an older capture replace that record.
            if let indexed = try Self.existingFile(volumeID: expected.volumeID,
                                                   resourceID: expected.resourceID, in: db) {
                let revision: String = indexed["content_revision"]
                let fingerprint: String? = indexed["content_fingerprint"]
                guard revision == expected.contentRevision else {
                    throw PlaybackHistoryError.mediaFileChanged
                }
                if let fingerprint, fingerprint != expected.contentFingerprint {
                    throw PlaybackHistoryError.mediaFileChanged
                }
            }
            let mediaFileID = try Self.resolve(identity, in: db)
            try Self.migrateLegacyHistory(for: url, mediaFileID: mediaFileID, in: db)
            if try Self.isHistoryExcluded(volumeID: identity.volumeID,
                                          relativePath: identity.relativePath, in: db) {
                try db.execute(sql: "DELETE FROM playback_history WHERE media_file_id = ?", arguments: [mediaFileID])
                return
            }
            try db.execute(
                sql: """
                INSERT INTO playback_history
                    (media_file_id, position, audio_track_id, subtitle_track_id, volume, updated_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(media_file_id) DO UPDATE SET
                    position = excluded.position,
                    audio_track_id = excluded.audio_track_id,
                    subtitle_track_id = excluded.subtitle_track_id,
                    volume = excluded.volume,
                    updated_at = excluded.updated_at
                """,
                arguments: [
                    mediaFileID,
                    position,
                    audioTrackID,
                    subtitleTrackID,
                    volume,
                    updatedAt.timeIntervalSince1970
                ]
            )
        }
    }

    func clearAll() async throws {
        try migrationBackup?.discard()
        try await database.write { db in
            try db.execute(sql: "DELETE FROM playback_history")
            try db.execute(sql: "DELETE FROM playback_history_legacy")
            try db.execute(sql: "DELETE FROM legacy_history_purges")
        }
    }

    func clearLibraryRecords() async throws {
        try migrationBackup?.discard()
        try await database.write { db in
            try db.execute(sql: "DELETE FROM media_sources")
            try db.execute(sql: "DELETE FROM playback_history_legacy")
            try db.execute(sql: "DELETE FROM legacy_history_purges")
        }
        failedScanFinalizations.removeAll()
    }

    func exportArchive(settings: MediaLibraryArchive.Settings) async throws -> Data {
        try await database.read { db in
            let roots = try Row.fetchAll(db, sql: """
                SELECT volume_id, relative_path, display_name, including_subfolders
                FROM media_source_roots ORDER BY volume_id, relative_path
                """)
            let rootsByVolume = Dictionary(grouping: roots) { $0["volume_id"] as String }
            let sources = try Row.fetchAll(db, sql: """
                SELECT volume_id, display_name FROM media_sources ORDER BY volume_id
                """).map { row in
                    let volumeID: String = row["volume_id"]
                    let sourceRoots = (rootsByVolume[volumeID] ?? []).map { root in
                        MediaLibraryArchive.Root(relativePath: root["relative_path"],
                            displayName: root["display_name"], includingSubfolders: root["including_subfolders"])
                    }
                    return MediaLibraryArchive.Source(volumeID: volumeID,
                        displayName: row["display_name"], roots: sourceRoots)
                }
            let memberships = try Row.fetchAll(db, sql: """
                SELECT media_source_files.media_file_id, media_source_roots.relative_path,
                       media_source_files.is_present
                FROM media_source_files JOIN media_source_roots
                  ON media_source_roots.id = media_source_files.source_root_id
                ORDER BY media_source_roots.volume_id, media_source_roots.relative_path
                """)
            let membershipsByFile = Dictionary(grouping: memberships) { $0["media_file_id"] as Int64 }
            let fileRows = try Row.fetchAll(db, sql: """
                SELECT media_files.id, media_files.volume_id, media_files.resource_id,
                       media_files.content_revision,
                       COALESCE(media_files.content_fingerprint, media_files.legacy_content_fingerprint) AS content_fingerprint,
                       media_files.relative_path,
                       media_files.byte_count, media_files.modified_at,
                       media_file_preferences.is_favorite, media_file_preferences.is_watched,
                       media_file_preferences.manual_category, playback_history.position,
                       playback_history.audio_track_id, playback_history.subtitle_track_id,
                       playback_history.volume AS saved_volume, playback_history.updated_at
                FROM media_files
                LEFT JOIN media_file_preferences ON media_file_preferences.media_file_id = media_files.id
                LEFT JOIN playback_history ON playback_history.media_file_id = media_files.id
                ORDER BY media_files.volume_id, media_files.relative_path COLLATE NOCASE
                """)
            let archiveSchemaVersion = fileRows.allSatisfy { ($0["content_fingerprint"] as String?) != nil } ? 2 : 1
            let files = fileRows.map { row in
                let fileID: Int64 = row["id"]
                let volumeID: String = row["volume_id"]
                let resourceID: String = row["resource_id"]
                let contentFingerprint: String? = row["content_fingerprint"]
                let position = row["position"] as Double?
                let history: MediaLibraryArchive.History?
                if let position {
                    history = MediaLibraryArchive.History(position: position,
                        audioTrackID: row["audio_track_id"], subtitleTrackID: row["subtitle_track_id"],
                        volume: row["saved_volume"],
                        updatedAt: Date(timeIntervalSince1970: row["updated_at"]))
                } else {
                    history = nil
                }
                return MediaLibraryArchive.File(
                    logicalID: archiveSchemaVersion == 2
                        ? "\(volumeID):\(resourceID):\(contentFingerprint ?? "")"
                        : "\(volumeID):\(resourceID)",
                    volumeID: volumeID, resourceID: resourceID,
                    contentRevision: row["content_revision"],
                    contentFingerprint: archiveSchemaVersion == 2 ? contentFingerprint : nil,
                    relativePath: row["relative_path"], byteCount: row["byte_count"],
                    modifiedAt: Date(timeIntervalSince1970: row["modified_at"]),
                    memberships: (membershipsByFile[fileID] ?? []).map {
                        MediaLibraryArchive.Membership(rootPath: $0["relative_path"], isPresent: $0["is_present"])
                    },
                    isFavorite: row["is_favorite"] ?? false, isWatched: row["is_watched"] ?? false,
                    manualCategory: (row["manual_category"] as String?).flatMap(MediaManualCategory.init(rawValue:)),
                    history: history
                )
            }
            let privateFolders = try Row.fetchAll(db, sql: """
                SELECT volume_id, relative_path, display_name FROM private_media_roots
                ORDER BY volume_id, relative_path
                """).map {
                    MediaLibraryArchive.PrivateFolder(volumeID: $0["volume_id"],
                        relativePath: $0["relative_path"], displayName: $0["display_name"])
                }
            let archive = MediaLibraryArchive(schemaVersion: archiveSchemaVersion, exportedAt: .now, sources: sources,
                files: files, privateFolders: privateFolders, settings: settings)
            return try MediaLibraryArchive.encodedData(for: archive)
        }
    }

    func previewArchiveImport(_ data: Data) async throws -> MediaLibraryImportPreview {
        let archive = try Self.decodeArchive(data)
        return try await database.read { db in
            let matches = try Self.matchArchiveFiles(archive, in: db)
            var replacedCount = 0
            for match in matches {
                let hasExistingData = try Int.fetchOne(db, sql: """
                    SELECT 1 FROM media_file_preferences
                    WHERE media_file_id = ? AND
                      (is_favorite = 1 OR is_watched = 1 OR manual_category IS NOT NULL)
                    UNION ALL
                    SELECT 1 FROM playback_history WHERE media_file_id = ?
                    LIMIT 1
                    """, arguments: [match.mediaFileID, match.mediaFileID]) != nil
                if hasExistingData { replacedCount += 1 }
            }
            return MediaLibraryImportPreview(schemaVersion: archive.schemaVersion,
                fileCount: archive.files.count, matchedFileCount: matches.count,
                unmatchedFileCount: archive.files.count - matches.count,
                replacedRecordCount: replacedCount, settings: archive.settings)
        }
    }

    func importArchive(_ data: Data) async throws -> MediaLibraryImportResult {
        let archive = try Self.decodeArchive(data)
        if !archive.privateFolders.isEmpty { try migrationBackup?.discard() }
        return try await database.write { db in
            let matches = try Self.matchArchiveFiles(archive, in: db)
            let now = Date.now.timeIntervalSince1970
            for source in archive.sources {
                try db.execute(sql: """
                    INSERT INTO media_sources (volume_id, display_name, updated_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(volume_id) DO UPDATE SET display_name = excluded.display_name,
                        updated_at = excluded.updated_at
                    """, arguments: [source.volumeID, source.displayName, now])
                for root in source.roots {
                    try db.execute(sql: """
                        INSERT INTO media_source_roots
                            (volume_id, relative_path, display_name, including_subfolders)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT(volume_id, relative_path) DO UPDATE SET
                            display_name = excluded.display_name,
                            including_subfolders = excluded.including_subfolders
                        """, arguments: [source.volumeID, root.relativePath,
                                          root.displayName, root.includingSubfolders])
                }
            }
            for folder in archive.privateFolders {
                try db.execute(sql: """
                    INSERT INTO private_media_roots (volume_id, relative_path, display_name)
                    VALUES (?, ?, ?)
                    ON CONFLICT(volume_id, relative_path) DO UPDATE SET display_name = excluded.display_name
                    """, arguments: [folder.volumeID, folder.relativePath, folder.displayName])
                try Self.purgeHistory(volumeID: folder.volumeID, relativePath: folder.relativePath, in: db)
            }
            var importScanIDs: [Int64: String] = [:]
            for match in matches {
                let file = match.file
                try db.execute(sql: """
                    INSERT INTO media_file_preferences
                        (media_file_id, is_favorite, is_watched, manual_category)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(media_file_id) DO UPDATE SET
                        is_favorite = excluded.is_favorite,
                        is_watched = excluded.is_watched,
                        manual_category = excluded.manual_category
                    """, arguments: [match.mediaFileID, file.isFavorite, file.isWatched,
                                      file.manualCategory?.rawValue])
                let excludesHistory = try Self.isHistoryExcluded(
                    volumeID: file.volumeID, relativePath: match.relativePath, in: db
                )
                if let history = file.history, !excludesHistory {
                    try db.execute(sql: """
                        INSERT INTO playback_history
                            (media_file_id, position, audio_track_id, subtitle_track_id, volume, updated_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(media_file_id) DO UPDATE SET
                            position = excluded.position,
                            audio_track_id = excluded.audio_track_id,
                            subtitle_track_id = excluded.subtitle_track_id,
                            volume = excluded.volume,
                            updated_at = excluded.updated_at
                        """, arguments: [match.mediaFileID, history.position, history.audioTrackID,
                                          history.subtitleTrackID, history.volume,
                                          history.updatedAt.timeIntervalSince1970])
                } else {
                    try db.execute(sql: "DELETE FROM playback_history WHERE media_file_id = ?",
                                   arguments: [match.mediaFileID])
                }
                for membership in file.memberships {
                    guard let sourceRootID = try Int64.fetchOne(db, sql: """
                        SELECT id FROM media_source_roots WHERE volume_id = ? AND relative_path = ?
                        """, arguments: [file.volumeID, membership.rootPath]) else { continue }
                    let scanID: String
                    if let existing = importScanIDs[sourceRootID] {
                        scanID = existing
                    } else {
                        scanID = UUID().uuidString
                        try db.execute(sql: """
                            INSERT INTO media_scan_runs
                                (id, source_root_id, started_at, completed_at, discovered_count,
                                 indexed_count, skipped_count, status)
                            VALUES (?, ?, ?, ?, 0, 0, 0, 'completed')
                            """, arguments: [scanID, sourceRootID, now, now])
                        importScanIDs[sourceRootID] = scanID
                    }
                    try db.execute(sql: """
                        INSERT INTO media_source_files
                            (source_root_id, media_file_id, last_seen_scan_id, is_present,
                             last_seen_at, added_at)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT(source_root_id, media_file_id) DO UPDATE SET
                            last_seen_scan_id = excluded.last_seen_scan_id,
                            is_present = excluded.is_present,
                            last_seen_at = excluded.last_seen_at
                        """, arguments: [sourceRootID, match.mediaFileID, scanID,
                                          membership.isPresent, now, now])
                }
            }
            return MediaLibraryImportResult(importedFileCount: matches.count,
                unmatchedFileCount: archive.files.count - matches.count, settings: archive.settings)
        }
    }

    private struct ArchiveMatch {
        let file: MediaLibraryArchive.File
        let mediaFileID: Int64
        let relativePath: String
    }

    private static func decodeArchive(_ data: Data) throws -> MediaLibraryArchive {
        guard data.count <= MediaLibraryArchive.maximumSize else { throw MediaLibraryArchiveError.tooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: MediaLibraryArchive
        do {
            archive = try decoder.decode(MediaLibraryArchive.self, from: data)
        } catch {
            throw MediaLibraryArchiveError.invalidContent(error.localizedDescription)
        }
        guard (1...2).contains(archive.schemaVersion) else {
            throw MediaLibraryArchiveError.unsupportedSchema(archive.schemaVersion)
        }
        let validSpeeds = [0.5, 0.75, 1, 1.25, 1.5, 2]
        guard validSpeeds.contains(archive.settings.defaultSpeed),
              archive.settings.defaultSubtitleDelay.isFinite,
              (-30...30).contains(archive.settings.defaultSubtitleDelay) else {
            throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveInvalidSettings"))
        }
        for source in archive.sources {
            guard !source.volumeID.isEmpty else {
                throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveMissingVolume"))
            }
            var rootPaths = Set<String>()
            for root in source.roots {
                guard Self.isValidRelativePath(root.relativePath, allowingEmpty: true),
                      rootPaths.insert(root.relativePath).inserted else {
                    throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveInvalidSourcePath"))
                }
            }
        }
        for folder in archive.privateFolders where
            folder.volumeID.isEmpty || !Self.isValidRelativePath(folder.relativePath, allowingEmpty: true) {
            throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveInvalidPrivatePath"))
        }
        var logicalIDs = Set<String>()
        for file in archive.files {
            let expectedLogicalID: String
            if archive.schemaVersion == 1 {
                expectedLogicalID = "\(file.volumeID):\(file.resourceID)"
            } else {
                expectedLogicalID = "\(file.volumeID):\(file.resourceID):\(file.contentFingerprint ?? "")"
            }
            guard !file.volumeID.isEmpty, !file.resourceID.isEmpty,
                  file.logicalID == expectedLogicalID,
                  Self.isValidRelativePath(file.relativePath, allowingEmpty: false),
                  file.byteCount >= 0,
                  logicalIDs.insert(file.logicalID).inserted else {
                throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveInvalidIdentity"))
            }
            if archive.schemaVersion == 2,
               !(file.contentFingerprint.map(Self.isValidContentFingerprint) ?? false) {
                throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveMissingFingerprint"))
            }
            for membership in file.memberships where
                !Self.isValidRelativePath(membership.rootPath, allowingEmpty: true) {
                throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveInvalidMembership"))
            }
            if let history = file.history {
                guard history.position.isFinite, history.position >= 0,
                      history.volume.isFinite, (0...100).contains(history.volume) else {
                    throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveInvalidCheckpoint"))
                }
            }
        }
        return archive
    }

    private static func isValidRelativePath(_ path: String, allowingEmpty: Bool) -> Bool {
        if path.isEmpty { return allowingEmpty }
        guard !path.hasPrefix("/"), !path.hasSuffix("/"), !path.contains("\0") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func isValidContentFingerprint(_ value: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == 64 else { return false }
        return bytes.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private static func matchArchiveFiles(_ archive: MediaLibraryArchive, in db: Database) throws -> [ArchiveMatch] {
        var matches: [ArchiveMatch] = []
        var usedFileIDs = Set<Int64>()
        for file in archive.files {
            let exact = try existingFile(volumeID: file.volumeID, resourceID: file.resourceID, in: db)
            let candidate: Row?
            if let exact,
               Self.archiveFile(file, matches: exact, schemaVersion: archive.schemaVersion) {
                candidate = exact
            } else {
                if archive.schemaVersion == 2, let fingerprint = file.contentFingerprint {
                    candidate = try Row.fetchOne(db, sql: """
                        SELECT id, content_revision, content_fingerprint, legacy_content_fingerprint, relative_path FROM media_files
                        WHERE volume_id = ? AND relative_path = ? AND byte_count = ?
                          AND content_revision = ? AND (content_fingerprint = ? OR legacy_content_fingerprint = ?)
                        """, arguments: [file.volumeID, file.relativePath, file.byteCount,
                                         file.contentRevision, fingerprint, fingerprint])
                } else {
                    candidate = try Row.fetchOne(db, sql: """
                        SELECT id, content_revision, content_fingerprint, legacy_content_fingerprint, relative_path FROM media_files
                        WHERE volume_id = ? AND relative_path = ? AND byte_count = ? AND content_revision = ?
                        """, arguments: [file.volumeID, file.relativePath,
                                         file.byteCount, file.contentRevision])
                }
            }
            guard let candidate else { continue }
            let mediaFileID: Int64 = candidate["id"]
            let relativePath: String = candidate["relative_path"]
            guard usedFileIDs.insert(mediaFileID).inserted else {
                throw MediaLibraryArchiveError.invalidContent(String(localized: "error.archiveConflictingFiles"))
            }
            matches.append(ArchiveMatch(file: file, mediaFileID: mediaFileID,
                                        relativePath: relativePath))
        }
        return matches
    }

    private static func archiveFile(_ file: MediaLibraryArchive.File, matches row: Row,
                                    schemaVersion: Int) -> Bool {
        guard (row["content_revision"] as String) == file.contentRevision else { return false }
        guard schemaVersion == 2 else { return true }
        return (row["content_fingerprint"] as String?) == file.contentFingerprint
            || (row["legacy_content_fingerprint"] as String?) == file.contentFingerprint
    }

    func setHistoryExcludedFolder(_ folder: URL, excluded: Bool) async throws {
        let hasScopedAccess = folder.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess { folder.stopAccessingSecurityScopedResource() }
        }
        let source = try Self.sourceIdentity(for: folder)
        if excluded { try migrationBackup?.discard() }
        try await database.write { db in
            if excluded {
                try db.execute(
                    sql: """
                    INSERT INTO private_media_roots (volume_id, relative_path, display_name)
                    VALUES (?, ?, ?)
                    ON CONFLICT(volume_id, relative_path) DO UPDATE SET display_name = excluded.display_name
                    """,
                    arguments: [source.volumeID, source.relativePath, source.displayName]
                )
                try Self.purgeHistory(volumeID: source.volumeID, relativePath: source.relativePath, in: db)
                let folderPath = folder.standardizedFileURL.resolvingSymlinksInPath().path
                try db.execute(sql: """
                    DELETE FROM playback_history_legacy
                    WHERE file_path = ? OR substr(file_path, 1, length(?) + 1) = ? || '/'
                    """, arguments: [folderPath, folderPath, folderPath])
                try db.execute(sql: """
                    DELETE FROM legacy_history_purges WHERE NOT EXISTS (SELECT 1 FROM playback_history_legacy)
                    """)
            } else {
                try db.execute(sql: "DELETE FROM private_media_roots WHERE volume_id = ? AND relative_path = ?",
                               arguments: [source.volumeID, source.relativePath])
            }
        }
    }

    func historyExcludedFolders() async throws -> [HistoryExcludedFolder] {
        try await database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT private_media_roots.volume_id, media_sources.display_name AS volume_name,
                       private_media_roots.relative_path, private_media_roots.display_name
                FROM private_media_roots
                LEFT JOIN media_sources USING (volume_id)
                ORDER BY volume_name COLLATE NOCASE, relative_path COLLATE NOCASE
                """).map { row in
                    HistoryExcludedFolder(volumeID: row["volume_id"],
                                          volumeName: row["volume_name"] ?? String(localized: "library.unknownVolume"),
                                          relativePath: row["relative_path"],
                                          displayName: row["display_name"])
                }
        }
    }

    func removeHistoryExcludedFolder(_ folder: HistoryExcludedFolder) async throws {
        try await database.write { db in
            try db.execute(sql: "DELETE FROM private_media_roots WHERE volume_id = ? AND relative_path = ?",
                           arguments: [folder.volumeID, folder.relativePath])
        }
    }

    /** 删除事实独立于当前隐私开关；未解析的旧路径记录必须在以后解析身份时继续遵守。 */
    private static func purgeHistory(volumeID: String, relativePath: String, in db: Database) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO legacy_history_purges (volume_id, relative_path)
            SELECT ?, ? WHERE EXISTS (SELECT 1 FROM playback_history_legacy)
            """, arguments: [volumeID, relativePath])
        try db.execute(sql: """
            DELETE FROM playback_history
            WHERE media_file_id IN (
                SELECT id FROM media_files
                WHERE volume_id = ? AND (? = '' OR relative_path = ? OR
                    substr(relative_path, 1, length(?) + 1) = ? || '/')
            )
            """, arguments: [volumeID, relativePath, relativePath, relativePath, relativePath])
    }

    private static func isHistoryExcluded(volumeID: String, relativePath: String, in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: """
            SELECT 1 FROM private_media_roots
            WHERE volume_id = ? AND (relative_path = '' OR relative_path = ? OR
                substr(?, 1, length(relative_path) + 1) = relative_path || '/')
            LIMIT 1
            """, arguments: [volumeID, relativePath, relativePath]) != nil
    }

    /** 卷 UUID 已确定设备；只解析旧设备号序列化和新格式中的卷内编号。 */
    private static func fileNumber(in resourceID: String) -> String? {
        let parts = resourceID.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "inode" || Int32(parts[0]) != nil,
              let number = UInt64(parts[1]), String(number) == parts[1] else { return nil }
        return String(number)
    }

    private static func existingFile(volumeID: String, resourceID: String, in db: Database) throws -> Row? {
        let rows: [Row]
        if let number = fileNumber(in: resourceID) {
            rows = try Row.fetchAll(db, sql: """
                SELECT id, content_revision, content_fingerprint, legacy_content_fingerprint, relative_path
                FROM media_files WHERE volume_id = ? AND file_number = ? LIMIT 2
                """, arguments: [volumeID, number])
        } else {
            rows = try Row.fetchAll(db, sql: """
                SELECT id, content_revision, content_fingerprint, legacy_content_fingerprint, relative_path
                FROM media_files WHERE volume_id = ? AND resource_id = ? LIMIT 2
                """, arguments: [volumeID, resourceID])
        }
        // Conflicting historical rows have user facts; never choose or merge them implicitly.
        guard rows.count < 2 else { throw PlaybackHistoryError.ambiguousMediaIdentity }
        return rows.first
    }

    private static func resolve(_ identity: MediaFileIdentity, in db: Database) throws -> Int64 {
        try db.execute(
            sql: """
            INSERT INTO media_sources (volume_id, display_name, updated_at)
            VALUES (?, ?, ?)
            ON CONFLICT(volume_id) DO UPDATE SET
                display_name = excluded.display_name,
                updated_at = excluded.updated_at
            """,
            arguments: [identity.volumeID, identity.volumeName, Date.now.timeIntervalSince1970]
        )

        if let existing = try existingFile(volumeID: identity.volumeID, resourceID: identity.resourceID, in: db) {
            let mediaFileID: Int64 = existing["id"]
            let oldRevision: String = existing["content_revision"]
            let oldFingerprint: String? = existing["content_fingerprint"]
            let legacyFingerprint: String? = existing["legacy_content_fingerprint"]
            let changedFingerprint: Bool
            if let oldFingerprint {
                changedFingerprint = oldFingerprint != identity.contentFingerprint
            } else if let legacyFingerprint {
                changedFingerprint = legacyFingerprint != identity.legacyContentFingerprint
            } else {
                changedFingerprint = false
            }
            if oldRevision != identity.contentRevision || changedFingerprint {
                return try Self.replaceChangedFile(existingID: mediaFileID, with: identity, in: db)
            }
            try db.execute(
                sql: """
                UPDATE media_files
                SET content_revision = ?, content_fingerprint = ?, legacy_content_fingerprint = ?,
                    relative_path = ?, byte_count = ?, modified_at = ?
                WHERE id = ?
                """,
                arguments: [
                    identity.contentRevision,
                    identity.contentFingerprint,
                    identity.legacyContentFingerprint,
                    identity.relativePath,
                    identity.byteCount,
                    identity.modifiedAt.timeIntervalSince1970,
                    mediaFileID
                ]
            )
            return mediaFileID
        }

        return try insert(identity, in: db)
    }

    private static func replaceChangedFile(
        existingID: Int64,
        with identity: MediaFileIdentity,
        in db: Database
    ) throws -> Int64 {
        struct Membership {
            let sourceRootID: Int64
            let lastSeenScanID: String
            let isPresent: Bool
            let lastSeenAt: Double
            let addedAt: Double
        }

        let memberships = try Row.fetchAll(db, sql: """
            SELECT source_root_id, last_seen_scan_id, is_present, last_seen_at, added_at
            FROM media_source_files WHERE media_file_id = ?
            """, arguments: [existingID]).map { row in
                Membership(sourceRootID: row["source_root_id"],
                           lastSeenScanID: row["last_seen_scan_id"], isPresent: row["is_present"],
                           lastSeenAt: row["last_seen_at"], addedAt: row["added_at"])
            }
        try db.execute(sql: "DELETE FROM media_files WHERE id = ?", arguments: [existingID])
        let newID = try insert(identity, in: db)
        for membership in memberships {
            try db.execute(sql: """
                INSERT INTO media_source_files
                    (source_root_id, media_file_id, last_seen_scan_id, is_present, last_seen_at, added_at)
                VALUES (?, ?, ?, ?, ?, ?)
                """, arguments: [membership.sourceRootID, newID, membership.lastSeenScanID,
                                 membership.isPresent, membership.lastSeenAt, membership.addedAt])
        }
        return newID
    }

    private static func insert(_ identity: MediaFileIdentity, in db: Database) throws -> Int64 {
        try db.execute(
            sql: """
            INSERT INTO media_files
                (volume_id, resource_id, file_number, content_revision, content_fingerprint, legacy_content_fingerprint,
                 relative_path, byte_count, modified_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [identity.volumeID, identity.resourceID, identity.fileNumber, identity.contentRevision,
                        identity.contentFingerprint, identity.legacyContentFingerprint, identity.relativePath, identity.byteCount,
                        identity.modifiedAt.timeIntervalSince1970]
        )
        return db.lastInsertedRowID
    }

    /// Moves an exact-path v0.0 checkpoint on first access; path alone cannot safely match a rename.
    private static func migrateLegacyHistory(for url: URL, mediaFileID: Int64, in db: Database) throws {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard try Int.fetchOne(db, sql: "SELECT 1 FROM playback_history_legacy WHERE file_path = ?",
                               arguments: [path]) != nil else { return }
        try db.execute(
            sql: """
            INSERT OR IGNORE INTO playback_history
                (media_file_id, position, audio_track_id, subtitle_track_id, volume, updated_at)
            SELECT ?, position, audio_track_id, subtitle_track_id, volume, updated_at
            FROM playback_history_legacy WHERE file_path = ?
                AND NOT EXISTS (
                    SELECT 1 FROM (
                        SELECT volume_id, relative_path FROM private_media_roots
                        UNION ALL
                        SELECT volume_id, relative_path FROM legacy_history_purges
                    ) AS excluded
                    JOIN media_files AS file ON file.id = ? AND file.volume_id = excluded.volume_id
                    WHERE excluded.relative_path = '' OR file.relative_path = excluded.relative_path
                        OR substr(file.relative_path, 1, length(excluded.relative_path) + 1)
                            = excluded.relative_path || '/'
                )
            """,
            arguments: [mediaFileID, path, mediaFileID]
        )
        try db.execute(sql: "DELETE FROM playback_history_legacy WHERE file_path = ?", arguments: [path])
        try db.execute(sql: """
            DELETE FROM legacy_history_purges WHERE NOT EXISTS (SELECT 1 FROM playback_history_legacy)
            """)
    }

    private static func identity(for url: URL) throws -> MediaFileIdentity {
        let resolvedURL = url.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [
            .volumeUUIDStringKey,
            .volumeURLKey,
            .volumeNameKey,
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let values: URLResourceValues
        do {
            values = try resolvedURL.resourceValues(forKeys: keys)
        } catch {
            if Self.isMissingMediaFile(error) {
                throw PlaybackHistoryError.mediaFileUnavailable(url.path)
            }
            throw PlaybackHistoryError.identityUnavailable(url.path, underlying: error.localizedDescription)
        }
        guard values.isRegularFile == true,
              let volumeID = values.volumeUUIDString,
              let volumeURL = values.volume,
              let byteCount = values.fileSize,
              let modifiedAt = values.contentModificationDate else {
            throw PlaybackHistoryError.identityUnavailable(url.path, underlying: String(localized: "error.fileMetadataUnavailable"))
        }

        var metadata = stat()
        let statResult = resolvedURL.path.withCString { stat($0, &metadata) }
        guard statResult == 0 else {
            if errno == ENOENT {
                throw PlaybackHistoryError.mediaFileUnavailable(url.path)
            }
            throw PlaybackHistoryError.identityUnavailable(
                url.path,
                underlying: String(cString: strerror(errno))
            )
        }

        let rootPath = volumeURL.standardizedFileURL.path
        let filePath = resolvedURL.path
        let relativePath: String
        if rootPath == "/" {
            relativePath = String(filePath.dropFirst())
        } else if filePath.hasPrefix(rootPath + "/") {
            relativePath = String(filePath.dropFirst(rootPath.count + 1))
        } else {
            throw PlaybackHistoryError.identityUnavailable(url.path, underlying: String(localized: "error.fileOutsideVolume"))
        }

        let modified = metadata.st_mtimespec
        let revision = "\(byteCount):\(modified.tv_sec).\(modified.tv_nsec)"
        let fingerprints = try Self.sampleFingerprint(for: resolvedURL, expected: metadata, byteCount: Int64(byteCount))
        return MediaFileIdentity(
            volumeID: volumeID,
            fileNumber: String(metadata.st_ino),
            contentRevision: revision,
            contentFingerprint: fingerprints.current,
            legacyContentFingerprint: fingerprints.legacy,
            relativePath: relativePath,
            volumeName: values.volumeName ?? volumeURL.lastPathComponent,
            byteCount: Int64(byteCount),
            modifiedAt: modifiedAt
        )
    }

    private static func isMissingMediaFile(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOENT) { return true }
        return error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError
    }

    private static func sampleFingerprint(for url: URL, expected: stat, byteCount: Int64) throws
        -> (current: String, legacy: String?) {
        let file: FileHandle
        do {
            file = try FileHandle(forReadingFrom: url)
        } catch {
            if Self.isMissingMediaFile(error) {
                throw PlaybackHistoryError.mediaFileUnavailable(url.path)
            }
            throw PlaybackHistoryError.identityUnavailable(url.path, underlying: error.localizedDescription)
        }
        defer { try? file.close() }

        func verifyUnchanged() throws {
            var current = stat()
            guard fstat(file.fileDescriptor, &current) == 0,
                  current.st_dev == expected.st_dev,
                  current.st_ino == expected.st_ino,
                  current.st_size == expected.st_size,
                  current.st_mtimespec.tv_sec == expected.st_mtimespec.tv_sec,
                  current.st_mtimespec.tv_nsec == expected.st_mtimespec.tv_nsec,
                  current.st_ctimespec.tv_sec == expected.st_ctimespec.tv_sec,
                  current.st_ctimespec.tv_nsec == expected.st_ctimespec.tv_nsec else {
                throw PlaybackHistoryError.identityUnavailable(
                    url.path,
                    underlying: "The file changed while its content fingerprint was being sampled."
                )
            }
        }

        try verifyUnchanged()
        let blockSize = Int64(16 * 1_024)
        let sampleLength: Int64
        let offsets: [Int64]
        if byteCount <= 5 * blockSize {
            sampleLength = byteCount
            offsets = [0]
        } else {
            sampleLength = blockSize
            let lastOffset = byteCount - sampleLength
            offsets = (0...4).map { lastOffset * Int64($0) / 4 }
        }

        var legacyFingerprint: String?
        var hasher = SHA256()
        hasher.update(data: Data("size:\(byteCount);".utf8))
        for offset in offsets {
            try file.seek(toOffset: UInt64(offset))
            let sample: Data
            do {
                sample = try file.read(upToCount: Int(sampleLength)) ?? Data()
            } catch {
                throw PlaybackHistoryError.identityUnavailable(url.path, underlying: error.localizedDescription)
            }
            guard sample.count == Int(sampleLength) else {
                throw PlaybackHistoryError.identityUnavailable(
                    url.path,
                    underlying: "The file ended before its content fingerprint could be sampled."
                )
            }
            hasher.update(data: Data("offset:\(offset);".utf8))
            hasher.update(data: sample)
            if byteCount > blockSize, byteCount <= 5 * blockSize {
                // Preserve the old prefix-only digest for database and archive upgrades.
                var legacyHasher = SHA256()
                legacyHasher.update(data: Data("size:\(byteCount);offset:0;".utf8))
                legacyHasher.update(data: sample.prefix(Int(blockSize)))
                legacyFingerprint = legacyHasher.finalize().map { String(format: "%02x", $0) }.joined()
            }
        }
        try verifyUnchanged()
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), legacyFingerprint)
    }

    private static func sourceIdentity(for folder: URL) throws -> (volumeID: String, volumeName: String, relativePath: String, displayName: String) {
        let resolvedURL = folder.standardizedFileURL.resolvingSymlinksInPath()
        let values: URLResourceValues
        do {
            values = try resolvedURL.resourceValues(forKeys: [.volumeUUIDStringKey, .volumeURLKey, .volumeNameKey, .isDirectoryKey])
        } catch {
            throw PlaybackHistoryError.identityUnavailable(folder.path, underlying: error.localizedDescription)
        }
        guard values.isDirectory == true, let volumeID = values.volumeUUIDString, !volumeID.isEmpty,
              let volumeURL = values.volume else {
            throw PlaybackHistoryError.identityUnavailable(folder.path, underlying: String(localized: "error.folderMetadataUnavailable"))
        }
        let rootPath = volumeURL.standardizedFileURL.path
        let folderPath = resolvedURL.path
        let relativePath: String
        if folderPath == rootPath {
            relativePath = ""
        } else if rootPath == "/" {
            relativePath = String(folderPath.dropFirst())
        } else if folderPath.hasPrefix(rootPath + "/") {
            relativePath = String(folderPath.dropFirst(rootPath.count + 1))
        } else {
            throw PlaybackHistoryError.identityUnavailable(folder.path, underlying: String(localized: "error.folderOutsideVolume"))
        }
        return (volumeID, values.volumeName ?? volumeURL.lastPathComponent, relativePath, resolvedURL.lastPathComponent)
    }

    private static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("createPlaybackHistory") { db in
            try db.create(table: "playback_history") { table in
                table.column("file_path", .text).primaryKey().notNull()
                table.column("position", .double).notNull().defaults(to: 0)
                    .check(sql: "position >= 0")
                table.column("audio_track_id", .integer)
                table.column("subtitle_track_id", .integer)
                table.column("volume", .double).notNull().defaults(to: 100)
                    .check(sql: "volume >= 0 AND volume <= 100")
                table.column("updated_at", .double).notNull()
            }
        }
        migrator.registerMigration("mediaFileIdentity") { db in
            try db.execute(sql: "ALTER TABLE playback_history RENAME TO playback_history_legacy")
            try db.create(table: "media_sources") { table in
                table.column("volume_id", .text).primaryKey().notNull()
                table.column("display_name", .text).notNull()
                table.column("updated_at", .double).notNull()
            }
            try db.create(table: "media_files") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("volume_id", .text).notNull()
                    .references("media_sources", column: "volume_id", onDelete: .cascade)
                table.column("resource_id", .text).notNull()
                table.column("content_revision", .text).notNull()
                table.column("relative_path", .text).notNull()
                table.column("byte_count", .integer).notNull().check(sql: "byte_count >= 0")
                table.column("modified_at", .double).notNull()
                table.uniqueKey(["volume_id", "resource_id"])
            }
            try db.create(table: "playback_history") { table in
                table.column("media_file_id", .integer).primaryKey().notNull()
                    .references("media_files", column: "id", onDelete: .cascade)
                table.column("position", .double).notNull().defaults(to: 0)
                    .check(sql: "position >= 0")
                table.column("audio_track_id", .integer)
                table.column("subtitle_track_id", .integer)
                table.column("volume", .double).notNull().defaults(to: 100)
                    .check(sql: "volume >= 0 AND volume <= 100")
                table.column("updated_at", .double).notNull()
            }
            try db.create(index: "media_files_by_relative_path", on: "media_files", columns: ["volume_id", "relative_path"])
        }
        migrator.registerMigration("incrementalMediaLibrary") { db in
            try db.create(table: "media_source_roots") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("volume_id", .text).notNull()
                    .references("media_sources", column: "volume_id", onDelete: .cascade)
                table.column("relative_path", .text).notNull()
                table.column("display_name", .text).notNull()
                table.column("including_subfolders", .boolean).notNull()
                table.column("last_successful_scan_at", .double)
                table.uniqueKey(["volume_id", "relative_path"])
            }
            try db.create(table: "media_scan_runs") { table in
                table.column("id", .text).primaryKey().notNull()
                table.column("source_root_id", .integer).notNull()
                    .references("media_source_roots", column: "id", onDelete: .cascade)
                table.column("started_at", .double).notNull()
                table.column("completed_at", .double)
                table.column("discovered_count", .integer).notNull().defaults(to: 0)
                table.column("indexed_count", .integer).notNull().defaults(to: 0)
                table.column("skipped_count", .integer).notNull().defaults(to: 0)
                table.column("status", .text).notNull()
                    .check(sql: "status IN ('running', 'completed', 'partial', 'cancelled')")
            }
            try db.create(table: "media_source_files") { table in
                table.column("source_root_id", .integer).notNull()
                    .references("media_source_roots", column: "id", onDelete: .cascade)
                table.column("media_file_id", .integer).notNull()
                    .references("media_files", column: "id", onDelete: .cascade)
                table.column("last_seen_scan_id", .text).notNull()
                    .references("media_scan_runs", column: "id", onDelete: .cascade)
                table.column("is_present", .boolean).notNull()
                table.column("last_seen_at", .double).notNull()
                table.primaryKey(["source_root_id", "media_file_id"])
            }
            try db.create(index: "media_source_files_by_scan", on: "media_source_files", columns: ["source_root_id", "last_seen_scan_id"])
        }
        migrator.registerMigration("mediaLibraryPreferences") { db in
            try db.alter(table: "media_source_files") { table in
                table.add(column: "added_at", .double).notNull().defaults(to: 0)
            }
            try db.execute(sql: "UPDATE media_source_files SET added_at = last_seen_at WHERE added_at = 0")
            try db.create(table: "media_file_preferences") { table in
                table.column("media_file_id", .integer).primaryKey().notNull()
                    .references("media_files", column: "id", onDelete: .cascade)
                table.column("is_favorite", .boolean).notNull().defaults(to: false)
                table.column("is_watched", .boolean).notNull().defaults(to: false)
            }
            try db.create(index: "playback_history_by_updated_at", on: "playback_history", columns: ["updated_at"])
        }
        migrator.registerMigration("manualMediaCategory") { db in
            try db.alter(table: "media_file_preferences") { table in
                table.add(column: "manual_category", .text)
                    .check(sql: "manual_category IS NULL OR manual_category IN ('movie', 'series', 'personal')")
            }
        }
        migrator.registerMigration("privatePlaybackFolders") { db in
            try db.create(table: "private_media_roots") { table in
                table.column("volume_id", .text).notNull()
                table.column("relative_path", .text).notNull()
                table.column("display_name", .text).notNull()
                table.primaryKey(["volume_id", "relative_path"])
            }
            try db.create(index: "private_media_roots_by_volume", on: "private_media_roots",
                          columns: ["volume_id", "relative_path"])
        }
        migrator.registerMigration("mediaSourceDirectories") { db in
            try db.create(table: "media_source_directories") { table in
                table.column("source_root_id", .integer).notNull()
                    .references("media_source_roots", column: "id", onDelete: .cascade)
                table.column("relative_path", .text).notNull()
                table.column("display_name", .text).notNull()
                table.column("last_seen_scan_id", .text).notNull()
                    .references("media_scan_runs", column: "id", onDelete: .cascade)
                table.column("is_present", .boolean).notNull()
                table.primaryKey(["source_root_id", "relative_path"])
            }
            try db.create(index: "media_source_directories_by_scan", on: "media_source_directories",
                          columns: ["source_root_id", "last_seen_scan_id"])
        }
        migrator.registerMigration("mediaContentFingerprint") { db in
            try db.alter(table: "media_files") { table in
                table.add(column: "content_fingerprint", .text)
            }
        }
        migrator.registerMigration("completeSmallFileFingerprint") { db in
            try db.alter(table: "media_files") { table in
                table.add(column: "legacy_content_fingerprint", .text)
            }
            // Defer filesystem reads until normal access; retain the prior verification baseline.
            try db.execute(sql: """
                UPDATE media_files SET legacy_content_fingerprint = content_fingerprint,
                    content_fingerprint = NULL
                WHERE byte_count > 16384 AND byte_count <= 81920
                """)
        }
        migrator.registerMigration("volumeScopedFileNumber") { db in
            try db.alter(table: "media_files") { table in
                table.add(column: "file_number", .text)
            }
            for row in try Row.fetchAll(db, sql: "SELECT id, resource_id FROM media_files") {
                let resourceID: String = row["resource_id"]
                if let number = Self.fileNumber(in: resourceID) {
                    try db.execute(sql: "UPDATE media_files SET file_number = ? WHERE id = ?",
                                   arguments: [number, row["id"] as Int64])
                }
            }
            try db.create(index: "media_files_by_volume_number", on: "media_files",
                          columns: ["volume_id", "file_number"])
        }
        migrator.registerMigration("legacyHistoryPrivacyPurges") { db in
            // No foreign key: removing a source or privacy rule cannot revoke a completed purge.
            try db.create(table: "legacy_history_purges") { table in
                table.column("volume_id", .text).notNull()
                table.column("relative_path", .text).notNull()
                table.primaryKey(["volume_id", "relative_path"])
            }
            for row in try Row.fetchAll(db, sql: "SELECT volume_id, relative_path FROM private_media_roots") {
                try Self.purgeHistory(volumeID: row["volume_id"], relativePath: row["relative_path"], in: db)
            }
        }
        return migrator
    }
}
