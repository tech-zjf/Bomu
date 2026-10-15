import Foundation
import GRDB
import XCTest

final class MediaLibraryScannerTests: XCTestCase {
    func testMediaAccessibilitySummaryIncludesKnownFactsWithoutDuplicatingCodecs() {
        let item = MediaLibraryItem(id: 1, sourceRootID: 2, volumeID: "volume",
            relativePath: "feature.mp4", displayName: "feature.mp4", byteCount: 12_345,
            contentRevision: "revision", isPresent: true, isFavorite: false, isWatched: true,
            manualCategory: .movie, playbackPosition: 42, lastPlayedAt: nil, addedAt: .distantPast)
        let metadata = MediaTechnicalMetadata(duration: 65, width: 1920, height: 1080,
            videoCodec: "h264", audioTracks: [
                MediaAudioTrackMetadata(codec: "aac"), MediaAudioTrackMetadata(codec: "aac")
            ])

        let value = MediaLibraryAccessibilitySummary.value(
            for: item, isSelected: true, metadata: metadata
        )

        XCTAssertTrue(value.contains(String(localized: "library.selection.selected")))
        XCTAssertTrue(value.contains(String(localized: "library.filter.watched")))
        XCTAssertTrue(value.contains(MediaManualCategory.movie.accessibilityTitle))
        XCTAssertTrue(value.contains("1:05"))
        XCTAssertTrue(value.contains("1920 × 1080"))
        XCTAssertTrue(value.contains("h264"))
        XCTAssertEqual(value.components(separatedBy: "aac").count - 1, 1,
                       "Repeated audio codecs should be spoken only once")
        XCTAssertTrue(value.contains(ByteCountFormatStyle().format(item.byteCount)))
    }

    func testDirectoryBreadcrumbAncestorsStayWithinTheirSourceRoot() {
        let root = MediaSourceRoot(id: 7, volumeID: "volume", volumeName: "Disk",
            relativePath: "Movies", displayName: "Movies", includingSubfolders: true,
            lastSuccessfulScanAt: nil, isOnline: true)
        let rootDirectory = MediaLibraryDirectory(sourceRootID: root.id,
            relativePath: root.relativePath, displayName: root.displayName)
        let nestedDirectory = MediaLibraryDirectory(sourceRootID: root.id,
            relativePath: "Movies/Season 01/Bonus", displayName: "Bonus")
        let unrelatedDirectory = MediaLibraryDirectory(sourceRootID: root.id,
            relativePath: "Movies-Archive/Bonus", displayName: "Bonus")
        let otherRoot = MediaSourceRoot(id: 8, volumeID: "volume", volumeName: "Disk",
            relativePath: "Series", displayName: "Series", includingSubfolders: true,
            lastSuccessfulScanAt: nil, isOnline: true)

        XCTAssertTrue(rootDirectory.ancestors(relativeTo: root).isEmpty)
        XCTAssertEqual(nestedDirectory.ancestors(relativeTo: root).map(\.relativePath),
                       ["Movies/Season 01", "Movies/Season 01/Bonus"])
        XCTAssertTrue(unrelatedDirectory.ancestors(relativeTo: root).isEmpty,
                      "A similarly prefixed path must not be treated as a child of the root")
        XCTAssertTrue(nestedDirectory.ancestors(relativeTo: otherRoot).isEmpty)
    }

    func testDirectoryBreadcrumbResolvesToItsNavigationPathPrefix() {
        let root = MediaLibraryDirectory(sourceRootID: 7,
            relativePath: "Movies", displayName: "Movies")
        let season = MediaLibraryDirectory(sourceRootID: 7,
            relativePath: "Movies/Season 01", displayName: "Season 01")
        let bonus = MediaLibraryDirectory(sourceRootID: 7,
            relativePath: "Movies/Season 01/Bonus", displayName: "Bonus")
        let staleDirectory = MediaLibraryDirectory(sourceRootID: 7,
            relativePath: "Movies/Deleted", displayName: "Deleted")
        let path = [root, season, bonus]

        XCTAssertEqual(root.navigationPathPrefix(in: path), [root])
        XCTAssertEqual(season.navigationPathPrefix(in: path), [root, season])
        XCTAssertEqual(bonus.navigationPathPrefix(in: path), path)
        XCTAssertNil(staleDirectory.navigationPathPrefix(in: path))
    }

    @MainActor
    func testUnavailableLibraryStoreShowsFailureInsteadOfEmptyLibrary() async {
        let model = MediaLibraryModel(store: nil, thumbnailCache: nil)

        XCTAssertFalse(model.isStorageAvailable)
        let unavailableRefreshSucceeded = await model.refresh()
        XCTAssertFalse(unavailableRefreshSucceeded)

        XCTAssertEqual(model.errorMessage, String(localized: "library.unavailable"))
        XCTAssertTrue(model.roots.isEmpty)
        XCTAssertTrue(model.items.isEmpty)

        let startupFailure = MediaLibraryModel(store: nil, thumbnailCache: nil,
                                               startupError: "Injected database open failure.")
        let startupFailureRefreshSucceeded = await startupFailure.refresh()
        XCTAssertFalse(startupFailureRefreshSucceeded)
        XCTAssertEqual(startupFailure.errorMessage, "Injected database open failure.",
                       "Refreshing an unavailable library must preserve the initialization failure")
    }

    @MainActor
    func testLibraryRefreshReportsSuccessfulSnapshotLoad() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let model = MediaLibraryModel(store: store, thumbnailCache: nil)

        let refreshSucceeded = await model.refresh()
        XCTAssertTrue(refreshSucceeded)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testLibraryModelShowsRecentDiscoveredNamesBeforeIndexingCompletes() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = DelayedIndexingScanner()
        let model = MediaLibraryModel(store: store, thumbnailCache: nil, scanner: scanner)

        model.addFolder(URL(fileURLWithPath: "/tmp/scan-preview"))

        for _ in 0..<100 where model.discoveredCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.recentlyDiscoveredFiles,
                       (2...6).map { "film-\($0).mp4" })
        XCTAssertEqual(model.discoveredCount, 7)
        XCTAssertEqual(model.indexedCount, 0,
                       "The filename should be visible while indexing is still pending")

        for _ in 0..<100 where model.isScanning {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.indexedCount, 7)
        XCTAssertTrue(model.recentlyDiscoveredFiles.isEmpty,
                      "Transient scan previews should clear when the scan ends")
    }

    @MainActor
    func testCancellingScanClearsUnindexedFilenamePreviews() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = DelayedIndexingScanner(indexingDelay: .seconds(30))
        let model = MediaLibraryModel(store: store, thumbnailCache: nil, scanner: scanner)

        model.addFolder(URL(fileURLWithPath: "/tmp/cancelled-scan-preview"))
        for _ in 0..<100 where model.discoveredCount < 7 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.recentlyDiscoveredFiles.count, 5)

        model.cancelScan()
        for _ in 0..<100 where model.isScanning {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.isScanning)
        XCTAssertTrue(model.recentlyDiscoveredFiles.isEmpty)
        XCTAssertEqual(model.indexedCount, 0)
    }

    @MainActor
    func testRapidFolderChangesDoNotStartCancelledPendingScans() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let recorder = ScanCallRecorder()
        let model = MediaLibraryModel(store: store, thumbnailCache: nil,
                                      scanner: ImmediateRecordingScanner(recorder: recorder))
        let first = URL(fileURLWithPath: "/tmp/first-library")
        let second = URL(fileURLWithPath: "/tmp/second-library")
        let latest = URL(fileURLWithPath: "/tmp/latest-library")

        model.addFolder(first)
        model.addFolder(second)
        model.addFolder(latest)

        for _ in 0..<100 {
            if await recorder.roots().last == latest.path && !model.isScanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }

        let scannedRoots = await recorder.roots()
        XCTAssertEqual(scannedRoots, [latest.path],
                       "Cancelled tasks waiting for the previous scan must not start their own scans")
        XCTAssertFalse(model.isScanning)
    }

    func testSearchFindsLastMatchInTenThousandIndexedItems() {
        let items = (0..<10_000).map { index in
            MediaLibraryItem(id: Int64(index), sourceRootID: 1, volumeID: "volume",
                relativePath: "file-\(index).mp4", displayName: "file-\(index).mp4",
                byteCount: 1, contentRevision: "revision", isPresent: true,
                isFavorite: false, isWatched: false, manualCategory: nil,
                playbackPosition: 0, lastPlayedAt: nil, addedAt: .distantPast)
        }

        let results = MediaLibraryModel.matchingItems(in: items, query: "file-9999")

        XCTAssertEqual(results.map(\.id), [9_999])
    }

    func testTenThousandItemSearchPerformance() {
        let items = (0..<10_000).map { index in
            makeLibraryItem(id: Int64(index), name: "media item \(index).mp4",
                            category: nil, watched: false)
        }

        measure {
            XCTAssertEqual(MediaLibraryModel.matchingItems(in: items, query: "media item 9999").count, 1)
        }
    }

    @MainActor
    func testDatabaseBackedTenThousandItemLibraryRefreshAndSearch() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                         directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let mediaRoot = directory.appending(path: "Library", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mediaRoot, withIntermediateDirectories: true)
        try Data("seed".utf8).write(to: mediaRoot.appending(path: "seed.mp4"))

        let databasePath = directory.appending(path: "library.sqlite").path
        let store = try PlaybackHistoryStore(path: databasePath)
        let scanner = MediaLibraryScanner(historyStore: store)
        for try await _ in scanner.scan(folder: mediaRoot) { }

        let database = try DatabaseQueue(path: databasePath)
        try await database.write { db in
            guard let seed = try Row.fetchOne(db, sql: """
                SELECT media_files.volume_id, media_files.content_revision,
                       media_source_files.source_root_id, media_source_files.last_seen_scan_id,
                       media_source_files.last_seen_at, media_source_files.added_at
                FROM media_files
                JOIN media_source_files ON media_source_files.media_file_id = media_files.id
                LIMIT 1
                """) else {
                throw TestFailure.missingSeedMedia
            }

            let volumeID: String = seed["volume_id"]
            let revision: String = seed["content_revision"]
            let sourceRootID: Int64 = seed["source_root_id"]
            let scanID: String = seed["last_seen_scan_id"]
            let lastSeenAt: Double = seed["last_seen_at"]
            let addedAt: Double = seed["added_at"]

            for index in 0..<9_999 {
                try db.execute(sql: """
                    INSERT INTO media_files
                        (volume_id, resource_id, content_revision, relative_path, byte_count, modified_at)
                    VALUES (?, ?, ?, ?, 1, ?)
                    """, arguments: [volumeID, "benchmark-\(index)", revision,
                                     "media item \(index).mp4", lastSeenAt])
                let mediaFileID = db.lastInsertedRowID
                try db.execute(sql: """
                    INSERT INTO media_source_files
                        (source_root_id, media_file_id, last_seen_scan_id, is_present,
                         last_seen_at, added_at)
                    VALUES (?, ?, ?, 1, ?, ?)
                    """, arguments: [sourceRootID, mediaFileID, scanID, lastSeenAt, addedAt])
            }
        }

        let model = MediaLibraryModel(store: store, thumbnailCache: nil)
        let clock = ContinuousClock()
        await model.refresh()
        XCTAssertEqual(model.items.count, 10_000)

        var refreshSamples: [Double] = []
        for _ in 0..<5 {
            let startedAt = clock.now
            await model.refresh()
            refreshSamples.append(Self.milliseconds(startedAt.duration(to: clock.now)))
        }
        XCTAssertEqual(model.items.count, 10_000)

        let searchSamples = (0..<10).map { _ -> Double in
            let startedAt = clock.now
            let results = MediaLibraryModel.matchingItems(in: model.items, query: "media item 9998")
            let elapsed = Self.milliseconds(startedAt.duration(to: clock.now))
            XCTAssertEqual(results.map(\.displayName), ["media item 9998.mp4"])
            return elapsed
        }
        let refreshAverage = refreshSamples.reduce(0, +) / Double(refreshSamples.count)
        let searchAverage = searchSamples.reduce(0, +) / Double(searchSamples.count)
        let measurements = "SQLite-backed refresh: mean \(refreshAverage) ms over 5 runs; "
            + "in-memory search over the loaded SQLite rows: mean \(searchAverage) ms over 10 runs."
        XCTContext.runActivity(named: measurements) { activity in
            let attachment = XCTAttachment(string: measurements)
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000
    }

    private enum TestFailure: Error {
        case missingSeedMedia
    }

    private struct DelayedIndexingScanner: MediaLibraryScanning {
        let indexingDelay: Duration

        init(indexingDelay: Duration = .milliseconds(250)) {
            self.indexingDelay = indexingDelay
        }

        func scan(folder root: URL, includingSubfolders: Bool) -> AsyncThrowingStream<MediaLibraryScanEvent, Error> {
            let candidates = (0..<7).map { index in
                let name = "film-\(index).mp4"
                return MediaLibraryCandidate(
                    url: root.appending(path: name),
                    displayName: name,
                    relativePath: name
                )
            }
            return AsyncThrowingStream { continuation in
                for candidate in candidates {
                    continuation.yield(.discovered(candidate))
                }
                let task = Task {
                    do {
                        try await Task.sleep(for: indexingDelay)
                        for (index, candidate) in candidates.enumerated() {
                            continuation.yield(.indexed(candidate, mediaFileID: Int64(index + 1)))
                        }
                        continuation.yield(.completed(.init(discoveredCount: candidates.count,
                                                              indexedCount: candidates.count,
                                                              skippedCount: 0, reconciledDeletions: true)))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private actor ScanCallRecorder {
        private var recordedRoots: [String] = []

        func record(_ root: String) {
            recordedRoots.append(root)
        }

        func roots() -> [String] { recordedRoots }
    }

    private struct ImmediateRecordingScanner: MediaLibraryScanning {
        let recorder: ScanCallRecorder

        func scan(folder root: URL, includingSubfolders: Bool) -> AsyncThrowingStream<MediaLibraryScanEvent, Error> {
            Task { await recorder.record(root.path) }
            return AsyncThrowingStream { continuation in
                continuation.yield(.completed(.init(discoveredCount: 0, indexedCount: 0,
                                                       skippedCount: 0, reconciledDeletions: true)))
                continuation.finish()
            }
        }
    }

    func testCategoryAndWatchedFiltersKeepUnclassifiedItemsExplicit() {
        let items = [
            makeLibraryItem(id: 1, name: "movie.mp4", category: .movie, watched: true),
            makeLibraryItem(id: 2, name: "episode.mkv", category: .series, watched: false),
            makeLibraryItem(id: 3, name: "recording.mov", category: nil, watched: false)
        ]

        let series = MediaLibraryModel.filtering(items, category: .category(.series), watched: .unwatched)
        let unclassified = MediaLibraryModel.filtering(items, category: .unclassified, watched: .all)

        XCTAssertEqual(series.map(\.displayName), ["episode.mkv"])
        XCTAssertEqual(unclassified.map(\.displayName), ["recording.mov"])
    }

    func testDeduplicatingLibraryItemsPreservesOrderAndKeepsEarliestSource() {
        let firstSeen = Date(timeIntervalSince1970: 20)
        let earliest = Date(timeIntervalSince1970: 10)
        let last = Date(timeIntervalSince1970: 30)
        let items = [
            makeLibraryItem(id: 9, name: "first-root/movie.mp4", category: nil,
                            watched: false, addedAt: firstSeen),
            makeLibraryItem(id: 3, name: "second.mp4", category: nil,
                            watched: false, addedAt: last),
            makeLibraryItem(id: 9, name: "earlier-root/movie.mp4", category: nil,
                            watched: false, addedAt: earliest),
            makeLibraryItem(id: 5, name: "third.mp4", category: nil,
                            watched: false, addedAt: last)
        ]

        let result = MediaLibraryModel.deduplicatingItems(items)

        XCTAssertEqual(result.map(\.id), [9, 3, 5])
        XCTAssertEqual(result.map(\.relativePath), ["earlier-root/movie.mp4", "second.mp4", "third.mp4"])
    }

    func testDeduplicatingLibraryItemsPrefersPresentSourceMembership() {
        let earlier = Date(timeIntervalSince1970: 10)
        let later = Date(timeIntervalSince1970: 20)
        let absentMembership = makeLibraryItem(id: 4, name: "movie.mp4", category: nil,
            watched: false, addedAt: earlier, isPresent: false, sourceRootID: 1)
        let presentMembership = makeLibraryItem(id: 4, name: "movie.mp4", category: nil,
            watched: false, addedAt: later, isPresent: true, sourceRootID: 2)

        let result = MediaLibraryModel.deduplicatingItems([absentMembership, presentMembership])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.sourceRootID, 2,
                       "A stale source membership must not hide a file still present in another root")
        XCTAssertEqual(result.first?.isPresent, true)
    }

    private func makeLibraryItem(
        id: Int64,
        name: String,
        category: MediaManualCategory?,
        watched: Bool,
        addedAt: Date = .distantPast,
        isPresent: Bool = true,
        sourceRootID: Int64 = 1
    ) -> MediaLibraryItem {
        MediaLibraryItem(id: id, sourceRootID: sourceRootID, volumeID: "volume", relativePath: name,
            displayName: name, byteCount: 1, contentRevision: "revision", isPresent: isPresent,
            isFavorite: false, isWatched: watched, manualCategory: category,
            playbackPosition: 0, lastPlayedAt: nil, addedAt: addedAt)
    }

    @MainActor
    func testLibraryModelBuildsNestedFoldersAndKeepsFilesAtTheirOwnLevel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                    directoryHint: .isDirectory)
        let season = root.appending(path: "Season 01", directoryHint: .isDirectory)
        let bonus = season.appending(path: "Bonus", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bonus, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("root".utf8).write(to: root.appending(path: "trailer.mp4"))
        try Data("episode".utf8).write(to: season.appending(path: "Episode 02.mkv"))
        try Data("bonus".utf8).write(to: bonus.appending(path: "Behind the scenes.mov"))

        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)
        for try await _ in scanner.scan(folder: root) { }
        let model = MediaLibraryModel(store: store, thumbnailCache: nil)
        await model.refresh()

        let source = try XCTUnwrap(model.onlineRoots.first)
        let sourceDirectory = MediaLibraryDirectory(sourceRootID: source.id,
            relativePath: source.relativePath, displayName: source.displayName)
        let seasonDirectory = try XCTUnwrap(model.childDirectories(in: sourceDirectory).first)
        let bonusDirectory = try XCTUnwrap(model.childDirectories(in: seasonDirectory).first)

        XCTAssertEqual(seasonDirectory.displayName, "Season 01")
        XCTAssertEqual(bonusDirectory.displayName, "Bonus")
        XCTAssertEqual(model.mediaItems(in: sourceDirectory).map(\.displayName), ["trailer.mp4"])
        XCTAssertEqual(model.mediaItems(in: seasonDirectory).map(\.displayName), ["Episode 02.mkv"])
        XCTAssertEqual(model.mediaItems(in: bonusDirectory).map(\.displayName), ["Behind the scenes.mov"])
    }

    @MainActor
    func testSelectedMediaRemainsSelectedAcrossLibraryRefresh() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                    directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("selected media".utf8).write(to: root.appending(path: "selected.mp4"))
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)
        for try await _ in scanner.scan(folder: root) { }
        let model = MediaLibraryModel(store: store, thumbnailCache: nil)
        await model.refresh()
        let item = try XCTUnwrap(model.items.first)

        model.select(item)
        await model.refresh()

        XCTAssertEqual(model.selectedItemID, item.id)
    }

    @MainActor
    func testAvailableItemsExcludeMediaRemovedByCompleteScan() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let availableURL = root.appending(path: "available.mp4")
        let removedURL = root.appending(path: "removed.mp4")
        try Data("available".utf8).write(to: availableURL)
        try Data("removed".utf8).write(to: removedURL)

        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)
        for try await _ in scanner.scan(folder: root) { }
        try FileManager.default.removeItem(at: removedURL)
        for try await _ in scanner.scan(folder: root) { }

        let model = MediaLibraryModel(store: store, thumbnailCache: nil)
        let refreshed = await model.refresh()
        XCTAssertTrue(refreshed)
        XCTAssertEqual(model.availableItems.map(\.displayName), ["available.mp4"])
        XCTAssertEqual(model.items.first(where: { $0.displayName == "removed.mp4" })?.isPresent, false,
                       "A reconciled membership stays in history without appearing in the active library")
    }

    @MainActor
    func testLaunchReconciliationRecoversChangesWithoutAFileEvent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("initial".utf8).write(to: root.appending(path: "initial.mp4"))

        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)
        for try await _ in scanner.scan(folder: root) { }

        let model = MediaLibraryModel(store: store, thumbnailCache: nil)
        await model.refresh()
        XCTAssertEqual(model.items.map(\.displayName), ["initial.mp4"])

        try Data("new media".utf8).write(to: root.appending(path: "new.mp4"))
        let reconciled = expectation(description: "reconciliation refreshes the library model")
        let coordinator = MediaLibrarySyncCoordinator(historyStore: store) {
            await model.refresh()
            reconciled.fulfill()
        }

        coordinator.start()
        await fulfillment(of: [reconciled], timeout: 10)

        XCTAssertEqual(Set(model.items.map(\.displayName)), ["initial.mp4", "new.mp4"])
        await coordinator.stop()
    }

    @MainActor
    func testEmptyDirectoriesAreNavigableAndRemovedAfterACompleteRescan() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                    directoryHint: .isDirectory)
        let empty = root.appending(path: "Empty folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)
        for try await _ in scanner.scan(folder: root) { }
        let model = MediaLibraryModel(store: store, thumbnailCache: nil)
        await model.refresh()

        let source = try XCTUnwrap(model.onlineRoots.first)
        let sourceDirectory = MediaLibraryDirectory(sourceRootID: source.id,
            relativePath: source.relativePath, displayName: source.displayName)
        let emptyDirectory = try XCTUnwrap(model.childDirectories(in: sourceDirectory).first)
        XCTAssertEqual(emptyDirectory.displayName, "Empty folder")
        XCTAssertTrue(model.childDirectories(in: emptyDirectory).isEmpty)
        XCTAssertTrue(model.mediaItems(in: emptyDirectory).isEmpty)

        try FileManager.default.removeItem(at: empty)
        for try await _ in scanner.scan(folder: root) { }
        await model.refresh()
        XCTAssertTrue(model.childDirectories(in: sourceDirectory).isEmpty)
    }

    func testMediaNamesArePublishedBeforeEachFileIsIndexed() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("movie".utf8).write(to: root.appending(path: "旅行 1.mp4"))
        try Data("audio".utf8).write(to: root.appending(path: "song.m4a"))
        try Data("document".utf8).write(to: root.appending(path: "notes.txt"))
        let nested = root.appending(path: "Season 1", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("episode".utf8).write(to: nested.appending(path: "第 2 集.mkv"))
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)

        var events: [MediaLibraryScanEvent] = []
        for try await event in scanner.scan(folder: root) {
            events.append(event)
        }

        let candidates = events.compactMap { event -> MediaLibraryCandidate? in
            guard case .discovered(let candidate) = event else { return nil }
            return candidate
        }
        XCTAssertEqual(Set(candidates.map(\.displayName)), ["旅行 1.mp4", "song.m4a", "第 2 集.mkv"])
        XCTAssertFalse(candidates.contains { $0.displayName == "notes.txt" })
        for candidate in candidates {
            let discoveredIndex = try XCTUnwrap(events.firstIndex(of: .discovered(candidate)))
            let indexedIndex = try XCTUnwrap(events.firstIndex { event in
                guard case .indexed(let indexed, _) = event else { return false }
                return indexed == candidate
            })
            XCTAssertLessThan(discoveredIndex, indexedIndex)
        }
        XCTAssertEqual(events.last, .completed(.init(discoveredCount: 3, indexedCount: 3,
                                                    skippedCount: 0, reconciledDeletions: true)))
    }

    func testUnavailableRootDoesNotDeleteExistingHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let media = directory.appending(path: "kept.mp4")
        try Data("kept".utf8).write(to: media)
        let store = try PlaybackHistoryStore(path: ":memory:")
        try await store.save(for: media, position: 42, volume: 70)
        let scanner = MediaLibraryScanner(historyStore: store)
        let missingRoot = directory.appending(path: "offline", directoryHint: .isDirectory)

        do {
            for try await _ in scanner.scan(folder: missingRoot) { }
            XCTFail("An unavailable source must fail explicitly")
        } catch is MediaLibraryScanError {
            // Existing library data is not reconciled from a failed scan.
        }

        let retained = try await store.history(for: media)
        XCTAssertEqual(retained?.position, 42)
    }

    func testNonRecursiveScanSkipsNestedDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("root".utf8).write(to: root.appending(path: "root.mp4"))
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: nested.appending(path: "nested.mp4"))
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)

        var discovered: [String] = []
        for try await event in scanner.scan(folder: root, includingSubfolders: false) {
            if case .discovered(let candidate) = event { discovered.append(candidate.displayName) }
        }

        XCTAssertEqual(discovered, ["root.mp4"])
    }

    func testScanDoesNotFollowSymbolicLinksOutsideTheSelectedSource() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                       directoryHint: .isDirectory)
        let root = parent.appending(path: "Library", directoryHint: .isDirectory)
        let external = parent.appending(path: "Outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        try Data("inside".utf8).write(to: root.appending(path: "inside.mp4"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "inside-alias.mp4"),
                                                   withDestinationURL: root.appending(path: "inside.mp4"))
        try Data("outside file".utf8).write(to: external.appending(path: "outside-file.mp4"))
        try Data("outside folder".utf8).write(to: external.appending(path: "outside-folder.mov"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked-file.mp4"),
                                                   withDestinationURL: external.appending(path: "outside-file.mp4"))
        try FileManager.default.createSymbolicLink(at: root.appending(path: "linked-folder"),
                                                   withDestinationURL: external)
        let scanner = MediaLibraryScanner(historyStore: try PlaybackHistoryStore(path: ":memory:"))

        var events: [MediaLibraryScanEvent] = []
        for try await event in scanner.scan(folder: root) { events.append(event) }

        let discovered = events.compactMap { event -> String? in
            guard case .discovered(let candidate) = event else { return nil }
            return candidate.displayName
        }
        XCTAssertEqual(discovered, ["inside.mp4"])
        XCTAssertEqual(events.last, .completed(.init(discoveredCount: 1, indexedCount: 1,
                                                    skippedCount: 0, reconciledDeletions: true)))
    }

    func testOnlyCompleteScanMarksDeletedFilesAbsentAndOfflineRootRemainsVisible() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let currentFile = root.appending(path: "current.mp4")
        let removedFile = root.appending(path: "removed.mp4")
        try Data("current".utf8).write(to: currentFile)
        try Data("removed".utf8).write(to: removedFile)
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)
        for try await _ in scanner.scan(folder: root) { }
        let saved = try await store.sourceRoots(mountedVolumeIDs: [])
        let sourceRoot = try XCTUnwrap(saved.first)
        let onlineRoots = try await store.sourceRoots(mountedVolumeIDs: [sourceRoot.volumeID])
        XCTAssertEqual(onlineRoots.first?.isOnline, true)
        XCTAssertEqual(sourceRoot.isOnline, false)
        try FileManager.default.removeItem(at: removedFile)

        for try await _ in scanner.scan(folder: root) { }

        let items = try await store.libraryItems(in: sourceRoot.id)
        XCTAssertEqual(items.first(where: { $0.displayName == "current.mp4" })?.isPresent, true)
        XCTAssertEqual(items.first(where: { $0.displayName == "removed.mp4" })?.isPresent, false)
        XCTAssertEqual(items.first(where: { $0.displayName == "removed.mp4" })?.relativePath,
                       sourceRoot.relativePath.isEmpty ? "removed.mp4" : "\(sourceRoot.relativePath)/removed.mp4")
    }

    func testReconciliationTracksMovedFileWithoutLosingPlaybackHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let original = root.appending(path: "before.mp4")
        let moved = root.appending(path: "Subfolder/after.mp4")
        try Data("same media identity".utf8).write(to: original)
        let store = try PlaybackHistoryStore(path: ":memory:")
        let scanner = MediaLibraryScanner(historyStore: store)
        for try await _ in scanner.scan(folder: root) { }
        try await store.save(for: original, position: 42, volume: 80)

        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: original, to: moved)
        for try await _ in scanner.scan(folder: root) { }

        let rootRecords = try await store.sourceRoots(mountedVolumeIDs: [])
        let sourceRoot = try XCTUnwrap(rootRecords.first)
        let items = try await store.libraryItems(in: sourceRoot.id)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.relativePath,
                       sourceRoot.relativePath.isEmpty ? "Subfolder/after.mp4"
                                                       : "\(sourceRoot.relativePath)/Subfolder/after.mp4")
        XCTAssertEqual(items.first?.isPresent, true)
        let restored = try await store.history(for: moved)
        XCTAssertEqual(restored?.position, 42)
    }

    func testPartialScanDoesNotMarkPreviouslySeenFilesAbsent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "kept.mp4")
        try Data("kept".utf8).write(to: media)
        let store = try PlaybackHistoryStore(path: ":memory:")
        let firstScan = try await store.beginScan(folder: root, includingSubfolders: true)
        _ = try await store.indexMediaFile(at: media, in: firstScan)
        try await store.finishScan(firstScan, reconcileDeletions: true,
                                   discoveredCount: 1, indexedCount: 1, skippedCount: 0)

        let interruptedScan = try await store.beginScan(folder: root, includingSubfolders: true)
        try await store.finishScan(interruptedScan, reconcileDeletions: false,
                                   discoveredCount: 0, indexedCount: 0, skippedCount: 1)

        let roots = try await store.sourceRoots(mountedVolumeIDs: [])
        let sourceRoot = try XCTUnwrap(roots.first)
        let items = try await store.libraryItems(in: sourceRoot.id)
        XCTAssertEqual(items.first?.isPresent, true)
    }

    func testConcurrentScansOfOneRootAreRejectedBeforeTheyCanRaceReconciliation() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let media = root.appending(path: "kept.mp4")
        try Data("kept".utf8).write(to: media)
        let store = try PlaybackHistoryStore(path: ":memory:")
        let activeScan = try await store.beginScan(folder: root, includingSubfolders: true)

        do {
            _ = try await store.beginScan(folder: root, includingSubfolders: true)
            XCTFail("Overlapping scans can mark each other's files absent")
        } catch PlaybackHistoryError.scanAlreadyRunning { }

        _ = try await store.indexMediaFile(at: media, in: activeScan)
        try await store.finishScan(activeScan, reconcileDeletions: true,
                                   discoveredCount: 1, indexedCount: 1, skippedCount: 0)
        let items = try await store.libraryItems(in: activeScan.sourceRootID)
        XCTAssertEqual(items.first?.isPresent, true)
    }

    func testOpeningStoreRecoversAnInterruptedScanFromPreviousProcess() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appending(path: "library.sqlite").path
        let firstStore = try PlaybackHistoryStore(path: databasePath)
        _ = try await firstStore.beginScan(folder: directory, includingSubfolders: true)

        let recoveredStore = try PlaybackHistoryStore(path: databasePath)
        let nextScan = try await recoveredStore.beginScan(folder: directory, includingSubfolders: true)
        try await recoveredStore.finishScan(nextScan, reconcileDeletions: false,
                                            discoveredCount: 0, indexedCount: 0, skippedCount: 1)
    }

    func testCancellationLeavesPreviousCheckpointUntouched() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appending(path: "existing.mp4")
        try Data("existing".utf8).write(to: existing)
        let store = try PlaybackHistoryStore(path: ":memory:")
        try await store.save(for: existing, position: 64, volume: 80)
        for index in 0..<500 {
            try Data("candidate \(index)".utf8).write(to: directory.appending(path: "new-\(index).mp4"))
        }
        let scanner = MediaLibraryScanner(historyStore: store)
        let consume = Task {
            for try await event in scanner.scan(folder: directory) {
                if case .discovered = event { throw CancellationError() }
            }
        }

        do {
            try await consume.value
            XCTFail("The consumer should stop after its first discovered filename")
        } catch is CancellationError { }

        let retained = try await store.history(for: existing)
        XCTAssertEqual(retained?.position, 64)
    }
}
