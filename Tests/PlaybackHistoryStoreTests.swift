import Darwin
import Foundation
import GRDB
import XCTest

final class PlaybackHistoryStoreTests: XCTestCase {
    func testCorruptDatabaseStartupPreservesOriginalBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "history.sqlite")
        let damagedBytes = Data(repeating: 0xA5, count: 4096)
        try damagedBytes.write(to: databaseURL)

        XCTAssertThrowsError(try PlaybackHistoryStore(path: databaseURL.path)) { error in
            XCTAssertEqual((error as? DatabaseError)?.resultCode, .SQLITE_NOTADB)
        }
        XCTAssertEqual(try Data(contentsOf: databaseURL), damagedBytes,
                       "A failed database open must preserve the file for recovery")
    }

    func testReadOnlyDatabaseStartupPreservesCheckpointAndRecovers() async throws {
        guard geteuid() != 0 else { throw XCTSkip("Root bypasses filesystem permission restrictions") }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databaseURL = directory.appending(path: "history.sqlite")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: databaseURL.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let mediaURL = directory.appending(path: "media.mp4")
        let mediaBytes = Data("read-only database recovery fixture".utf8)
        try mediaBytes.write(to: mediaURL)
        let seeded = try await runStorageProcess(role: "seed", directory: directory)
        XCTAssertEqual(seeded, [32.5, 2, 4, 55])
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: databaseURL.path)
        let failure = try await runStorageProcess(role: "readonly", directory: directory)
        XCTAssertEqual(failure, [Double(ResultCode.SQLITE_READONLY.rawValue)])

        for suffix in ["", "-wal", "-shm"] {
            let path = databaseURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            }
        }
        let recovered = try PlaybackHistoryStore(path: databaseURL.path)
        let checkpoint = try await recovered.history(for: mediaURL)
        XCTAssertEqual(checkpoint?.position, 32.5)
        XCTAssertEqual(checkpoint?.audioTrackID, 2)
        XCTAssertEqual(checkpoint?.subtitleTrackID, 4)
        XCTAssertEqual(checkpoint?.volume, 55)
        try await recovered.save(for: mediaURL, position: 40, volume: 70)
        let updated = try await recovered.history(for: mediaURL)
        XCTAssertEqual(updated?.position, 40)
        XCTAssertEqual(updated?.volume, 70)
        XCTAssertEqual(try Data(contentsOf: mediaURL), mediaBytes)
    }

    func testReadOnlyStartupInSeparateProcess() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["BOMU_STORAGE_PROCESS_DIRECTORY"],
              let role = environment["BOMU_STORAGE_PROCESS_ROLE"] else { return }
        let directory = URL(fileURLWithPath: path)
        let databaseURL = directory.appending(path: "history.sqlite")
        let result: [Double]
        switch role {
        case "seed":
            let store = try PlaybackHistoryStore(path: databaseURL.path)
            let mediaURL = directory.appending(path: "media.mp4")
            try await store.save(for: mediaURL, position: 32.5, audioTrackID: 2,
                                 subtitleTrackID: 4, volume: 55)
            let checkpoint = try await store.history(for: mediaURL)
            let saved = try XCTUnwrap(checkpoint)
            result = [saved.position, Double(try XCTUnwrap(saved.audioTrackID)),
                      Double(try XCTUnwrap(saved.subtitleTrackID)), saved.volume]
        case "readonly":
            do {
                _ = try PlaybackHistoryStore(path: databaseURL.path)
                XCTFail("Read-only storage must fail startup without replacing the database")
                return
            } catch let error as DatabaseError {
                XCTAssertEqual(error.resultCode, .SQLITE_READONLY)
                result = [Double(error.resultCode.rawValue)]
            }
        default:
            XCTFail("Unknown storage test process role")
            return
        }
        try JSONEncoder().encode(result).write(
            to: directory.appending(path: "\(role)-result.json"), options: .atomic)
    }

    func testArchiveReaderEnforcesByteLimitWhileReading() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                          directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archiveURL = directory.appending(path: "archive.json")
        let payload = Data(repeating: 0x41, count: 129)
        try payload.write(to: archiveURL)

        XCTAssertEqual(try MediaLibraryArchive.read(from: archiveURL, maximumSize: payload.count), payload)
        XCTAssertThrowsError(try MediaLibraryArchive.read(from: archiveURL, maximumSize: payload.count - 1)) {
            XCTAssertTrue($0 is MediaLibraryArchiveError)
        }
        let emptyArchiveURL = directory.appending(path: "empty.json")
        try Data().write(to: emptyArchiveURL)
        XCTAssertEqual(try MediaLibraryArchive.read(from: emptyArchiveURL, maximumSize: 0), Data(),
                       "Empty files are accepted at a zero-byte limit")
    }

    func testArchiveEncodingUsesTheSameByteLimitAsImport() throws {
        let archive = MediaLibraryArchive(schemaVersion: 1, exportedAt: .now, sources: [], files: [],
            privateFolders: [], settings: MediaLibraryArchive.Settings(automaticallyPlayNext: true,
                resumeFromLastPosition: true, defaultSpeed: 1, defaultSubtitleDelay: 0))
        let encoded = try MediaLibraryArchive.encodedData(for: archive)

        XCTAssertEqual(try MediaLibraryArchive.encodedData(for: archive, maximumSize: encoded.count), encoded)
        XCTAssertThrowsError(try MediaLibraryArchive.encodedData(for: archive, maximumSize: encoded.count - 1)) {
            XCTAssertTrue($0 is MediaLibraryArchiveError)
        }
    }

    func testMigrationPersistsIndependentFilesAndTrackPreferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appending(path: "history.sqlite").path
        let firstURL = directory.appending(path: "episode 1.mkv")
        let secondURL = directory.appending(path: "episode 2.mkv")
        try Data("first media".utf8).write(to: firstURL)
        try Data("second media".utf8).write(to: secondURL)
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            let store = try PlaybackHistoryStore(path: databasePath)
            try await store.save(for: firstURL, position: 81.25, audioTrackID: 2,
                                 subtitleTrackID: 4, volume: 63, updatedAt: timestamp)
            try await store.save(for: secondURL, position: 12, volume: 100, updatedAt: timestamp)

            let first = try await store.history(for: firstURL)
            XCTAssertEqual(first?.position, 81.25)
            XCTAssertEqual(first?.audioTrackID, 2)
            XCTAssertEqual(first?.subtitleTrackID, 4)
            XCTAssertEqual(first?.volume, 63)
            XCTAssertEqual(first?.updatedAt, timestamp)
            let second = try await store.history(for: secondURL)
            XCTAssertEqual(second?.position, 12)
        }

        let reopened = try PlaybackHistoryStore(path: databasePath)
        let restored = try await reopened.history(for: firstURL)
        XCTAssertEqual(restored?.position, 81.25)
    }

    func testRejectedWriteLeavesPreviousRecordUntouched() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = try makeMediaFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try await store.save(for: url, position: 30, volume: 70)

        do {
            try await store.save(for: url, position: .nan, volume: 20)
            XCTFail("Non-finite playback positions must be rejected")
        } catch PlaybackHistoryError.invalidPosition {
            // Expected validation before opening the write transaction.
        }

        let saved = try await store.history(for: url)
        XCTAssertEqual(saved?.position, 30)
        XCTAssertEqual(saved?.volume, 70)
    }

    func testVolumeAndPositionBoundsAreEnforced() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = try makeMediaFile()
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try await store.save(for: url, position: -1, volume: 50)
            XCTFail("Negative positions must be rejected")
        } catch PlaybackHistoryError.invalidPosition { }

        do {
            try await store.save(for: url, position: 1, volume: 101)
            XCTFail("Volume outside the native 0–100 range must be rejected")
        } catch PlaybackHistoryError.invalidVolume { }

        let saved = try await store.history(for: url)
        XCTAssertNil(saved)
    }

    func testRenameKeepsHistoryAndUpdatesVolumeRelativePath() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appending(path: "../\(directory.lastPathComponent)-history.sqlite").path
        defer { try? FileManager.default.removeItem(atPath: databasePath) }
        let store = try PlaybackHistoryStore(path: databasePath)
        let original = directory.appending(path: "before.mkv")
        let renamed = directory.appending(path: "after.mkv")
        try Data("same media contents".utf8).write(to: original)
        try await store.save(for: original, position: 91, volume: 50)

        try FileManager.default.moveItem(at: original, to: renamed)

        let restored = try await store.history(for: renamed)
        XCTAssertEqual(restored?.position, 91)
        XCTAssertEqual(restored?.relativePath, relativePath(of: renamed))

        let database = try DatabaseQueue(path: databasePath)
        let metadata = try await database.read { db -> (String, String)? in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT media_sources.volume_id, media_files.relative_path FROM media_sources JOIN media_files USING (volume_id)"
            ) else { return nil }
            let volumeID: String = row["volume_id"]
            let persistedRelativePath: String = row["relative_path"]
            return (volumeID, persistedRelativePath)
        }
        let volumeID = metadata?.0
        let persistedRelativePath = metadata?.1
        XCTAssertFalse(volumeID?.isEmpty ?? true)
        XCTAssertEqual(persistedRelativePath, relativePath(of: renamed))
    }

    func testAtomicReplacementAtSamePathDoesNotInheritHistory() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "movie.mkv")
        let replacement = directory.appending(path: "replacement.tmp")
        try Data(repeating: 0x41, count: 1024).write(to: url)
        try await store.save(for: url, position: 120, volume: 50)

        try Data(repeating: 0x42, count: 1024).write(to: replacement)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: replacement)

        let history = try await store.history(for: url)
        XCTAssertNil(history)
    }

    func testInPlaceContentChangeClearsHistory() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = try makeMediaFile(contents: Data(repeating: 0x31, count: 64))
        defer { try? FileManager.default.removeItem(at: url) }
        try await store.save(for: url, position: 18, volume: 50)

        try Data(repeating: 0x32, count: 128).write(to: url)

        let history = try await store.history(for: url)
        XCTAssertNil(history)
    }

    func testSampledFingerprintDetectsSameSizeRewriteWithRestoredModificationDate() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = try makeMediaFile(contents: Data(repeating: 0x31, count: 256 * 1_024))
        defer { try? FileManager.default.removeItem(at: url) }
        try await store.save(for: url, position: 18, volume: 50)

        // Read the identity values from the same store's database through an archive, then mutate
        // a region that is included in the deterministic sparse sample set.
        let before = try await store.exportArchive(settings: Self.testSettings)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archivedBefore = try decoder.decode(MediaLibraryArchive.self, from: before)
        let originalFile = try XCTUnwrap(archivedBefore.files.first)
        var originalMetadata = stat()
        let statResult = url.path.withCString { stat($0, &originalMetadata) }
        XCTAssertEqual(statResult, 0)

        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 128 * 1_024)
        try handle.write(contentsOf: Data(repeating: 0x32, count: 16 * 1_024))
        try handle.synchronize()
        try handle.close()
        var originalTimes = [originalMetadata.st_atimespec, originalMetadata.st_mtimespec]
        let timestampResult = url.path.withCString {
            utimensat(AT_FDCWD, $0, &originalTimes, 0)
        }
        XCTAssertEqual(timestampResult, 0)

        let history = try await store.history(for: url)
        let after = try await store.exportArchive(settings: Self.testSettings)
        let archivedAfter = try decoder.decode(MediaLibraryArchive.self, from: after)
        let updatedFile = try XCTUnwrap(archivedAfter.files.first)

        XCTAssertEqual(updatedFile.contentRevision, originalFile.contentRevision,
                       "The test must preserve the metadata revision to exercise sampled content identity")
        XCTAssertNotEqual(updatedFile.contentFingerprint, originalFile.contentFingerprint)
        XCTAssertNil(history, "A same-size rewrite must not inherit the old checkpoint when mtime is restored")
    }

    func testDeviceNumberChangeAndRenamePreserveVolumeScopedIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "original.mp4")
        try Data("unchanged remounted media".utf8).write(to: media)
        let databaseURL = root.appending(path: "history.sqlite")
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        let id = try await store.indexMediaFile(at: media)
        try await store.save(for: media, position: 25, volume: 70)
        try await store.setFavorite(true, for: id)
        var metadata = stat()
        XCTAssertEqual(media.path.withCString { stat($0, &metadata) }, 0)
        let oldResourceID = "\(Int64(metadata.st_dev) + 1):\(metadata.st_ino)"
        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { db in
            try db.execute(sql: "UPDATE media_files SET resource_id = ? WHERE id = ?", arguments: [oldResourceID, id])
        }
        let archive = try await store.exportArchive(settings: Self.testSettings)
        try await database.write { db in
            try db.execute(sql: "DROP INDEX media_files_by_volume_number")
            try db.execute(sql: "ALTER TABLE media_files DROP COLUMN file_number")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'volumeScopedFileNumber'")
        }
        let renamed = root.appending(path: "renamed.mp4")
        try FileManager.default.moveItem(at: media, to: renamed)
        let reopened = try PlaybackHistoryStore(path: databaseURL.path)
        let history = try await reopened.history(for: renamed)
        XCTAssertEqual(history?.mediaFileID, id)
        XCTAssertEqual(history?.position, 25)
        let newID = try await reopened.indexMediaFile(at: renamed)
        XCTAssertEqual(newID, id)
        let fresh = try PlaybackHistoryStore(path: ":memory:")
        _ = try await fresh.indexMediaFile(at: renamed)
        let restored = try await fresh.importArchive(archive)
        XCTAssertEqual(restored.importedFileCount, 1, "A legacy device number must not break renamed-file restore")
        let restoredHistory = try await fresh.history(for: renamed)
        XCTAssertEqual(restoredHistory?.position, 25)
    }

    func testConflictingVolumeFileNumbersPreserveRecordsAndRejectImplicitChoice() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "conflict.mp4")
        try Data("conflicting legacy identities".utf8).write(to: media)
        let databaseURL = root.appending(path: "history.sqlite")
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        let id = try await store.indexMediaFile(at: media)
        try await store.save(for: media, position: 25, volume: 70)
        try await store.setFavorite(true, for: id)
        let archive = try await store.exportArchive(settings: Self.testSettings)
        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO media_files
                    (volume_id, resource_id, file_number, content_revision, content_fingerprint,
                     legacy_content_fingerprint, relative_path, byte_count, modified_at)
                SELECT volume_id, '999:' || file_number, file_number, content_revision, content_fingerprint,
                     legacy_content_fingerprint, relative_path, byte_count, modified_at
                FROM media_files WHERE id = ?
                """, arguments: [id])
            let duplicateID = db.lastInsertedRowID
            try db.execute(sql: """
                INSERT INTO playback_history (media_file_id, position, volume, updated_at)
                VALUES (?, 99, 50, 1)
                """, arguments: [duplicateID])
        }
        do {
            _ = try await store.history(for: media)
            XCTFail("Conflicting histories require an explicit resolution")
        } catch PlaybackHistoryError.ambiguousMediaIdentity { }
        do {
            _ = try await store.indexMediaFile(at: media)
            XCTFail("Scanning must not silently choose a conflicting row")
        } catch PlaybackHistoryError.ambiguousMediaIdentity { }
        do {
            _ = try await store.importArchive(archive)
            XCTFail("Import must not pick one of two matching identities")
        } catch PlaybackHistoryError.ambiguousMediaIdentity { }
        try await database.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM media_files"), 2)
            XCTAssertEqual(try Double.fetchAll(db, sql: "SELECT position FROM playback_history ORDER BY position"), [25, 99])
            XCTAssertEqual(try Bool.fetchOne(db, sql: "SELECT is_favorite FROM media_file_preferences WHERE media_file_id = ?",
                                            arguments: [id]), true)
        }
    }

    func testIdenticalFileNumberOnAnotherVolumeCannotSupplyHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "volume.mp4")
        try Data("volume scoped identity".utf8).write(to: media)
        let databaseURL = root.appending(path: "history.sqlite")
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        let id = try await store.indexMediaFile(at: media)
        try await store.save(for: media, position: 25, volume: 70)
        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { db in
            try db.execute(sql: "INSERT INTO media_sources (volume_id, display_name, updated_at) VALUES ('other-volume', 'Other', 1)")
            try db.execute(sql: "UPDATE media_files SET volume_id = 'other-volume' WHERE id = ?", arguments: [id])
        }
        let history = try await store.history(for: media)
        XCTAssertNil(history)
        let newID = try await store.indexMediaFile(at: media)
        XCTAssertNotEqual(newID, id)
        try await database.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT position FROM playback_history WHERE media_file_id = ?",
                                              arguments: [id]), 25)
        }
    }

    func testSmallFileFingerprintUpgradePreservesFactsAndLegacyArchiveMatching() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "small.mp4")
        try Data(repeating: 0x31, count: 48 * 1_024).write(to: media)
        let databaseURL = root.appending(path: "history.sqlite")
        let legacy = try await makePrefixFingerprintDatabase(at: databaseURL, media: media)
        let renamed = root.appending(path: "renamed.mp4")
        try FileManager.default.moveItem(at: media, to: renamed)
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        let beforeAccess = try await store.exportArchive(settings: Self.testSettings)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let oldArchive = try decoder.decode(MediaLibraryArchive.self, from: legacy.archive)
        let lazyArchive = try decoder.decode(MediaLibraryArchive.self, from: beforeAccess)
        XCTAssertEqual(lazyArchive.schemaVersion, 2)
        XCTAssertEqual(lazyArchive.files.first?.contentFingerprint, oldArchive.files.first?.contentFingerprint)

        let history = try await store.history(for: renamed)
        XCTAssertEqual(history?.mediaFileID, legacy.id)
        XCTAssertEqual(history?.position, 18)
        let upgraded = try await store.exportArchive(settings: Self.testSettings)
        let newArchive = try decoder.decode(MediaLibraryArchive.self, from: upgraded)
        let newFile = try XCTUnwrap(newArchive.files.first)
        XCTAssertNotEqual(newFile.contentFingerprint, oldArchive.files.first?.contentFingerprint)
        XCTAssertTrue(newFile.isFavorite)
        XCTAssertTrue(newFile.isWatched)
        XCTAssertEqual(newFile.manualCategory, .movie)
        let preview = try await store.previewArchiveImport(legacy.archive)
        XCTAssertEqual(preview.matchedFileCount, 1, "Renaming preserves the old backup's identity")

        let fresh = try PlaybackHistoryStore(path: ":memory:")
        _ = try await fresh.indexMediaFile(at: renamed)
        let imported = try await fresh.importArchive(legacy.archive)
        XCTAssertEqual(imported.importedFileCount, 1)
        let restored = try await fresh.history(for: renamed)
        XCTAssertEqual(restored?.position, 18)
        XCTAssertEqual(try Data(contentsOf: renamed), Data(repeating: 0x31, count: 48 * 1_024))

        // A restored copy has a new inode: the archive must also match by location and verified content.
        var metadata = stat()
        XCTAssertEqual(renamed.path.withCString { stat($0, &metadata) }, 0)
        try FileManager.default.copyItem(at: renamed, to: media)
        var times = [metadata.st_atimespec, metadata.st_mtimespec]
        XCTAssertEqual(media.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }, 0)
        let copiedStore = try PlaybackHistoryStore(path: ":memory:")
        _ = try await copiedStore.indexMediaFile(at: media)
        let copiedImport = try await copiedStore.importArchive(legacy.archive)
        XCTAssertEqual(copiedImport.importedFileCount, 1)
        let copiedHistory = try await copiedStore.history(for: media)
        XCTAssertEqual(copiedHistory?.position, 18)
    }

    func testSmallFileFingerprintMigrationFailureRollsBackAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "small.mp4")
        try Data(repeating: 0x31, count: 48 * 1_024).write(to: media)
        let databaseURL = root.appending(path: "history.sqlite")
        _ = try await makePrefixFingerprintDatabase(at: databaseURL, media: media)
        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_fingerprint_upgrade BEFORE UPDATE ON media_files
                BEGIN SELECT RAISE(ABORT, 'injected migration failure'); END
                """)
        }
        XCTAssertThrowsError(try PlaybackHistoryStore(path: databaseURL.path))
        try await database.read { db in
            XCTAssertFalse(try db.columns(in: "media_files").contains { $0.name == "legacy_content_fingerprint" })
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT position FROM playback_history"), 18)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT is_favorite FROM media_file_preferences"), 1)
        }
        try await database.write { try $0.execute(sql: "DROP TRIGGER reject_fingerprint_upgrade") }
        let recovered = try PlaybackHistoryStore(path: databaseURL.path)
        let history = try await recovered.history(for: media)
        XCTAssertEqual(history?.position, 18)
    }

    func testSmallFileUpgradeRejectsChangesAlreadyDetectableByLegacyFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "small.mp4")
        try Data(repeating: 0x31, count: 48 * 1_024).write(to: media)
        let databaseURL = root.appending(path: "history.sqlite")
        let legacy = try await makePrefixFingerprintDatabase(at: databaseURL, media: media)
        var metadata = stat()
        XCTAssertEqual(media.path.withCString { stat($0, &metadata) }, 0)
        let handle = try FileHandle(forUpdating: media)
        try handle.write(contentsOf: Data([0x32]))
        try handle.close()
        var times = [metadata.st_atimespec, metadata.st_mtimespec]
        XCTAssertEqual(media.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }, 0)
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        let history = try await store.history(for: media)
        XCTAssertNil(history)
        let id = try await store.indexMediaFile(at: media)
        XCTAssertNotEqual(id, legacy.id)
        let preview = try await store.previewArchiveImport(legacy.archive)
        XCTAssertEqual(preview.matchedFileCount, 0)
    }

    func testSmallFileFingerprintIncludesTailWithUnchangedSizeAndModificationTime() async throws {
        for size in [16 * 1_024 + 1, 48 * 1_024, 80 * 1_024] {
            let store = try PlaybackHistoryStore(path: ":memory:")
            let url = try makeMediaFile(contents: Data(repeating: 0x31, count: size))
            defer { try? FileManager.default.removeItem(at: url) }
            let originalID = try await store.indexMediaFile(at: url)
            try await store.save(for: url, position: 18, volume: 50)
            try await store.setFavorite(true, for: originalID)
            let archive = try await store.exportArchive(settings: Self.testSettings)
            var metadata = stat()
            XCTAssertEqual(url.path.withCString { stat($0, &metadata) }, 0)
            let handle = try FileHandle(forUpdating: url)
            try handle.seek(toOffset: UInt64(size - 1))
            try handle.write(contentsOf: Data([0x32]))
            try handle.close()
            var times = [metadata.st_atimespec, metadata.st_mtimespec]
            XCTAssertEqual(url.path.withCString { utimensat(AT_FDCWD, $0, &times, 0) }, 0)

            let history = try await store.history(for: url)
            let replacementID = try await store.indexMediaFile(at: url)
            let preview = try await store.previewArchiveImport(archive)
            XCTAssertNil(history, "A changed final byte must invalidate history for \(size) bytes")
            XCTAssertNotEqual(replacementID, originalID)
            XCTAssertEqual(preview.matchedFileCount, 0, "New archives must not restore replaced content")
        }
    }

    func testContentReplacementCreatesNewMediaIdentityAndClearsPreferences() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appending(path: "replace-in-place.mp4")
        try Data(repeating: 0x31, count: 256 * 1_024).write(to: url)
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scan = try await store.beginScan(folder: root, includingSubfolders: true)
        let originalID = try await store.indexMediaFile(at: url, in: scan)
        try await store.finishScan(scan, reconcileDeletions: true, discoveredCount: 1,
                                   indexedCount: 1, skippedCount: 0)
        try await store.setFavorite(true, for: originalID)
        try await store.setWatched(true, for: originalID)
        try await store.setManualCategory(.movie, for: originalID)
        try await store.save(for: url, position: 88, volume: 50)
        let originalItems = try await store.libraryItems(in: scan.sourceRootID)
        let originalItem = try XCTUnwrap(originalItems.first)

        var originalMetadata = stat()
        XCTAssertEqual(url.path.withCString { stat($0, &originalMetadata) }, 0)
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: 128 * 1_024)
        try handle.write(contentsOf: Data(repeating: 0x32, count: 16 * 1_024))
        try handle.synchronize()
        try handle.close()
        var originalTimes = [originalMetadata.st_atimespec, originalMetadata.st_mtimespec]
        XCTAssertEqual(url.path.withCString { utimensat(AT_FDCWD, $0, &originalTimes, 0) }, 0)

        let replacedHistory = try await store.history(for: url)
        XCTAssertNil(replacedHistory)
        let replacementID = try await store.indexMediaFile(at: url)
        let replacementItems = try await store.libraryItems(in: scan.sourceRootID)
        let replacementItem = try XCTUnwrap(replacementItems.first)

        XCTAssertNotEqual(replacementID, originalID,
                          "Changed content receives a new durable row identity")
        XCTAssertEqual(replacementItem.id, replacementID)
        XCTAssertTrue(replacementItem.isPresent)
        XCTAssertEqual(replacementItem.addedAt, originalItem.addedAt,
                       "Replacing bytes does not make the same source membership appear newly added")
        XCTAssertFalse(replacementItem.isFavorite)
        XCTAssertFalse(replacementItem.isWatched)
        XCTAssertNil(replacementItem.manualCategory)
        XCTAssertEqual(replacementItem.playbackPosition, 0)
    }

    func testClearHistoryRemovesDeferredLegacyRecordsWithoutRemovingLibraryPreferences() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let source = directory.appending(path: "Library")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = source.appending(path: "current.mp4")
        let legacy = directory.appending(path: "legacy.mp4")
        try Data("current media".utf8).write(to: current)
        try Data("legacy media".utf8).write(to: legacy)
        let databasePath = directory.appending(path: "history.sqlite").path
        let store = try PlaybackHistoryStore(path: databasePath)
        for try await _ in MediaLibraryScanner(historyStore: store).scan(folder: source).events { }
        let roots = try await store.sourceRoots(mountedVolumeIDs: [])
        let rootID = try XCTUnwrap(roots.first?.id)
        let indexed = try await store.libraryItems(in: rootID)
        let item = try XCTUnwrap(indexed.first)
        try await store.setFavorite(true, for: item.id)
        try await store.setManualCategory(.movie, for: item.id)
        try await store.save(for: current, position: 42, volume: 70)
        let connection = try DatabaseQueue(path: databasePath)
        try await connection.write { db in
            try db.execute(sql: "INSERT INTO playback_history_legacy VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [legacy.standardizedFileURL.resolvingSymlinksInPath().path,
                                       77.0, 3, 4, 66.0, 1_800_000_000.0])
        }

        try await store.clearAll()
        let reopened = try PlaybackHistoryStore(path: databasePath)
        let legacyHistory = try await reopened.history(for: legacy)
        let currentHistory = try await reopened.history(for: current)
        XCTAssertNil(legacyHistory, "First open after clearing must not resurrect deferred old-version history")
        XCTAssertNil(currentHistory)
        let retained = try await reopened.libraryItems(in: rootID)
        XCTAssertEqual(retained.count, 1)
        XCTAssertTrue(retained.first?.isFavorite == true)
        XCTAssertEqual(retained.first?.manualCategory, .movie)
        XCTAssertEqual(retained.first?.playbackPosition, 0)
        XCTAssertEqual(try Data(contentsOf: current), Data("current media".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy), Data("legacy media".utf8))
    }

    func testFailedLegacyHistoryClearRollsBackCurrentHistoryAndCanRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appending(path: "current.mp4")
        try Data("kept media".utf8).write(to: media)
        let databasePath = directory.appending(path: "history.sqlite").path
        let store = try PlaybackHistoryStore(path: databasePath)
        try await store.save(for: media, position: 42, volume: 70)
        let connection = try DatabaseQueue(path: databasePath)
        try await connection.write { db in
            try db.execute(sql: "INSERT INTO playback_history_legacy VALUES (?, ?, NULL, NULL, ?, ?)",
                           arguments: ["/unmounted/legacy.mp4", 77.0, 66.0, 1_800_000_000.0])
            try db.execute(sql: """
                CREATE TRIGGER fail_legacy_delete BEFORE DELETE ON playback_history_legacy
                BEGIN SELECT RAISE(ABORT, 'forced history clear failure'); END
                """)
        }
        do {
            try await store.clearAll()
            XCTFail("Failure clearing old records must fail the whole history clear")
        } catch is DatabaseError { }
        let retained = try await store.history(for: media)
        XCTAssertEqual(retained?.position, 42)
        let legacyCount = try await connection.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_history_legacy")
        }
        XCTAssertEqual(legacyCount, 1)
        try await connection.write { db in try db.execute(sql: "DROP TRIGGER fail_legacy_delete") }
        try await store.clearAll()
        let cleared = try await store.history(for: media)
        XCTAssertNil(cleared)
        let clearedLegacyCount = try await connection.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_history_legacy")
        }
        XCTAssertEqual(clearedLegacyCount, 0)
    }

    func testLegacyPathRecordMovesToFileIdentityOnFirstOpen() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "existing.mkv")
        let databasePath = directory.appending(path: "history.sqlite").path
        try Data("existing media".utf8).write(to: url)
        let legacyDatabase = try DatabaseQueue(path: databasePath)
        try await legacyDatabase.write { db in
            try db.create(table: "grdb_migrations") { table in
                table.column("identifier", .text).primaryKey().notNull()
            }
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["createPlaybackHistory"]
            )
            try db.create(table: "playback_history") { table in
                table.column("file_path", .text).primaryKey().notNull()
                table.column("position", .double).notNull()
                table.column("audio_track_id", .integer)
                table.column("subtitle_track_id", .integer)
                table.column("volume", .double).notNull()
                table.column("updated_at", .double).notNull()
            }
            try db.execute(
                sql: "INSERT INTO playback_history VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [url.path, 77.0, 3, 4, 66.0, 1_800_000_000.0]
            )
        }
        withExtendedLifetime(legacyDatabase) { }

        let store = try PlaybackHistoryStore(path: databasePath)
        let history = try await store.history(for: url)

        XCTAssertEqual(history?.position, 77)
        XCTAssertEqual(history?.audioTrackID, 3)
        XCTAssertEqual(history?.subtitleTrackID, 4)
        XCTAssertEqual(history?.volume, 66)
    }

    func testInterruptedSchemaMigrationRollsBackAndCanResumeWithoutLosingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = directory.appending(path: "existing.mkv")
        let databasePath = directory.appending(path: "history.sqlite").path
        try Data("existing media".utf8).write(to: mediaURL)

        let legacyDatabase = try DatabaseQueue(path: databasePath)
        try await legacyDatabase.write { db in
            try db.create(table: "grdb_migrations") { table in
                table.column("identifier", .text).primaryKey().notNull()
            }
            try db.execute(
                sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)",
                arguments: ["createPlaybackHistory"]
            )
            try db.create(table: "playback_history") { table in
                table.column("file_path", .text).primaryKey().notNull()
                table.column("position", .double).notNull()
                table.column("audio_track_id", .integer)
                table.column("subtitle_track_id", .integer)
                table.column("volume", .double).notNull()
                table.column("updated_at", .double).notNull()
            }
            try db.execute(
                sql: "INSERT INTO playback_history VALUES (?, ?, ?, ?, ?, ?)",
                arguments: [mediaURL.path, 77.0, 3, 4, 66.0, 1_800_000_000.0]
            )
            // Force mediaFileIdentity to fail after it renames the legacy table.
            try db.create(table: "media_sources") { $0.column("migration_blocker", .integer) }
        }
        withExtendedLifetime(legacyDatabase) { }

        XCTAssertThrowsError(try PlaybackHistoryStore(path: databasePath),
                             "A failed migration must be reported to the caller")

        let failedDatabase = try DatabaseQueue(path: databasePath)
        let afterFailure = try await failedDatabase.read { db -> (Set<String>, Double?) in
            let tables = Set(try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
            let position = try Double.fetchOne(
                db, sql: "SELECT position FROM playback_history WHERE file_path = ?", arguments: [mediaURL.path]
            )
            return (tables, position)
        }
        XCTAssertTrue(afterFailure.0.contains("playback_history"))
        XCTAssertFalse(afterFailure.0.contains("playback_history_legacy"),
                       "The table rename must roll back with the failed migration")
        XCTAssertEqual(afterFailure.1, 77)

        try await failedDatabase.write { db in try db.execute(sql: "DROP TABLE media_sources") }
        let recoveredStore = try PlaybackHistoryStore(path: databasePath)
        let recoveredHistory = try await recoveredStore.history(for: mediaURL)
        XCTAssertEqual(recoveredHistory?.position, 77)
        XCTAssertEqual(recoveredHistory?.audioTrackID, 3)
        XCTAssertEqual(recoveredHistory?.subtitleTrackID, 4)
        XCTAssertEqual(recoveredHistory?.volume, 66)
    }

    func testLibraryPreferencesAndPlaybackPositionPersistForIndexedItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PlaybackHistoryStore(path: directory.appending(path: "library.sqlite").path)
        let mediaURL = directory.appending(path: "favorite film.mp4")
        try Data("local video".utf8).write(to: mediaURL)
        let scan = try await store.beginScan(folder: directory, includingSubfolders: true)
        let mediaFileID = try await store.indexMediaFile(at: mediaURL, in: scan)
        try await store.finishScan(scan, reconcileDeletions: true, discoveredCount: 1,
                                   indexedCount: 1, skippedCount: 0)
        try await store.save(for: mediaURL, position: 42.5, volume: 70)

        try await store.setFavorite(true, for: mediaFileID)
        try await store.setWatched(true, for: mediaFileID)
        try await store.setWatched(false, for: mediaFileID)
        try await store.setManualCategory(.series, for: mediaFileID)
        let item = try await store.libraryItems(in: scan.sourceRootID).first

        XCTAssertEqual(item?.id, mediaFileID)
        XCTAssertEqual(item?.displayName, "favorite film.mp4")
        XCTAssertEqual(item?.playbackPosition, 42.5)
        XCTAssertTrue(item?.isFavorite == true)
        XCTAssertFalse(item?.isWatched == true)
        XCTAssertEqual(item?.manualCategory, .series)

        try await store.setManualCategory(nil, for: mediaFileID)
        let unclassified = try await store.libraryItems(in: scan.sourceRootID).first
        XCTAssertNil(unclassified?.manualCategory)
    }

    func testConcurrentFavoriteAndWatchedTogglesApplyEveryClick() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try PlaybackHistoryStore(path: ":memory:")
        let mediaURL = directory.appending(path: "rapid toggles.mp4")
        try Data("rapid toggle fixture".utf8).write(to: mediaURL)
        let scan = try await store.beginScan(folder: directory, includingSubfolders: true)
        let mediaFileID = try await store.indexMediaFile(at: mediaURL, in: scan)
        try await store.finishScan(scan, reconcileDeletions: true, discoveredCount: 1,
                                   indexedCount: 1, skippedCount: 0)

        async let firstFavoriteToggle = store.toggleFavorite(for: mediaFileID)
        async let secondFavoriteToggle = store.toggleFavorite(for: mediaFileID)
        async let firstWatchedToggle = store.toggleWatched(for: mediaFileID)
        async let secondWatchedToggle = store.toggleWatched(for: mediaFileID)
        let favoriteResults = try await [firstFavoriteToggle, secondFavoriteToggle]
        let watchedResults = try await [firstWatchedToggle, secondWatchedToggle]
        let item = try await store.libraryItems(in: scan.sourceRootID).first

        XCTAssertEqual(Set(favoriteResults), [false, true])
        XCTAssertEqual(Set(watchedResults), [false, true])
        XCTAssertFalse(item?.isFavorite == true)
        XCTAssertFalse(item?.isWatched == true)
    }

    func testPrivateFolderStopsHistoryWritesWithoutMatchingSiblingPrefixes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        let privateFolder = root.appending(path: "Private", directoryHint: .isDirectory)
        let similarlyNamedFolder = root.appending(path: "Privateer", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: similarlyNamedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let privateMedia = privateFolder.appending(path: "clip.mp4")
        let siblingMedia = similarlyNamedFolder.appending(path: "clip.mp4")
        try Data("private media".utf8).write(to: privateMedia)
        try Data("sibling media".utf8).write(to: siblingMedia)
        let store = try PlaybackHistoryStore(path: ":memory:")
        try await store.save(for: privateMedia, position: 20, volume: 50)
        try await store.save(for: siblingMedia, position: 30, volume: 50)

        try await store.setHistoryExcludedFolder(privateFolder, excluded: true)
        try await store.save(for: privateMedia, position: 40, volume: 60)

        let privateHistory = try await store.history(for: privateMedia)
        let siblingHistory = try await store.history(for: siblingMedia)
        let exclusions = try await store.historyExcludedFolders()
        XCTAssertNil(privateHistory)
        XCTAssertEqual(siblingHistory?.position, 30)
        XCTAssertEqual(exclusions.map(\.displayName), ["Private"])

        let exclusion = try XCTUnwrap(exclusions.first)
        try await store.removeHistoryExcludedFolder(exclusion)
        try await store.save(for: privateMedia, position: 5, volume: 60)
        let resumedHistory = try await store.history(for: privateMedia)
        XCTAssertEqual(resumedHistory?.position, 5)
    }

    func testExportContainsLibraryMetadataAndSettingsButNeverMediaBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "exported.mp4")
        let mediaBytes = Data("PRIVATE_MEDIA_PAYLOAD".utf8)
        try mediaBytes.write(to: media)
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scan = try await store.beginScan(folder: root, includingSubfolders: true)
        let fileID = try await store.indexMediaFile(at: media, in: scan)
        try await store.finishScan(scan, reconcileDeletions: true, discoveredCount: 1,
                                   indexedCount: 1, skippedCount: 0)
        try await store.setFavorite(true, for: fileID)
        try await store.setManualCategory(.movie, for: fileID)
        try await store.save(for: media, position: 73, audioTrackID: 2, volume: 81)
        let settings = MediaLibraryArchive.Settings(automaticallyPlayNext: false,
            resumeFromLastPosition: true, defaultSpeed: 1.25, defaultSubtitleDelay: -0.5)

        let data = try await store.exportArchive(settings: settings)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(MediaLibraryArchive.self, from: data)
        let file = try XCTUnwrap(archive.files.first)

        XCTAssertEqual(archive.schemaVersion, 2)
        XCTAssertEqual(archive.sources.first?.roots.first?.displayName, root.lastPathComponent)
        XCTAssertTrue(file.logicalID.contains(file.resourceID))
        XCTAssertFalse(file.contentFingerprint?.isEmpty ?? true)
        XCTAssertTrue(file.isFavorite)
        XCTAssertEqual(file.manualCategory, .movie)
        XCTAssertEqual(file.history?.position, 73)
        XCTAssertEqual(archive.settings.defaultSpeed, 1.25)
        XCTAssertNil(data.range(of: mediaBytes))
    }

    func testVersionOneArchiveRemainsImportableWithoutFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "legacy-archive.mp4")
        try Data("legacy archive media".utf8).write(to: media)
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scan = try await store.beginScan(folder: root, includingSubfolders: true)
        _ = try await store.indexMediaFile(at: media, in: scan)
        try await store.finishScan(scan, reconcileDeletions: true, discoveredCount: 1,
                                   indexedCount: 1, skippedCount: 0)
        let currentData = try await store.exportArchive(settings: Self.testSettings)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let current = try decoder.decode(MediaLibraryArchive.self, from: currentData)
        let files = current.files.map { file in
            MediaLibraryArchive.File(logicalID: "\(file.volumeID):\(file.resourceID)", volumeID: file.volumeID,
                resourceID: file.resourceID, contentRevision: file.contentRevision,
                contentFingerprint: nil, relativePath: file.relativePath, byteCount: file.byteCount,
                modifiedAt: file.modifiedAt, memberships: file.memberships,
                isFavorite: file.isFavorite, isWatched: file.isWatched,
                manualCategory: file.manualCategory, history: file.history)
        }
        let legacy = MediaLibraryArchive(schemaVersion: 1, exportedAt: current.exportedAt,
            sources: current.sources, files: files, privateFolders: current.privateFolders,
            settings: current.settings)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let legacyData = try encoder.encode(legacy)

        let preview = try await store.previewArchiveImport(legacyData)

        XCTAssertEqual(preview.schemaVersion, 1)
        XCTAssertEqual(preview.matchedFileCount, 1)
        XCTAssertEqual(preview.unmatchedFileCount, 0)
    }

    func testVersionTwoArchiveRejectsMalformedContentFingerprint() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "fingerprint.mp4")
        try Data("fingerprint validation".utf8).write(to: media)
        let store = try PlaybackHistoryStore(path: ":memory:")
        _ = try await store.indexMediaFile(at: media)
        let archive = try await store.exportArchive(settings: Self.testSettings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        var changed = object
        var files = try XCTUnwrap(changed["files"] as? [[String: Any]])
        files[0]["contentFingerprint"] = "not-a-sha256"
        changed["files"] = files
        let malformed = try JSONSerialization.data(withJSONObject: changed)

        do {
            _ = try await store.previewArchiveImport(malformed)
            XCTFail("A version 2 archive must reject malformed fingerprints before matching")
        } catch MediaLibraryArchiveError.invalidContent { }
    }

    func testArchiveImportPreviewsMatchesAndReplacesOnlyMatchedFileRecords() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "imported.mp4")
        try Data("stable local media".utf8).write(to: media)
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scan = try await store.beginScan(folder: root, includingSubfolders: true)
        let fileID = try await store.indexMediaFile(at: media, in: scan)
        try await store.finishScan(scan, reconcileDeletions: true, discoveredCount: 1,
                                   indexedCount: 1, skippedCount: 0)
        try await store.setFavorite(true, for: fileID)
        try await store.setWatched(true, for: fileID)
        try await store.setManualCategory(.series, for: fileID)
        try await store.save(for: media, position: 42, audioTrackID: 2,
                             subtitleTrackID: 3, volume: 64)
        let settings = MediaLibraryArchive.Settings(automaticallyPlayNext: false,
            resumeFromLastPosition: true, defaultSpeed: 1.5, defaultSubtitleDelay: 1.5)
        let archive = try await store.exportArchive(settings: settings)

        try await store.setFavorite(false, for: fileID)
        try await store.setWatched(false, for: fileID)
        try await store.setManualCategory(.movie, for: fileID)
        try await store.save(for: media, position: 8, volume: 20)

        let preview = try await store.previewArchiveImport(archive)
        XCTAssertEqual(preview.fileCount, 1)
        XCTAssertEqual(preview.matchedFileCount, 1)
        XCTAssertEqual(preview.unmatchedFileCount, 0)
        XCTAssertEqual(preview.replacedRecordCount, 1)
        let result = try await store.importArchive(archive)
        XCTAssertEqual(result.importedFileCount, 1)
        XCTAssertEqual(result.unmatchedFileCount, 0)
        XCTAssertEqual(result.settings, settings)

        let restored = try await store.libraryItems(in: scan.sourceRootID).first
        XCTAssertTrue(restored?.isFavorite == true)
        XCTAssertTrue(restored?.isWatched == true)
        XCTAssertEqual(restored?.manualCategory, .series)
        let history = try await store.history(for: media)
        XCTAssertEqual(history?.position, 42)
        XCTAssertEqual(history?.audioTrackID, 2)
        XCTAssertEqual(history?.subtitleTrackID, 3)
        XCTAssertEqual(history?.volume, 64)
    }

    func testExportedBackupRestoresIntoFreshDatabaseForMatchingLocalMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "restorable.mp4")
        let sourceBytes = Data("same local media identity".utf8)
        try sourceBytes.write(to: media)

        let source = try PlaybackHistoryStore(path: ":memory:")
        let sourceScan = try await source.beginScan(folder: root, includingSubfolders: true)
        let sourceFileID = try await source.indexMediaFile(at: media, in: sourceScan)
        try await source.finishScan(sourceScan, reconcileDeletions: true, discoveredCount: 1,
                                   indexedCount: 1, skippedCount: 0)
        try await source.setFavorite(true, for: sourceFileID)
        try await source.setWatched(true, for: sourceFileID)
        try await source.setManualCategory(.personal, for: sourceFileID)
        try await source.save(for: media, position: 63.5, audioTrackID: 4,
                              subtitleTrackID: 7, volume: 38)
        let settings = MediaLibraryArchive.Settings(automaticallyPlayNext: false,
            resumeFromLastPosition: true, defaultSpeed: 1.25, defaultSubtitleDelay: -0.25)
        let backup = try await source.exportArchive(settings: settings)

        let destination = try PlaybackHistoryStore(path: root.appending(path: "restored.sqlite").path)
        let destinationScan = try await destination.beginScan(folder: root, includingSubfolders: true)
        let destinationFileID = try await destination.indexMediaFile(at: media, in: destinationScan)
        try await destination.finishScan(destinationScan, reconcileDeletions: true, discoveredCount: 1,
                                         indexedCount: 1, skippedCount: 0)

        let preview = try await destination.previewArchiveImport(backup)
        XCTAssertEqual(preview.matchedFileCount, 1)
        XCTAssertEqual(preview.unmatchedFileCount, 0)
        let result = try await destination.importArchive(backup)
        XCTAssertEqual(result.importedFileCount, 1)
        XCTAssertEqual(result.settings, settings)

        let restoredItem = try await destination.libraryItems(in: destinationScan.sourceRootID)
            .first { $0.id == destinationFileID }
        XCTAssertTrue(restoredItem?.isFavorite == true)
        XCTAssertTrue(restoredItem?.isWatched == true)
        XCTAssertEqual(restoredItem?.manualCategory, .personal)
        let restoredHistory = try await destination.history(for: media)
        XCTAssertEqual(restoredHistory?.position, 63.5)
        XCTAssertEqual(restoredHistory?.audioTrackID, 4)
        XCTAssertEqual(restoredHistory?.subtitleTrackID, 7)
        XCTAssertEqual(restoredHistory?.volume, 38)
        XCTAssertEqual(try Data(contentsOf: media), sourceBytes, "Restore must not modify or replace media")
    }

    func testArchiveImportSkipsFilesThatCannotBeMatched() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "source.mp4")
        try Data("source media".utf8).write(to: media)
        let source = try PlaybackHistoryStore(path: ":memory:")
        _ = try await source.indexMediaFile(at: media)
        let settings = MediaLibraryArchive.Settings(automaticallyPlayNext: true,
            resumeFromLastPosition: true, defaultSpeed: 1, defaultSubtitleDelay: 0)
        let archive = try await source.exportArchive(settings: settings)

        let destination = try PlaybackHistoryStore(path: ":memory:")
        let preview = try await destination.previewArchiveImport(archive)
        let result = try await destination.importArchive(archive)

        XCTAssertEqual(preview.fileCount, 1)
        XCTAssertEqual(preview.matchedFileCount, 0)
        XCTAssertEqual(preview.unmatchedFileCount, 1)
        XCTAssertEqual(result.importedFileCount, 0)
        XCTAssertEqual(result.unmatchedFileCount, 1)
        let unmatchedDestinationItems = try await destination.libraryItems(in: 1)
        XCTAssertTrue(unmatchedDestinationItems.isEmpty)
    }

    func testArchiveImportRejectsTraversalInEveryPersistedRelativePath() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        let privateFolder = root.appending(path: "Private", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: privateFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "archive-path.mp4")
        try Data("archive path fixture".utf8).write(to: media)

        let store = try PlaybackHistoryStore(path: ":memory:")
        let scan = try await store.beginScan(folder: root, includingSubfolders: true)
        _ = try await store.indexMediaFile(at: media, in: scan)
        try await store.finishScan(scan, reconcileDeletions: true, discoveredCount: 1,
                                   indexedCount: 1, skippedCount: 0)
        try await store.setHistoryExcludedFolder(privateFolder, excluded: true)
        let settings = MediaLibraryArchive.Settings(automaticallyPlayNext: true,
            resumeFromLastPosition: true, defaultSpeed: 1, defaultSubtitleDelay: 0)
        let validArchive = try await store.exportArchive(settings: settings)
        let sourceRootsBeforeImport = try await store.sourceRoots(mountedVolumeIDs: [])

        for field in ["sourceRoot", "membership", "privateFolder", "file"] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: validArchive) as? [String: Any])
            switch field {
            case "sourceRoot":
                var sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
                var roots = try XCTUnwrap(sources[0]["roots"] as? [[String: Any]])
                roots[0]["relativePath"] = "../outside"
                sources[0]["roots"] = roots
                object["sources"] = sources
            case "membership":
                var files = try XCTUnwrap(object["files"] as? [[String: Any]])
                var memberships = try XCTUnwrap(files[0]["memberships"] as? [[String: Any]])
                memberships[0]["rootPath"] = "../outside"
                files[0]["memberships"] = memberships
                object["files"] = files
            case "privateFolder":
                var folders = try XCTUnwrap(object["privateFolders"] as? [[String: Any]])
                folders[0]["relativePath"] = "../outside"
                object["privateFolders"] = folders
            case "file":
                var files = try XCTUnwrap(object["files"] as? [[String: Any]])
                files[0]["relativePath"] = "../outside"
                object["files"] = files
            default:
                XCTFail("Unexpected archive path field: \(field)")
                continue
            }
            let invalidArchive = try JSONSerialization.data(withJSONObject: object)

            do {
                _ = try await store.previewArchiveImport(invalidArchive)
                XCTFail("Preview should reject traversal in \(field)")
            } catch is MediaLibraryArchiveError { }
            do {
                _ = try await store.importArchive(invalidArchive)
                XCTFail("Import should reject traversal in \(field)")
            } catch is MediaLibraryArchiveError { }
        }

        let sourceRootsAfterImport = try await store.sourceRoots(mountedVolumeIDs: [])
        XCTAssertEqual(sourceRootsAfterImport, sourceRootsBeforeImport)
    }

    func testDestinationPrivacyRulePreventsCheckpointImport() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "private.mp4")
        try Data("private media".utf8).write(to: media)
        let settings = MediaLibraryArchive.Settings(automaticallyPlayNext: true,
            resumeFromLastPosition: true, defaultSpeed: 1, defaultSubtitleDelay: 0)
        let source = try PlaybackHistoryStore(path: ":memory:")
        try await source.save(for: media, position: 91, volume: 50)
        let archive = try await source.exportArchive(settings: settings)

        let destination = try PlaybackHistoryStore(path: ":memory:")
        try await destination.setHistoryExcludedFolder(root, excluded: true)
        _ = try await destination.importArchive(archive)

        let history = try await destination.history(for: media)
        XCTAssertNil(history)
    }

    func testImportedPrivacyDeletionSurvivesRuleRemovalAndDeferredLegacyAccess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let privateRoot = directory.appending(path: "Private")
        let sibling = directory.appending(path: "Private-other")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["active.mp4", "read.mp4", "index.mp4", "scan.mp4", "save.mp4"]
            .map { privateRoot.appending(path: $0) }
        let publicFile = sibling.appending(path: "retained.mp4")
        let bytes = Data("original media unchanged".utf8)
        for file in files + [publicFile] { try bytes.write(to: file) }
        let source = try PlaybackHistoryStore(path: ":memory:")
        try await source.setHistoryExcludedFolder(privateRoot, excluded: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try await source.exportArchive(settings: Self.testSettings)
        let base = try decoder.decode(MediaLibraryArchive.self, from: exported)
        let otherVolume = MediaLibraryArchive.PrivateFolder(volumeID: UUID().uuidString,
            relativePath: "", displayName: "Other volume")
        let archive = try MediaLibraryArchive.encodedData(for: MediaLibraryArchive(
            schemaVersion: base.schemaVersion, exportedAt: base.exportedAt, sources: base.sources,
            files: base.files, privateFolders: base.privateFolders + [otherVolume], settings: base.settings))
        let path = directory.appending(path: "history.sqlite").path
        let destination = try PlaybackHistoryStore(path: path)
        let database = try DatabaseQueue(path: path)
        try await database.write { db in
            for file in files + [publicFile] {
                try db.execute(sql: "INSERT INTO playback_history_legacy VALUES (?, 77, 3, 4, 66, 1800000000)",
                    arguments: [file.standardizedFileURL.resolvingSymlinksInPath().path])
            }
        }

        // Import must preserve deletion intent even while its source is unavailable.
        let unavailableRoot = directory.appending(path: "temporarily-unavailable")
        try FileManager.default.moveItem(at: privateRoot, to: unavailableRoot)
        _ = try await destination.importArchive(archive)
        try FileManager.default.moveItem(at: unavailableRoot, to: privateRoot)
        _ = try await destination.indexMediaFile(at: files[0])
        let activeLegacyCount = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_history_legacy WHERE file_path = ?",
                            arguments: [files[0].standardizedFileURL.resolvingSymlinksInPath().path])
        }
        XCTAssertEqual(activeLegacyCount, 0, "Access under an active rule must consume the obsolete record")
        let folders = try await destination.historyExcludedFolders()
        for folder in folders { try await destination.removeHistoryExcludedFolder(folder) }

        let reopened = try PlaybackHistoryStore(path: path)
        let readHistory = try await reopened.history(for: files[1])
        XCTAssertNil(readHistory, "Removing the rule must not revoke deletion of pre-existing legacy history")
        _ = try await reopened.indexMediaFile(at: files[2])
        let indexedHistory = try await reopened.history(for: files[2])
        XCTAssertNil(indexedHistory)
        let scan = try await reopened.beginScan(folder: privateRoot, includingSubfolders: true)
        _ = try await reopened.indexMediaFile(at: files[3], in: scan)
        try await reopened.finishScan(scan, reconcileDeletions: false, discoveredCount: 1,
                                      indexedCount: 1, skippedCount: 0)
        let scannedHistory = try await reopened.history(for: files[3])
        XCTAssertNil(scannedHistory)
        try await reopened.save(for: files[4], position: 9, volume: 50)
        let newHistory = try await reopened.history(for: files[4])
        XCTAssertEqual(newHistory?.position, 9, "New history remains allowed after privacy is disabled")
        XCTAssertNil(newHistory?.audioTrackID)
        let publicHistory = try await reopened.history(for: publicFile)
        XCTAssertEqual(publicHistory?.position, 77, "A sibling prefix must retain its old history")
        let activeHistory = try await reopened.history(for: files[0])
        XCTAssertNil(activeHistory)
        for file in files + [publicFile] { XCTAssertEqual(try Data(contentsOf: file), bytes) }
        let pendingPurges = try await database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM legacy_history_purges")
        }
        XCTAssertEqual(pendingPurges, 0, "Purge scopes are no longer needed after the last legacy row is consumed")
    }

    func testPrivacyPurgeMigrationBackfillsExistingRulesAndRollsBackOnFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let privateRoot = directory.appending(path: "Private")
        try FileManager.default.createDirectory(at: privateRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = privateRoot.appending(path: "current.mp4")
        let legacy = privateRoot.appending(path: "legacy.mp4")
        try Data("current media".utf8).write(to: current)
        try Data("legacy media".utf8).write(to: legacy)
        let source = try PlaybackHistoryStore(path: ":memory:")
        try await source.setHistoryExcludedFolder(privateRoot, excluded: true)
        let folders = try await source.historyExcludedFolders()
        let rule = try XCTUnwrap(folders.first)
        let path = directory.appending(path: "history.sqlite").path
        do {
            let store = try PlaybackHistoryStore(path: path)
            try await store.save(for: current, position: 42, volume: 50)
        }
        let database = try DatabaseQueue(path: path)
        try await database.write { db in
            // Recreate the immediately preceding schema with an already active privacy rule.
            try db.execute(sql: "DROP TABLE legacy_history_purges")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'legacyHistoryPrivacyPurges'")
            try db.execute(sql: "INSERT INTO private_media_roots VALUES (?, ?, ?)",
                           arguments: [rule.volumeID, rule.relativePath, rule.displayName])
            try db.execute(sql: "INSERT INTO playback_history_legacy VALUES (?, 77, 3, 4, 66, 1800000000)",
                           arguments: [legacy.standardizedFileURL.resolvingSymlinksInPath().path])
            try db.execute(sql: """
                CREATE TRIGGER reject_migration_purge BEFORE DELETE ON playback_history
                BEGIN SELECT RAISE(ABORT, 'forced migration purge failure'); END
                """)
        }
        XCTAssertThrowsError(try PlaybackHistoryStore(path: path)) { error in
            XCTAssertTrue(error is DatabaseError)
        }
        let failed = try await database.read { db in
            (try db.tableExists("legacy_history_purges"),
             try Double.fetchOne(db, sql: "SELECT position FROM playback_history"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_history_legacy"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM grdb_migrations WHERE identifier = 'legacyHistoryPrivacyPurges'"))
        }
        XCTAssertFalse(failed.0, "Failed migration must roll back schema creation as well as deletion")
        XCTAssertEqual(failed.1, 42)
        XCTAssertEqual(failed.2, 1)
        XCTAssertEqual(failed.3, 0)
        try await database.write { db in try db.execute(sql: "DROP TRIGGER reject_migration_purge") }

        let migrated = try PlaybackHistoryStore(path: path)
        let backfilled = try await database.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM legacy_history_purges"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_history"))
        }
        XCTAssertEqual(backfilled.0, 1)
        XCTAssertEqual(backfilled.1, 0)
        try await migrated.removeHistoryExcludedFolder(rule)
        let oldHistory = try await migrated.history(for: legacy)
        XCTAssertNil(oldHistory, "Removing a backfilled active rule cannot restore legacy history")
        try await migrated.save(for: legacy, position: 9, volume: 50)
        let newHistory = try await migrated.history(for: legacy)
        XCTAssertEqual(newHistory?.position, 9)
        try await database.write { db in
            try db.execute(sql: "INSERT INTO playback_history_legacy VALUES (?, 77, 3, 4, 66, 1800000000)",
                           arguments: [current.standardizedFileURL.resolvingSymlinksInPath().path])
        }
        try await migrated.setHistoryExcludedFolder(privateRoot, excluded: true)
        let manuallyCleared = try await database.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_history_legacy"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM legacy_history_purges"))
        }
        XCTAssertEqual(manuallyCleared.0, 0)
        XCTAssertEqual(manuallyCleared.1, 0, "Direct path deletion must also discard exhausted purge scopes")
        XCTAssertEqual(try Data(contentsOf: current), Data("current media".utf8))
        XCTAssertEqual(try Data(contentsOf: legacy), Data("legacy media".utf8))
    }

    func testImportedPrivacyRuleClearsUnmatchedHistoryAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let privateRoot = directory.appending(path: "Private")
        let sibling = directory.appending(path: "Private-other")
        try FileManager.default.createDirectory(at: privateRoot.appending(path: "Nested"),
                                                withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateFile = privateRoot.appending(path: "Nested/local-only.mp4")
        let publicFile = sibling.appending(path: "retained.mp4")
        let mediaBytes = Data("unchanged original media".utf8)
        try mediaBytes.write(to: privateFile)
        try mediaBytes.write(to: publicFile)
        let source = try PlaybackHistoryStore(path: ":memory:")
        try await source.setHistoryExcludedFolder(privateRoot, excluded: true)
        let archive = try await source.exportArchive(settings: Self.testSettings)
        let path = directory.appending(path: "destination.sqlite").path
        let destination = try PlaybackHistoryStore(path: path)
        try await destination.save(for: privateFile, position: 42, volume: 60)
        try await destination.save(for: publicFile, position: 77, volume: 70)
        let privateID = try await destination.indexMediaFile(at: privateFile)
        try await destination.setFavorite(true, for: privateID)
        let preview = try await destination.previewArchiveImport(archive)
        XCTAssertEqual(preview.matchedFileCount, 0,
                       "Imported privacy rules apply beyond files represented in the backup")
        let database = try DatabaseQueue(path: path)
        try await database.write { db in
            try db.execute(sql: "INSERT INTO playback_history_legacy VALUES (?, 99, 3, 4, 66, 1800000000)",
                           arguments: [privateFile.standardizedFileURL.resolvingSymlinksInPath().path])
            try db.execute(sql: """
                CREATE TRIGGER reject_privacy_cleanup BEFORE DELETE ON playback_history
                BEGIN SELECT RAISE(ABORT, 'forced privacy cleanup failure'); END
                """)
        }
        do {
            _ = try await destination.importArchive(archive)
            XCTFail("A failed privacy purge must abort the complete import")
        } catch is DatabaseError { }
        let preserved = try await database.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_history"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM private_media_roots"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM legacy_history_purges"),
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM playback_history_legacy"))
        }
        XCTAssertEqual(preserved.0, 2)
        XCTAssertEqual(preserved.1, 0, "The newly imported rule must roll back with failed cleanup")
        XCTAssertEqual(preserved.2, 0, "A failed import must not leave a durable purge scope behind")
        XCTAssertEqual(preserved.3, 1)
        try await database.write { db in
            try db.execute(sql: "DROP TRIGGER reject_privacy_cleanup")
        }
        _ = try await destination.importArchive(archive)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let exported = try await destination.exportArchive(settings: Self.testSettings)
        let restored = try decoder.decode(MediaLibraryArchive.self, from: exported)
        let privateRecord = try XCTUnwrap(restored.files.first { $0.relativePath.hasSuffix("local-only.mp4") })
        let publicRecord = try XCTUnwrap(restored.files.first { $0.relativePath.hasSuffix("retained.mp4") })
        XCTAssertNil(privateRecord.history, "Export must not disclose an unmatched private checkpoint")
        XCTAssertTrue(privateRecord.isFavorite)
        XCTAssertEqual(publicRecord.history?.position, 77,
                       "A similarly prefixed sibling directory must retain its checkpoint")
        let folders = try await destination.historyExcludedFolders()
        let folder = try XCTUnwrap(folders.first)
        try await destination.removeHistoryExcludedFolder(folder)
        let historyAfterRemoval = try await destination.history(for: privateFile)
        XCTAssertNil(historyAfterRemoval, "Removing the rule must not resurrect purged indexed history")
        XCTAssertEqual(try Data(contentsOf: privateFile), mediaBytes)
        XCTAssertEqual(try Data(contentsOf: publicFile), mediaBytes)
    }

    func testArchiveImportRollsBackEarlierWritesWhenARecordFails() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                     directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "rollback.mp4")
        try Data("rollback media".utf8).write(to: media)
        let databasePath = root.appending(path: "library.sqlite").path
        let store = try PlaybackHistoryStore(path: databasePath)
        let fileID = try await store.indexMediaFile(at: media)
        try await store.setFavorite(true, for: fileID)
        try await store.save(for: media, position: 17, volume: 55)
        let settings = MediaLibraryArchive.Settings(automaticallyPlayNext: true,
            resumeFromLastPosition: true, defaultSpeed: 1, defaultSubtitleDelay: 0)
        let original = try await store.exportArchive(settings: settings)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        var modified = object
        var sources = try XCTUnwrap(modified["sources"] as? [[String: Any]])
        sources[0]["displayName"] = "must roll back"
        modified["sources"] = sources
        let changedArchive = try JSONSerialization.data(withJSONObject: modified)

        let database = try DatabaseQueue(path: databasePath)
        try await database.write { db in
            try db.execute(sql: """
                CREATE TRIGGER reject_archive_history BEFORE INSERT ON playback_history
                BEGIN SELECT RAISE(ABORT, 'forced import failure'); END
                """)
        }
        do {
            _ = try await store.importArchive(changedArchive)
            XCTFail("The trigger should abort the import transaction")
        } catch {
            // The failure must roll back source updates and preference writes as well.
        }
        let rolledBackState = try await database.read { db -> (String?, Bool?) in
            let sourceName = try String.fetchOne(db, sql: "SELECT display_name FROM media_sources LIMIT 1")
            let favorite = try Bool.fetchOne(db, sql: "SELECT is_favorite FROM media_file_preferences LIMIT 1")
            return (sourceName, favorite)
        }
        let history = try await store.history(for: media)
        XCTAssertNotEqual(rolledBackState.0, "must roll back")
        XCTAssertTrue(rolledBackState.1 == true)
        XCTAssertEqual(history?.position, 17)
    }

    private func runStorageProcess(role: String, directory: URL) async throws -> [Double] {
        let logURL = directory.appending(path: "\(role)-process.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: logURL.path, contents: nil))
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest",
                           "PlaybackHistoryStoreTests/testReadOnlyStartupInSeparateProcess",
                           Bundle(for: Self.self).bundlePath]
        child.environment = ["BOMU_STORAGE_PROCESS_DIRECTORY": directory.path,
                             "BOMU_STORAGE_PROCESS_ROLE": role,
                             "TMPDIR": FileManager.default.temporaryDirectory.path]
        child.standardOutput = log
        child.standardError = log
        let exited = expectation(description: "Storage test process exits")
        child.terminationHandler = { _ in exited.fulfill() }
        try child.run()
        await fulfillment(of: [exited], timeout: 20)
        guard !child.isRunning else {
            kill(child.processIdentifier, SIGKILL)
            child.waitUntilExit()
            return []
        }
        let output = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertEqual(child.terminationStatus, 0, output)
        return try JSONDecoder().decode([Double].self,
            from: Data(contentsOf: directory.appending(path: "\(role)-result.json")))
    }

    private func makePrefixFingerprintDatabase(at databaseURL: URL, media: URL) async throws
        -> (id: Int64, archive: Data) {
        let id: Int64
        let archive: Data
        do {
            let store = try PlaybackHistoryStore(path: databaseURL.path)
            id = try await store.indexMediaFile(at: media)
            try await store.save(for: media, position: 18, volume: 50)
            try await store.setFavorite(true, for: id)
            try await store.setWatched(true, for: id)
            try await store.setManualCategory(.movie, for: id)
            archive = try await store.exportArchive(settings: Self.testSettings)
        }
        let database = try DatabaseQueue(path: databaseURL.path)
        let legacyFingerprint = try await database.read { db in
            try XCTUnwrap(String.fetchOne(db, sql: "SELECT legacy_content_fingerprint FROM media_files"))
        }
        XCTAssertEqual(legacyFingerprint, "deeb2131c0ef1fcfc2fd19625b1f1c0f79bc8e84ac691ebf7cc91c6e53b014b2",
                       "The 48 KiB fixture must retain the original prefix-only digest")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: archive) as? [String: Any])
        var files = try XCTUnwrap(json["files"] as? [[String: Any]])
        let volumeID = try XCTUnwrap(files[0]["volumeID"] as? String)
        let resourceID = try XCTUnwrap(files[0]["resourceID"] as? String)
        files[0]["contentFingerprint"] = legacyFingerprint
        files[0]["logicalID"] = "\(volumeID):\(resourceID):\(legacyFingerprint)"
        json["files"] = files
        try await database.write { db in
            try db.execute(sql: "UPDATE media_files SET content_fingerprint = legacy_content_fingerprint")
            try db.execute(sql: "ALTER TABLE media_files DROP COLUMN legacy_content_fingerprint")
            try db.execute(sql: "DELETE FROM grdb_migrations WHERE identifier = 'completeSmallFileFingerprint'")
        }
        return (id, try JSONSerialization.data(withJSONObject: json))
    }

    private func makeMediaFile(contents: Data = Data("test media".utf8)) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try contents.write(to: url)
        return url
    }

    private static let testSettings = MediaLibraryArchive.Settings(
        automaticallyPlayNext: true,
        resumeFromLastPosition: true,
        defaultSpeed: 1,
        defaultSubtitleDelay: 0
    )

    private func relativePath(of url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        let volume = (try? resolved.resourceValues(forKeys: [.volumeURLKey]).volume)?.standardizedFileURL.path ?? "/"
        return volume == "/" ? String(resolved.path.dropFirst()) : String(resolved.path.dropFirst(volume.count + 1))
    }
}
