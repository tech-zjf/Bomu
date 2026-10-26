import CryptoKit
import Foundation
import GRDB

/// Startup-only snapshots. The store remains the connection and migration owner.
/// Each target schema keeps its first pre-migration image so retries after a
/// partially completed upgrade cannot overwrite the original recovery point.
struct DatabaseMigrationBackup: Sendable {
    let directory: URL

    init?(databasePath: String) {
        guard databasePath != ":memory:" else { return nil }
        directory = URL(filePath: databasePath + ".migration-backups", directoryHint: .isDirectory)
    }

    func migrate(_ database: DatabaseQueue, using migrator: DatabaseMigrator) throws {
        let needsBackup = try database.read { db in
            guard try !migrator.hasBeenSuperseded(db) else { throw BackupError.newerSchema }
            guard try !migrator.hasCompletedMigrations(db) else { return false }
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                """) != 0
        }
        if needsBackup {
            try capture(database, targetMigrations: migrator.migrations)
        }
        try migrator.migrate(database)
        // A failed upgrade retains all recovery points. Only successful upgrades
        // prune older images; normal startup does not produce another snapshot.
        if needsBackup { try prune() }
    }

    /// Privacy intent also applies to automatic copies, before modifying live data.
    /// Failure to delete a copy is reported rather than claiming a complete purge.
    func discard() throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    private func capture(_ database: DatabaseQueue, targetMigrations: [String]) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let target = SHA256.hash(data: Data(targetMigrations.joined(separator: "\n").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let destination = directory.appending(path: target + ".sqlite")
        if manager.fileExists(atPath: destination.path) {
            var configuration = Configuration()
            configuration.readonly = true
            let existing = try DatabaseQueue(path: destination.path, configuration: configuration)
            try validate(existing)
            try existing.close()
            return
        }

        let temporary = directory.appending(path: UUID().uuidString + ".partial")
        defer {
            for suffix in ["", "-wal", "-shm", "-journal"] {
                try? manager.removeItem(atPath: temporary.path + suffix)
            }
        }
        guard manager.createFile(atPath: temporary.path, contents: nil,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path])
        }
        let snapshot = try DatabaseQueue(path: temporary.path)
        // SQLite's backup API includes committed WAL pages; copying the main file does not.
        try database.backup(to: snapshot)
        try snapshot.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = DELETE")
        }
        try validate(snapshot)
        try snapshot.close()
        try manager.moveItem(at: temporary, to: destination)
    }

    private func validate(_ database: DatabaseQueue) throws {
        let results = try database.read { db in
            try String.fetchAll(db, sql: "PRAGMA quick_check")
        }
        guard results == ["ok"] else { throw BackupError.invalidSnapshot }
    }

    private func prune() throws {
        let manager = FileManager.default
        let snapshots = try manager.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey])
            .filter { Self.ownsSnapshot($0) }
            .map { ($0, try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) }
            .sorted { ($0.1 ?? .distantPast) > ($1.1 ?? .distantPast) }
        for (url, _) in snapshots.dropFirst(2) { try manager.removeItem(at: url) }
    }

    private static func ownsSnapshot(_ url: URL) -> Bool {
        guard url.pathExtension == "sqlite",
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return false }
        let digest = url.deletingPathExtension().lastPathComponent.utf8
        return digest.count == 64 && digest.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private enum BackupError: LocalizedError {
        case invalidSnapshot
        case newerSchema
        var errorDescription: String? {
            switch self {
            case .invalidSnapshot: String(localized: "persistence.invalidMigrationBackup")
            case .newerSchema: String(localized: "persistence.newerDatabaseSchema")
            }
        }
    }
}
