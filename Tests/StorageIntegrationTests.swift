import Darwin
import Foundation
import GRDB
import XCTest

/// Explicit opt-in acceptance against disposable volumes; never touches a user's disk.
final class StorageIntegrationTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BOMU_STORAGE_INTEGRATION"] == "1",
                          "Run scripts/test-dev.sh --direct-storage for disposable-volume acceptance")
    }

    func testRemountedVolumePreservesIdentityAndHistory() async throws {
        let volume = try TestDiskVolume()
        defer { volume.cleanup() }
        let spacer = try TestDiskVolume(mountImmediately: false)
        defer { spacer.cleanup() }
        let databaseURL = volume.directory.appending(path: "history.sqlite")
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        let media = volume.mountPoint.appending(path: "before.mp4")
        let bytes = Data("Bomu disposable remount fixture".utf8)
        try bytes.write(to: media)
        let id = try await store.indexMediaFile(at: media)
        try await store.save(for: media, position: 42, volume: 67)
        try await store.setFavorite(true, for: id)
        var before = stat()
        XCTAssertEqual(media.path.withCString { stat($0, &before) }, 0)
        let volumeID = try media.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString

        try volume.unmount()
        try spacer.mount()
        try volume.mount()
        let renamed = volume.mountPoint.appending(path: "after.mp4")
        try FileManager.default.moveItem(at: media, to: renamed)
        var after = stat()
        XCTAssertEqual(renamed.path.withCString { stat($0, &after) }, 0)
        print("Storage acceptance: device \(before.st_dev) → \(after.st_dev), inode \(before.st_ino) → \(after.st_ino)")
        XCTAssertNotEqual(before.st_dev, after.st_dev, "The test must exercise a changed device number")
        XCTAssertEqual(before.st_ino, after.st_ino)
        XCTAssertEqual(try renamed.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString, volumeID)
        let history = try await store.history(for: renamed)
        XCTAssertEqual(history?.mediaFileID, id)
        XCTAssertEqual(history?.position, 42)
        XCTAssertEqual(try Data(contentsOf: renamed), bytes)
        let archive = try await store.exportArchive(settings: Self.settings)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MediaLibraryArchive.self, from: archive).files.first?.isFavorite, true)
    }

    func testFullVolumePreservesCommittedCheckpointAndRecovers() async throws {
        let volume = try TestDiskVolume()
        defer { volume.cleanup() }
        try await verifyFullVolume(volume)
    }

    private func verifyFullVolume(_ volume: TestDiskVolume) async throws {
        let media = volume.directory.appending(path: "media.mp4")
        try Data("read-only checkpoint media".utf8).write(to: media)
        let databaseURL = volume.mountPoint.appending(path: "history.sqlite")
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        try await store.save(for: media, position: 12, volume: 70)
        // Checkpoint the WAL so the next save must allocate on the test volume.
        let database = try DatabaseQueue(path: databaseURL.path)
        try await database.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
        }
        let filler = volume.mountPoint.appending(path: "filler.bin")
        let handle = try FileHandle(forWritingTo: Self.createEmptyFile(at: filler))
        var reachedCapacity = false
        let block = Data(repeating: 0xA5, count: 64 * 1_024)
        for _ in 0..<2_048 {
            do { try handle.write(contentsOf: block) }
            catch {
                guard Self.isDiskFull(error) else { throw error }
                reachedCapacity = true
                break
            }
        }
        try handle.close()
        XCTAssertTrue(reachedCapacity, "The bounded 64 MiB test volume must run out of capacity")
        var lastCommittedPosition = 12.0
        var storageFailure: ResultCode?
        // APFS may retain a few writable blocks after the filler hits ENOSPC. Grow the
        // real checkpoint WAL within a bounded budget until SQLite itself reports failure.
        for position in 13...268 {
            do {
                try await store.save(for: media, position: Double(position), volume: 30)
                lastCommittedPosition = Double(position)
            } catch let error as DatabaseError {
                storageFailure = error.resultCode
                print("Storage acceptance: exhausted-volume SQLite result = \(error.resultCode)")
                break
            }
        }
        let code = try XCTUnwrap(storageFailure, "The test must observe a real SQLite storage-capacity failure")
        XCTAssertTrue([ResultCode.SQLITE_FULL, ResultCode.SQLITE_IOERR].contains(code))
        let expectedPosition = lastCommittedPosition
        try await database.read { db in
            XCTAssertEqual(try Double.fetchOne(db, sql: "SELECT position FROM playback_history"), expectedPosition)
        }
        try FileManager.default.removeItem(at: filler)
        try await store.save(for: media, position: 88, volume: 30)
        let recovered = try await store.history(for: media)
        XCTAssertEqual(recovered?.position, 88)
        XCTAssertEqual(recovered?.volume, 30)
    }

    private static func isDiskFull(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain, error.code == Int(ENOSPC) { return true }
        if error.domain == NSCocoaErrorDomain, error.code == CocoaError.fileWriteOutOfSpace.rawValue { return true }
        guard let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error else { return false }
        return isDiskFull(underlying)
    }

    private static func createEmptyFile(at url: URL) throws -> URL {
        try Data().write(to: url)
        return url
    }

    private static let settings = MediaLibraryArchive.Settings(automaticallyPlayNext: true,
        resumeFromLastPosition: true, defaultSpeed: 1, defaultSubtitleDelay: 0)
}

private final class TestDiskVolume {
    let directory: URL
    let mountPoint: URL
    private let image: URL
    private var device: String?

    init(mountImmediately: Bool = true) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "bomu-storage-\(UUID().uuidString)").resolvingSymlinksInPath()
        mountPoint = directory.appending(path: "mount")
        image = directory.appending(path: "test.sparseimage")
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: FileManager.default.temporaryDirectory.path)
        let available = try XCTUnwrap(attributes[.systemFreeSize] as? NSNumber).uint64Value
        try XCTSkipUnless(available >= 256 * 1_024 * 1_024, "Disposable volumes require 256 MiB of host free space")
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        do {
            _ = try run(["create", "-size", "64m", "-type", "SPARSE", "-fs", "APFS",
                         "-volname", "BomuStorageTest", image.path])
            if mountImmediately { try mount() }
        } catch {
            cleanup()
            throw error
        }
    }

    func mount() throws {
        guard device == nil else { return }
        let data = try run(["attach", "-nobrowse", "-plist", "-mountpoint", mountPoint.path, image.path])
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let entities = try XCTUnwrap(plist["system-entities"] as? [[String: Any]])
        device = entities.first { ($0["content-hint"] as? String) == "GUID_partition_scheme" }?["dev-entry"] as? String
        _ = try XCTUnwrap(device, "The image's own device is required for cleanup")
        let mountedAtExpectedPath = entities.contains { entity in
            guard let path = entity["mount-point"] as? String else { return false }
            return URL(fileURLWithPath: path).resolvingSymlinksInPath().path == mountPoint.path
        }
        guard mountedAtExpectedPath else {
            throw NSError(domain: "BomuStorageTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The disposable volume mounted at an unexpected path."])
        }
    }

    func unmount() throws {
        guard let device else { return }
        _ = try run(["detach", device])
        self.device = nil
    }

    func cleanup() {
        do {
            try unmount()
            var parent = stat()
            var mount = stat()
            if directory.path.withCString({ stat($0, &parent) }) == 0,
               mountPoint.path.withCString({ stat($0, &mount) }) == 0,
               parent.st_dev != mount.st_dev {
                XCTFail("Disposable volume remains mounted; retained \(directory.path) for cleanup")
                return
            }
            try FileManager.default.removeItem(at: directory)
        } catch {
            XCTFail("Disposable volume cleanup failed at \(directory.path): \(error)")
        }
    }

    private func run(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                               "TMPDIR": FileManager.default.temporaryDirectory.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "BomuStorageTest", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        return data
    }
}
