import GRDB
import XCTest

@MainActor
final class PlayerModelTests: XCTestCase {
    func testMenuCommandsCannotAffectReplacementQueueOrPlaybackSpeed() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["old-1.mp4", "old-2.mp4", "new-1.mp4", "new-2.mp4"]
            .map { directory.appending(path: $0) }
        for file in files { try Data().write(to: file) }

        player.open(Array(files.prefix(2)))
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let oldID = try XCTUnwrap(player.state.request?.id)
        let selectOldMenuItem = { player.playQueueItem(at: 1, requestID: oldID) }
        let selectOldSpeed = { player.setSpeed(2, requestID: oldID) }

        player.open(Array(files.suffix(2)))
        try await waitUntil { engine.requests.count == 2 }
        let newID = try XCTUnwrap(player.state.request?.id)
        engine.onEvent?(.loaded(newID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: newID, pauseCommandID: 0,
            position: 0, duration: 60, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 80)))
        let speedsBefore = engine.speeds
        selectOldMenuItem()
        selectOldSpeed()
        XCTAssertEqual(player.state.request?.id, newID)
        XCTAssertEqual(player.queue.currentURL, files[2])
        XCTAssertEqual(engine.requests.count, 2)
        XCTAssertEqual(engine.speeds, speedsBefore)

        player.setSpeed(1.5, requestID: newID)
        XCTAssertEqual(engine.speeds.last, 1.5)
        player.playQueueItem(at: 1, requestID: newID)
        try await waitUntil { engine.requests.count == 3 }
        XCTAssertEqual(player.queue.currentURL, files[3])
        player.stop()
        player.playQueueItem(at: 0, requestID: newID)
        XCTAssertEqual(player.state.phase, .idle)
        XCTAssertEqual(engine.requests.count, 3)
        await player.shutdown()
    }

    func testDelayedSubtitleSelectionCannotAffectReplacementPlayback() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let subtitle = URL(filePath: "/media/selected subtitle.srt")
        player.open(URL(filePath: "/media/episode-one.mp4"))
        try await waitUntilPrepared(player)
        let firstID = try XCTUnwrap(player.state.request?.id)
        engine.onEvent?(.loaded(firstID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: firstID, pauseCommandID: 0,
            position: 4, duration: 60, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 80)))
        let submitPanelSelection = { player.addExternalSubtitle(subtitle, requestID: firstID) }

        player.open(URL(filePath: "/media/episode-two.mp4"))
        let secondID = try XCTUnwrap(player.state.request?.id)
        engine.onEvent?(.loaded(secondID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: secondID, pauseCommandID: 0,
            position: 0, duration: 60, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 80)))
        let currentFailure = PlaybackCommandFailure(kind: .subtitle, detail: "current track failed")
        engine.onEvent?(.commandFailed(secondID, currentFailure))

        let delayCount = engine.subtitleDelays.count
        player.selectAudioTrack(5, requestID: firstID)
        player.selectSubtitleTrack(8, requestID: firstID)
        player.adjustSubtitleDelay(by: 0.5, requestID: firstID)
        player.resetSubtitleDelay(requestID: firstID)
        submitPanelSelection()
        XCTAssertTrue(engine.audioTrackRequests.isEmpty)
        XCTAssertTrue(engine.subtitleTrackRequests.isEmpty)
        XCTAssertEqual(engine.subtitleDelays.count, delayCount)
        XCTAssertTrue(engine.externalSubtitleRequests.isEmpty,
                      "A panel opened for another request must not attach subtitles to the current file")
        XCTAssertEqual(player.state.commandFailure, currentFailure,
                       "A stale result must not dismiss the current file's failure")

        player.addExternalSubtitle(subtitle, requestID: secondID)
        XCTAssertEqual(engine.externalSubtitleRequests.map(\.requestID), [secondID])
        XCTAssertNil(player.state.commandFailure)
        player.stop()
        submitPanelSelection()
        XCTAssertEqual(engine.externalSubtitleRequests.count, 1)
        await player.shutdown()
    }

    func testCancelOpeningRejectsLateEventsAndAllowsAnotherFile() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/opening.mp4"))
        try await waitUntilPrepared(player)
        let cancelledID = try XCTUnwrap(player.state.request?.id)
        XCTAssertEqual(player.state.activity, .opening)
        XCTAssertEqual(engine.requests.map(\.id), [cancelledID])

        player.stop()
        XCTAssertEqual(engine.stopCount, 1, "Cancel must stop the pending engine open, not only hide the UI")
        engine.onEvent?(.loaded(cancelledID))
        engine.onEvent?(.failed(cancelledID, PlaybackFailure(kind: .unsupportedOrDamaged)))
        XCTAssertEqual(player.state.phase, .idle)
        XCTAssertNil(player.state.request)
        XCTAssertNil(player.state.activity)

        player.open(URL(fileURLWithPath: "/replacement.mp4"))
        let replacementID = try XCTUnwrap(player.state.request?.id)
        XCTAssertNotEqual(replacementID, cancelledID)
        XCTAssertEqual(engine.requests.map(\.id), [cancelledID, replacementID])
        engine.onEvent?(.loaded(replacementID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: replacementID, pauseCommandID: 0,
            position: 0, duration: 15, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 100)))
        XCTAssertEqual(player.state.phase, .ready)
        XCTAssertNil(player.state.activity)
        XCTAssertTrue(player.canControlPlayback)
        await player.shutdown()
    }

    func testOnlyLatestOpenIsSubmittedAfterStartup() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        player.open(URL(fileURLWithPath: "/second.mp4"))
        try await waitUntilPrepared(player)
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(engine.requests.first?.url.lastPathComponent, "second.mp4")
        await player.shutdown()
        XCTAssertEqual(engine.shutdownCount, 1)
    }

    func testDelayedInputCannotOverrideANewerDirectOpen() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let delayedIntent = try XCTUnwrap(player.beginInputResolution())
        let newerURL = URL(fileURLWithPath: "/newer-selection.mp4")
        player.open(newerURL)

        player.open([URL(fileURLWithPath: "/late-drop.mp4")], for: delayedIntent)
        player.open([], for: delayedIntent)

        XCTAssertEqual(player.state.request?.url, newerURL)
        XCTAssertEqual(player.queue.items, [newerURL])
        XCTAssertNil(player.inputError, "A stale empty provider result must not report an error over a newer open")
        try await waitUntilPrepared(player)
        XCTAssertEqual(engine.requests.map(\.url), [newerURL])
        await player.shutdown()
    }

    func testUnreadableDropReportsAnImportError() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let intent = try XCTUnwrap(player.beginInputResolution())

        player.open([], for: intent)

        XCTAssertEqual(player.inputError, String(localized: "error.noPlayableMedia"))
        XCTAssertNil(player.state.request)
        XCTAssertTrue(engine.requests.isEmpty)
        await player.shutdown()
    }

    func testStartupFailureIsVisibleAndRejectsMediaRequests() async throws {
        let engine = RecordingPlaybackEngine()
        engine.shouldFailPreparation = true
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilStartupSettles(player)

        XCTAssertEqual(player.startupState, .failed("The playback engine is unavailable."))
        XCTAssertEqual(player.startupError, "The playback engine is unavailable.")
        XCTAssertFalse(player.canOpenMedia)
        XCTAssertTrue(engine.requests.isEmpty)

        player.open(URL(fileURLWithPath: "/second.mp4"))
        XCTAssertTrue(engine.requests.isEmpty, "A failed engine must not silently accept another open request")
        await player.shutdown()
        XCTAssertEqual(engine.shutdownCount, 1)
    }

    func testRapidPauseIntentAndSeekBounds() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilPrepared(player)
        let id = engine.requests[0].id
        engine.onEvent?(.loaded(id))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: id, pauseCommandID: 0, position: 3, duration: 15,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 100)))
        player.togglePause()
        player.togglePause()
        XCTAssertEqual(engine.pauses, [true, false])
        player.seek(to: -20, requestID: id)
        player.seek(to: 100, requestID: id)
        player.seek(to: .nan, requestID: id)
        XCTAssertEqual(engine.seeks, [
            PlaybackSeekRequest(requestID: id, target: .absolute(0)),
            PlaybackSeekRequest(requestID: id, target: .absolute(15))
        ])
        await player.shutdown()
    }

    func testTrackCommandFailureDoesNotStopTheCurrentSession() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilPrepared(player)
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        let currentSnapshot = PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
            position: 3, duration: 15, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 100)
        engine.onEvent?(.snapshot(currentSnapshot))

        engine.onEvent?(.commandFailed(requestID,
            PlaybackCommandFailure(kind: .subtitle, detail: "subtitle file could not be read")))

        XCTAssertEqual(player.state.phase, .ready)
        XCTAssertEqual(player.state.snapshot, currentSnapshot)
        XCTAssertEqual(player.state.commandFailure?.kind, .subtitle)
        player.dismissCommandFailure()
        XCTAssertNil(player.state.commandFailure)
        await player.shutdown()
    }

    func testShutdownPreventsPendingOpenAndRunsOnce() async {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        await player.shutdown()
        await player.shutdown()
        player.open(URL(fileURLWithPath: "/late.mp4"))
        XCTAssertTrue(engine.requests.isEmpty)
        XCTAssertEqual(engine.shutdownCount, 1)
        XCTAssertEqual(player.startupState, .shutDown)
        XCTAssertFalse(player.canOpenMedia)
        XCTAssertEqual(player.state.phase, .idle)
    }

    func testConcurrentShutdownWaitsForOneTeardownWhileHistoryWriteIsSuspended() async throws {
        let store = BlockingHistoryStore()
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
            position: 12, duration: 90, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 80)))

        player.open(URL(fileURLWithPath: "/second.mp4"))
        await store.waitUntilSaveStarts()

        let firstShutdown = Task { await player.shutdown() }
        let secondShutdown = Task { await player.shutdown() }
        await store.finishPendingSave()
        await firstShutdown.value
        await secondShutdown.value

        XCTAssertEqual(engine.shutdownCount, 1, "Overlapping shutdown requests share one native teardown")
        XCTAssertEqual(player.startupState, .shutDown)
    }

    func testFailedFinalCheckpointIsReportedWithoutBlockingEngineShutdown() async throws {
        let store = FailingHistoryStore()
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store)
        player.open(URL(fileURLWithPath: "/final-save.mp4"))
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
            position: 24, duration: 90, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 80)))

        await player.shutdown()

        XCTAssertEqual(player.persistenceError, String(localized: "persistence.saveFailed"))
        XCTAssertEqual(player.startupState, .shutDown)
        XCTAssertEqual(engine.shutdownCount, 1, "A failed save must not retain the native playback resources")
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1, "Shutdown attempts the final checkpoint exactly once")
    }

    func testAmbiguousHistoryPreservesRecordsAndSuppressesWritesForThatPlayback() async throws {
        let store = ConflictingHistoryStore()
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store)
        let media = URL(fileURLWithPath: "/conflicted-history.mp4")

        player.open(media)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let requestID = try XCTUnwrap(engine.requests.first?.id)

        XCTAssertEqual(player.persistenceError, String(localized: "persistence.identityConflict"))
        XCTAssertNil(engine.openOptions.first?.startPosition,
                     "Playback continues from the beginning when no checkpoint can be chosen safely")

        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
            position: 4, duration: 60, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 80)))
        try await player.checkpointPlaybackHistory()

        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 0, "An unresolved identity conflict must not generate a second save error")
        await player.shutdown()
    }

    func testDatabaseWriteContentionPreservesCheckpointAndRecovers() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databasePath = directory.appending(path: "history.sqlite").path
        let store = try PlaybackHistoryStore(path: databasePath)
        let url = directory.appending(path: "resume.mkv")
        try Data("checkpoint contention".utf8).write(to: url)
        try await store.save(for: url, position: 10, audioTrackID: 2, subtitleTrackID: 3, volume: 40)
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store)
        player.open(url)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
            position: 24, duration: 90, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 60)))

        // A separate SQLite writer holds the lock across the player's save/read attempts.
        // Only this test connection permits a transaction to outlive a database access.
        var configuration = Configuration()
        configuration.allowsUnsafeTransactions = true
        let competingWriter = try DatabaseQueue(path: databasePath, configuration: configuration)
        try await competingWriter.writeWithoutTransaction { db in
            try db.execute(sql: "BEGIN IMMEDIATE")
        }
        defer {
            try? competingWriter.writeWithoutTransaction { db in try db.execute(sql: "ROLLBACK") }
        }
        await player.shutdown()
        XCTAssertEqual(player.persistenceError, String(localized: "persistence.saveFailed"))
        XCTAssertEqual(player.startupState, .shutDown)
        XCTAssertEqual(engine.shutdownCount, 1)

        let restartedEngine = RecordingPlaybackEngine()
        let restartedPlayer = PlayerModel(engine: restartedEngine, historyStore: store)
        restartedPlayer.open(url)
        try await waitUntilPrepared(restartedPlayer)
        try await waitUntil { restartedEngine.requests.count == 1 }
        XCTAssertEqual(restartedPlayer.persistenceError, String(localized: "persistence.restoreFailed"))
        XCTAssertNil(restartedEngine.openOptions.first?.startPosition,
                     "Unavailable history must not prevent opening the media")
        try await competingWriter.writeWithoutTransaction { db in try db.execute(sql: "ROLLBACK") }
        let preserved = try await store.history(for: url)
        XCTAssertEqual(preserved?.position, 10, "A failed save must preserve the last committed checkpoint")
        XCTAssertEqual(preserved?.audioTrackID, 2)
        XCTAssertEqual(preserved?.subtitleTrackID, 3)
        XCTAssertEqual(preserved?.volume, 40)

        let restartedID = try XCTUnwrap(restartedEngine.requests.first?.id)
        restartedEngine.onEvent?(.loaded(restartedID))
        restartedEngine.onEvent?(.snapshot(PlaybackSnapshot(requestID: restartedID, pauseCommandID: 0,
            position: 25, duration: 90, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 60)))
        await restartedPlayer.shutdown()
        XCTAssertNil(restartedPlayer.persistenceError, "Successful saving clears the history failure")
        XCTAssertEqual(restartedEngine.shutdownCount, 1)
        let recovered = try await store.history(for: url)
        XCTAssertEqual(recovered?.position, 25)
        XCTAssertEqual(recovered?.volume, 60)
    }

    func testSavedPlaybackStateFlushesOnShutdownAndReopensFromFreshStore() async throws {
        guard ProcessInfo.processInfo.environment["BOMU_HISTORY_PROCESS_ROLE"] == nil else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "history.sqlite")
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        let url = directory.appending(path: "resume.mkv")
        try Data("resume media".utf8).write(to: url)
        try await store.save(for: url, position: 42, audioTrackID: 3,
                             subtitleTrackID: 5, volume: 37)
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store)

        player.open(url)
        try await waitUntilPrepared(player)
        try await waitUntil { !engine.requests.isEmpty }
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        XCTAssertEqual(engine.volumes, [37])

        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 0.2, duration: 120,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 37
        )))
        XCTAssertEqual(engine.openOptions.first?.startPosition?.seconds, 42)
        XCTAssertTrue(engine.seeks.isEmpty, "Restored playback starts at its saved position without a post-load seek")
        XCTAssertEqual(engine.audioTracks, [3])
        XCTAssertEqual(engine.subtitleTracks, [5])

        engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 47.5, duration: 120,
            isPaused: true, isSeeking: false, isBuffering: false, isSeekable: true,
            volume: 28, audioTrackID: 4, subtitleTrackID: 6
        )))
        player.setSpeed(1.5, requestID: requestID)
        player.setSpeed(6, requestID: requestID)
        player.setSpeed(.infinity, requestID: requestID)
        XCTAssertEqual(engine.speeds, [1, 1.5, 4])
        await player.shutdown()

        let reopenedStore = try PlaybackHistoryStore(path: databaseURL.path)
        let saved = try await reopenedStore.history(for: url)
        XCTAssertEqual(saved?.position, 47.5)
        XCTAssertEqual(saved?.audioTrackID, 4)
        XCTAssertEqual(saved?.subtitleTrackID, 6)
        XCTAssertEqual(saved?.volume, 28)

        let childLogURL = directory.appending(path: "fresh-process.log")
        let childResultURL = directory.appending(path: "fresh-process.json")
        XCTAssertTrue(FileManager.default.createFile(atPath: childLogURL.path, contents: nil))
        let childLog = try FileHandle(forWritingTo: childLogURL)
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = [
            "xctest", "-XCTest", "PlayerModelTests/testReadCheckpointFromSeparateProcess",
            Bundle(for: PlayerModelTests.self).bundlePath
        ]
        child.environment = [
            "BOMU_HISTORY_PROCESS_ROLE": "reader",
            "BOMU_HISTORY_DATABASE_PATH": databaseURL.path,
            "BOMU_HISTORY_MEDIA_PATH": url.path,
            "BOMU_HISTORY_RESULT_PATH": childResultURL.path,
            "TMPDIR": FileManager.default.temporaryDirectory.path
        ]
        child.standardOutput = childLog
        child.standardError = childLog
        try child.run()
        child.waitUntilExit()
        try childLog.close()
        let childOutput = try String(contentsOf: childLogURL, encoding: .utf8)
        XCTAssertEqual(child.terminationStatus, 0,
                       "A new XCTest process could not read the shutdown checkpoint.\n\(childOutput)")
        let childValues = try JSONDecoder().decode([Double].self, from: Data(contentsOf: childResultURL))
        XCTAssertEqual(childValues, [47.5, 4, 6, 28],
                       "Require checkpoint data from the child so selecting zero tests cannot pass")

        let restartedEngine = RecordingPlaybackEngine()
        let restartedPlayer = PlayerModel(engine: restartedEngine, historyStore: reopenedStore)
        restartedPlayer.open(url)
        try await waitUntilPrepared(restartedPlayer)
        try await waitUntil { restartedEngine.requests.count == 1 }
        let restartedRequestID = try XCTUnwrap(restartedEngine.requests.first?.id)
        XCTAssertEqual(restartedEngine.volumes, [28], "A fresh player applies the saved volume before opening")
        XCTAssertEqual(restartedEngine.openOptions.first?.startPosition?.seconds, 47.5)
        restartedEngine.onEvent?(.loaded(restartedRequestID))
        XCTAssertEqual(restartedEngine.audioTracks, [4])
        XCTAssertEqual(restartedEngine.subtitleTracks, [6])
        restartedEngine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: restartedRequestID, pauseCommandID: 0, position: 0.2, duration: 120,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 28
        )))
        XCTAssertTrue(restartedEngine.seeks.isEmpty)
        await restartedPlayer.shutdown()
    }

    func testReadCheckpointFromSeparateProcess() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BOMU_HISTORY_PROCESS_ROLE"] == "reader",
              let databasePath = environment["BOMU_HISTORY_DATABASE_PATH"],
              let mediaPath = environment["BOMU_HISTORY_MEDIA_PATH"],
              let resultPath = environment["BOMU_HISTORY_RESULT_PATH"] else {
            return
        }
        let store = try PlaybackHistoryStore(path: databasePath)
        let saved = try await store.history(for: URL(filePath: mediaPath))
        XCTAssertEqual(saved?.position, 47.5)
        XCTAssertEqual(saved?.audioTrackID, 4)
        XCTAssertEqual(saved?.subtitleTrackID, 6)
        XCTAssertEqual(saved?.volume, 28)
        let checkpoint = try XCTUnwrap(saved)
        let values = [checkpoint.position, Double(try XCTUnwrap(checkpoint.audioTrackID)),
                      Double(try XCTUnwrap(checkpoint.subtitleTrackID)), checkpoint.volume]
        try JSONEncoder().encode(values).write(to: URL(filePath: resultPath), options: .atomic)
    }

    func testPlaybackProgressCheckpointIsWrittenDuringPlayback() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
        try Data("periodic checkpoint".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store)

        player.open(url)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 18.25, duration: 120,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 64
        )))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        var saved = try await store.history(for: url)
        while saved?.position != 18.25 && clock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
            saved = try await store.history(for: url)
        }
        XCTAssertEqual(saved?.position, 18.25, "The periodic checkpoint should write before shutdown")

        await player.shutdown()
    }

    func testExplicitContinueAndStartFromBeginningOverrideResumePreference() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("resume choice".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await store.save(for: url, position: 42, audioTrackID: 2, volume: 70)
        let suiteName = "Bomu.ResumeChoice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(false, forKey: "playback.resumeFromLastPosition")
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = PlaybackPreferences(defaults: defaults)
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store, preferences: preferences)

        player.continuePlayback(url)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let continuedID = try XCTUnwrap(engine.requests.first?.id)
        XCTAssertEqual(engine.openOptions.first?.startPosition?.seconds, 42)
        engine.onEvent?(.loaded(continuedID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: continuedID, pauseCommandID: 0,
            position: 0.2, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))
        XCTAssertTrue(engine.seeks.isEmpty)

        player.playFromBeginning(url)
        try await waitUntil { engine.requests.count == 2 }
        let beginningID = try XCTUnwrap(engine.requests.last?.id)
        XCTAssertNil(engine.openOptions.last?.startPosition)
        engine.onEvent?(.loaded(beginningID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: beginningID, pauseCommandID: 0,
            position: 0.1, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(engine.seeks.isEmpty)
        await player.shutdown()
    }

    func testReplayStartsAtBeginningEvenWhenResumePreferenceIsEnabled() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString,
                                                                         directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "episode-1.mp4")
        let nextURL = directory.appending(path: "episode-2.mp4")
        try Data("replay from beginning".utf8).write(to: url)
        try Data("next queued episode".utf8).write(to: nextURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await store.save(for: url, position: 42, volume: 70)
        let suite = "Bomu.ReplayFromBeginning.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "playback.automaticallyPlayNext")
        defaults.set(true, forKey: "playback.resumeFromLastPosition")
        defer { defaults.removePersistentDomain(forName: suite) }

        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store,
                                 preferences: PlaybackPreferences(defaults: defaults))
        player.open([url, nextURL])
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let originalQueue = player.queue
        XCTAssertEqual(originalQueue.items.map(\.lastPathComponent), ["episode-1.mp4", "episode-2.mp4"])
        let endedRequestID = try XCTUnwrap(engine.requests.first?.id)
        XCTAssertEqual(engine.openOptions.first?.startPosition?.seconds, 42)
        engine.onEvent?(.loaded(endedRequestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: endedRequestID, pauseCommandID: 0,
            position: 0.2, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))
        XCTAssertTrue(engine.seeks.isEmpty)
        engine.onEvent?(.ended(endedRequestID))
        XCTAssertEqual(player.state.phase, .ended)

        player.replay()
        try await waitUntil { engine.requests.count == 2 }
        let replayRequestID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(replayRequestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: replayRequestID, pauseCommandID: 0,
            position: 0.2, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))

        XCTAssertNil(engine.openOptions.last?.startPosition,
                     "Replay is an explicit start-from-beginning action, regardless of the resume preference")
        XCTAssertTrue(engine.seeks.isEmpty)
        XCTAssertEqual(player.queue, originalQueue, "Replaying an item must retain the playback queue")
        await player.shutdown()
    }

    func testRetryPreservesExplicitContinueChoiceWhenGlobalResumeIsDisabled() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("retry resume choice".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await store.save(for: url, position: 42, volume: 70)
        let suite = "Bomu.RetryResumeChoice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "playback.resumeFromLastPosition")
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store,
                                 preferences: PlaybackPreferences(defaults: defaults))

        player.continuePlayback(url)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        XCTAssertEqual(engine.openOptions.first?.startPosition?.seconds, 42)
        let failedRequestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.failed(failedRequestID, PlaybackFailure(kind: .unsupportedOrDamaged)))
        XCTAssertEqual(player.state.phase, .failed(PlaybackFailure(kind: .unsupportedOrDamaged)))

        player.retryCurrentMedia()
        try await waitUntil { engine.requests.count == 2 }
        XCTAssertEqual(engine.openOptions.last?.startPosition?.seconds, 42)
        let retriedRequestID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(retriedRequestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: retriedRequestID, pauseCommandID: 0,
            position: 0.2, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))
        XCTAssertTrue(engine.seeks.isEmpty)
        await player.shutdown()
    }

    func testQueueAdvancesOnlyAfterNaturalEndAndCanRecoverFromFailure() async throws {
        let engine = RecordingPlaybackEngine()
        let suite = "Bomu.QueueNaturalEndTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "playback.automaticallyPlayNext")
        defer { defaults.removePersistentDomain(forName: suite) }
        let player = PlayerModel(engine: engine,
                                 preferences: PlaybackPreferences(defaults: defaults))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "Season 1 Episode 2.mkv")
        let second = directory.appending(path: "Season 1 Episode 10.mkv")
        try Data().write(to: first)
        try Data().write(to: second)
        player.open([second, first])
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        XCTAssertEqual(engine.requests[0].url, first)
        XCTAssertEqual(player.queue.currentURL, first)

        engine.onEvent?(.loaded(engine.requests[0].id))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: engine.requests[0].id, pauseCommandID: 0,
            position: 29.9, duration: 30, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 100)))
        engine.onEvent?(.ended(engine.requests[0].id))
        try await waitUntil { engine.requests.count == 2 }
        XCTAssertEqual(engine.requests[1].url, second)
        XCTAssertEqual(player.queue.currentURL, second)

        engine.onEvent?(.failed(engine.requests[1].id, PlaybackFailure(kind: .unsupportedOrDamaged)))
        XCTAssertEqual(player.state.phase, .failed(PlaybackFailure(kind: .unsupportedOrDamaged)))
        player.playQueueItem(at: 0, requestID: engine.requests[1].id)
        try await waitUntil { engine.requests.count == 3 }
        XCTAssertEqual(engine.requests[2].url, first)
        let manuallyOpenedID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(manuallyOpenedID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: manuallyOpenedID, pauseCommandID: 0,
            position: 1, duration: 3, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 100)))

        player.stop()
        XCTAssertEqual(player.state.phase, .idle)
        XCTAssertEqual(engine.requests.count, 3, "Manual stop does not advance the queue")
        await player.shutdown()
    }

    func testShortOrUnknownDurationDoesNotAutomaticallyAdvanceButManualNextStillWorks() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first.mp4")
        let second = directory.appending(path: "second.mp4")
        try Data().write(to: first)
        try Data().write(to: second)

        let durations: [Double?] = [29.999, nil, .nan, .infinity]
        for duration in durations {
            let suite = "Bomu.ShortClipQueueTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(true, forKey: "playback.automaticallyPlayNext")

            let engine = RecordingPlaybackEngine()
            let player = PlayerModel(engine: engine,
                                     preferences: PlaybackPreferences(defaults: defaults))
            player.open([first, second])
            try await waitUntilPrepared(player)
            try await waitUntil { engine.requests.count == 1 }
            let requestID = try XCTUnwrap(engine.requests.first?.id)
            engine.onEvent?(.loaded(requestID))
            engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
                position: 0, duration: duration, isPaused: false, isSeeking: false,
                isBuffering: false, isSeekable: duration != nil, volume: 100)))
            engine.onEvent?(.ended(requestID))

            XCTAssertEqual(engine.requests.count, 1,
                           "A short or unknown-duration file must not trigger automatic next")
            XCTAssertEqual(player.queue.currentIndex, 0)
            XCTAssertEqual(player.state.phase, .ended)

            player.playNext()
            try await waitUntil { engine.requests.count == 2 }
            XCTAssertEqual(engine.requests.last?.url, second,
                           "The duration rule must not prevent a manual queue change")
            await player.shutdown()
        }
    }

    func testUnreadableSubdirectoryPreservesCurrentPlaybackAndQueue() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let incoming = directory.appending(path: "incoming")
        let restricted = incoming.appending(path: "restricted")
        try FileManager.default.createDirectory(at: restricted, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "original-1.mp4")
        let second = directory.appending(path: "original-2.mp4")
        for file in [first, second, incoming.appending(path: "readable.mp4"),
                     restricted.appending(path: "inaccessible.mp4")] {
            try Data().write(to: file)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: restricted.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: restricted.path)
        }
        XCTAssertFalse(FileManager.default.isReadableFile(atPath: restricted.path),
                       "This test requires a real unreadable directory")
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open([first, second])
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let request = try XCTUnwrap(engine.requests.first)
        engine.onEvent?(.loaded(request.id))

        player.open([incoming])
        try await waitUntil { player.inputError != nil || engine.requests.count > 1 }

        XCTAssertEqual(player.inputError, String(localized: "error.mediaImportFailed"))
        XCTAssertEqual(player.queue.items, [first, second])
        XCTAssertEqual(player.queue.currentURL, first)
        XCTAssertEqual(player.state.request, request)
        XCTAssertEqual(player.state.phase, .ready)
        XCTAssertEqual(engine.requests.count, 1, "An incomplete import must not interrupt current playback")
        await player.shutdown()
    }

    func testStopCancelsPendingBatchImportBeforeItCanOpenMedia() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        player.open([url])
        player.stop()
        await player.shutdown()

        XCTAssertTrue(engine.requests.isEmpty)
        XCTAssertEqual(player.state.phase, .idle)
        XCTAssertTrue(player.queue.items.isEmpty)
        XCTAssertNil(player.inputError)
        XCTAssertEqual(engine.shutdownCount, 1)
    }

    func testPlaybackPreferencesApplyToNewMediaAndGateQueueAdvance() async throws {
        let engine = RecordingPlaybackEngine()
        let store = FailingHistoryStore()
        let suite = "Bomu.PlayerPreferencesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.automaticallyPlayNext = false
        preferences.defaultSpeed = 1.5
        preferences.defaultSubtitleDelay = -0.5

        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appending(path: "first.mp4")
        let second = directory.appending(path: "second.mp4")
        try Data().write(to: first)
        try Data().write(to: second)
        let player = PlayerModel(engine: engine, historyStore: store, preferences: preferences)
        player.open([first, second])
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }

        let requestID = engine.requests[0].id
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.loaded(requestID))
        XCTAssertEqual(engine.speeds, [1.5])
        XCTAssertEqual(engine.subtitleDelays, [.init(seconds: -0.5, requestID: requestID)],
                       "A duplicate load event must not reapply per-file defaults")
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
            position: 12, duration: 90, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 80)))
        engine.onEvent?(.ended(requestID))
        engine.onEvent?(.ended(requestID))
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(player.state.phase, .ended)
        await player.shutdown()
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 2,
                       "One end checkpoint and one shutdown checkpoint are expected; duplicate end events add none")
    }

    func testClearingHistoryDoesNotRecreateTheActiveFileRecord() async throws {
        let engine = RecordingPlaybackEngine()
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("clear history".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try await store.save(for: url, position: 42, volume: 80)
        let player = PlayerModel(engine: engine, historyStore: store)
        player.open(url)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        engine.onEvent?(.loaded(engine.requests[0].id))
        engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: engine.requests[0].id, pauseCommandID: 0, position: 50, duration: 100,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 80
        )))

        try await player.clearPlaybackHistory()

        try await player.checkpointPlaybackHistory()
        XCTAssertNil(player.historyClearError)
        let clearedWhilePlaying = try await store.history(for: url)
        XCTAssertNil(clearedWhilePlaying)
        await player.shutdown()
        let clearedAfterShutdown = try await store.history(for: url)
        XCTAssertNil(clearedAfterShutdown)
    }

    func testFailedLibraryClearRestoresActiveHistoryPersistence() async throws {
        let engine = RecordingPlaybackEngine()
        let store = FailingLibraryStore()
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("clear library failure".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(engine: engine, historyStore: store)
        player.open(url)
        try await waitUntilPrepared(player)
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 25, duration: 100,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 80
        )))

        do {
            try await player.clearLibraryRecords()
            XCTFail("The injected library clear should fail")
        } catch FailingLibraryStore.Failure.expected {
            // The failed destructive operation must restore the current request's save path.
        }

        player.stop()
        await player.shutdown()
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1)
    }

    func testFailedDataManagementPreservesExistingHistorySuppression() async throws {
        let engine = RecordingPlaybackEngine()
        let store = FailingLibraryStore(failingClearAllCalls: [2])
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("preserve history policy".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let player = PlayerModel(engine: engine, historyStore: store)
        player.open(url)
        try await waitUntilPrepared(player)
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 25, duration: 100,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 80
        )))

        try await player.clearPlaybackHistory()
        do {
            try await player.clearPlaybackHistory()
            XCTFail("The injected history clear must fail")
        } catch FailingLibraryStore.Failure.expected { }

        do {
            _ = try await player.importLibraryArchive(Data())
            XCTFail("The injected archive import should fail")
        } catch FailingLibraryStore.Failure.expected {
            // The earlier successful history clear remains authoritative.
        }
        do {
            try await player.clearLibraryRecords()
            XCTFail("The injected library clear should fail")
        } catch FailingLibraryStore.Failure.expected {
            // Failure must not undo the existing suppression policy.
        }

        player.stop()
        await player.shutdown()
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 0)
    }

    func testTrackSelectionExternalSubtitlesAndOffsetUseCurrentRequest() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(filePath: "/media/tracks.mkv"))
        try await waitUntilPrepared(player)
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 4, duration: 90,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 100,
            subtitleDelay: 0.25,
            tracks: [PlaybackTrack(id: 2, kind: .audio, language: "eng", title: "Commentary",
                                  isSelected: true, isExternal: false)]
        )))

        player.selectAudioTrack(5, requestID: requestID)
        player.selectSubtitleTrack(8, requestID: requestID)
        player.addExternalSubtitle(URL(filePath: "/media/external subtitle.srt"), requestID: requestID)
        player.adjustSubtitleDelay(by: 0.5, requestID: requestID)
        player.adjustSubtitleDelay(by: 0.5, requestID: requestID)
        player.resetSubtitleDelay(requestID: requestID)

        XCTAssertEqual(engine.audioTrackRequests.map(\.id), [5])
        XCTAssertEqual(engine.audioTrackRequests.map(\.requestID), [requestID])
        XCTAssertEqual(engine.subtitleTrackRequests.map(\.id), [8])
        XCTAssertEqual(engine.subtitleTrackRequests.map(\.requestID), [requestID])
        XCTAssertEqual(engine.externalSubtitleRequests.map(\.requestID), [requestID])
        XCTAssertEqual(engine.subtitleDelays.map(\.seconds), [0, 0.75, 1.25, 0])
        XCTAssertEqual(engine.subtitleDelays.map(\.requestID), [requestID, requestID, requestID, requestID])
        await player.shutdown()
    }

    func testStalePauseSnapshotCannotAcknowledgeNewerIntent() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilPrepared(player)
        let id = engine.requests[0].id
        engine.onEvent?(.loaded(id))
        let playing = PlaybackSnapshot(requestID: id, pauseCommandID: 0, position: 3, duration: 15,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 100)
        engine.onEvent?(.snapshot(playing))
        player.togglePause()
        player.togglePause()
        // This snapshot predates both commands but happens to match the newest intent.
        engine.onEvent?(.snapshot(playing))
        var earlierPause = playing
        earlierPause.isPaused = true
        earlierPause.pauseCommandID = 1
        engine.onEvent?(.snapshot(earlierPause))
        XCTAssertFalse(player.isPaused, "An earlier pause must not override the pending resume")
        player.togglePause()
        XCTAssertEqual(engine.pauses, [true, false, true])
        var confirmed = earlierPause
        confirmed.pauseCommandID = 3
        engine.onEvent?(.snapshot(confirmed))
        XCTAssertTrue(player.isPaused)
        var lateResume = playing
        lateResume.pauseCommandID = 2
        engine.onEvent?(.snapshot(lateResume))
        XCTAssertTrue(player.isPaused, "A late older acknowledgement must not roll back confirmed state")
        player.togglePause()
        XCTAssertEqual(engine.pauses, [true, false, true, false])
        await player.shutdown()
    }

    func testRelativeSeeksKeepTheirIntentAcrossDelayedSnapshotsAndReplacement() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilPrepared(player)
        let firstID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(firstID))
        let snapshot = PlaybackSnapshot(requestID: firstID, pauseCommandID: 0, position: 30,
            duration: 300, isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 100)
        engine.onEvent?(.snapshot(snapshot))
        player.skip(by: 10)
        engine.onEvent?(.snapshot(snapshot)) // A delayed position cannot turn a relative seek into an absolute one.
        player.skip(by: 10)
        player.skip(by: -10)
        player.seek(to: 90, requestID: firstID)
        player.skip(by: -10)
        player.skip(by: .nan)
        player.skip(by: .infinity)
        XCTAssertEqual(engine.seeks.map(\.target), [.relative(10), .relative(10), .relative(-10),
                                                  .absolute(90), .relative(-10)])
        XCTAssertTrue(engine.seeks.allSatisfy { $0.requestID == firstID })
        XCTAssertEqual(player.state.snapshot?.position, 30, "Only native snapshots confirm progress")

        player.open(URL(fileURLWithPath: "/second.mp4"))
        player.skip(by: 10)
        engine.onEvent?(.snapshot(snapshot))
        XCTAssertFalse(player.canSeek)
        XCTAssertEqual(engine.seeks.count, 5)
        let secondID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(secondID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: secondID, pauseCommandID: 0, position: 1,
            duration: 60, isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 100)))
        player.skip(by: 10)
        XCTAssertEqual(engine.seeks.last, PlaybackSeekRequest(requestID: secondID, target: .relative(10)))
        player.stop()
        player.skip(by: 10)
        XCTAssertFalse(player.canSeek)
        XCTAssertEqual(engine.seeks.count, 6)
        await player.shutdown()
    }

    func testDelayedTimelineCommitCannotSeekReplacementOrStoppedPlayback() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilPrepared(player)
        let firstID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(firstID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: firstID, pauseCommandID: 0,
            position: 3, duration: 90, isPaused: true, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 100)))
        let finishFirstTimeline = { player.seek(to: 45, requestID: firstID) }

        player.open(URL(fileURLWithPath: "/second.mp4"))
        let secondID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(secondID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: secondID, pauseCommandID: 0,
            position: 1, duration: 60, isPaused: true, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 100)))
        finishFirstTimeline()
        XCTAssertTrue(engine.seeks.isEmpty, "A delayed timeline callback belongs to its original file")
        XCTAssertEqual(player.state.snapshot?.position, 1)
        XCTAssertTrue(player.isPaused)

        player.seek(to: 12, requestID: secondID)
        XCTAssertEqual(engine.seeks, [PlaybackSeekRequest(requestID: secondID, target: .absolute(12))])
        player.stop()
        finishFirstTimeline()
        player.seek(to: 20, requestID: secondID)
        XCTAssertEqual(engine.seeks.count, 1)
        XCTAssertTrue(engine.pauses.isEmpty)
        await player.shutdown()
    }

    func testSeekCapabilityGatesBothAbsoluteAndRelativeCommands() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilPrepared(player)
        let id = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(id))
        var snapshot = PlaybackSnapshot(requestID: id, pauseCommandID: 0, position: 3, duration: 15,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: false, volume: 100)
        for (duration, seekable) in [(Double?.some(15), false), (nil, true), (0, true),
                                     (-1, true), (.nan, true), (.infinity, true)] {
            snapshot.duration = duration
            snapshot.isSeekable = seekable
            engine.onEvent?(.snapshot(snapshot))
            XCTAssertTrue(player.canControlPlayback)
            XCTAssertFalse(player.canSeek)
            player.seek(to: 10, requestID: id)
            player.skip(by: 10)
        }
        XCTAssertTrue(engine.seeks.isEmpty)
        snapshot.duration = 15
        snapshot.isSeekable = true
        engine.onEvent?(.snapshot(snapshot))
        XCTAssertTrue(player.canSeek)
        engine.onEvent?(.ended(id))
        XCTAssertFalse(player.canSeek)
        await player.shutdown()
    }

    func testSeekingWhilePausedDoesNotIssueResumeIntent() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/paused.mp4"))
        try await waitUntilPrepared(player)
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
            position: 12, duration: 90, isPaused: true, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 100)))

        player.seek(to: 45, requestID: requestID)

        XCTAssertEqual(engine.seeks, [PlaybackSeekRequest(requestID: requestID, target: .absolute(45))])
        XCTAssertTrue(engine.pauses.isEmpty, "Seeking must not implicitly resume paused media")
        await player.shutdown()
    }

    func testReturningToLibraryCoalescesRefreshAndKeepsPlayerUntilReady() async throws {
        let navigation = MainWindowNavigation()
        let gate = RecordScanGate()
        var refreshCount = 0
        navigation.showPlayer()
        navigation.showLibrary {
            refreshCount += 1
            await gate.wait()
        }
        try await waitUntil { refreshCount == 1 }
        navigation.showLibrary { refreshCount += 1 }
        XCTAssertTrue(navigation.isPlayerVisible)
        await gate.release()
        try await waitUntil { !navigation.isPlayerVisible }
        XCTAssertEqual(refreshCount, 1)
    }

    func testNewPlaybackIntentCancelsOldReturnWithoutOverwritingNewReturn() async throws {
        let navigation = MainWindowNavigation()
        let oldGate = RecordScanGate()
        let newGate = RecordScanGate()
        var oldStarted = false
        var oldFinished = false
        var newStarted = false
        var unexpectedRefresh = false
        navigation.showPlayer()
        navigation.showLibrary {
            oldStarted = true
            await oldGate.wait()
            oldFinished = true
        }
        try await waitUntil { oldStarted }
        navigation.showPlayer()
        navigation.showLibrary {
            newStarted = true
            await newGate.wait()
        }
        try await waitUntil { newStarted }
        await oldGate.release()
        try await waitUntil { oldFinished }
        XCTAssertTrue(navigation.isPlayerVisible)
        navigation.showLibrary { unexpectedRefresh = true }
        await newGate.release()
        try await waitUntil { !navigation.isPlayerVisible }
        XCTAssertFalse(unexpectedRefresh, "An old return must not clear the new return's task ownership")

        navigation.showPlayer()
        let closeGate = RecordScanGate()
        var closeStarted = false
        var closeFinished = false
        navigation.showLibrary {
            closeStarted = true
            await closeGate.wait()
            closeFinished = true
        }
        try await waitUntil { closeStarted }
        navigation.cancelPendingReturn()
        await closeGate.release()
        try await waitUntil { closeFinished }
        XCTAssertTrue(navigation.isPlayerVisible, "A disappeared window must not finish its cancelled route")
    }

    func testEveryLibraryReturnRefreshesCheckpointWithoutReopeningPlayback() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: fixture.store,
                                 preferences: PlaybackPreferences(defaults: fixture.defaults))
        let item = try XCTUnwrap(fixture.library.items.first)
        fixture.library.select(item)
        player.open(fixture.media)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let requestID = engine.requests[0].id
        engine.onEvent?(.loaded(requestID))
        let navigation = MainWindowNavigation()
        for position in [8.3, 9.767] {
            navigation.showPlayer()
            engine.onEvent?(.snapshot(PlaybackSnapshot(
                requestID: requestID, pauseCommandID: 0, position: position, duration: 100,
                isPaused: true, isSeeking: false, isBuffering: false, isSeekable: true, volume: 80
            )))
            navigation.showLibrary {
                try? await player.checkpointPlaybackHistory()
                await fixture.library.refresh()
            }
            try await waitUntil { !navigation.isPlayerVisible }
            XCTAssertEqual(fixture.library.continueWatching.first?.playbackPosition, position)
            XCTAssertEqual(fixture.library.selectedItemID, item.id)
            XCTAssertEqual(player.state.request?.id, requestID)
            XCTAssertEqual(engine.requests.count, 1)
            XCTAssertTrue(engine.pauses.isEmpty)
            XCTAssertTrue(engine.seeks.isEmpty)
        }
        await player.shutdown()
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    @MainActor
    func testHistoryClearRefreshesContinueWatchingWithoutRemovingFavorites() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let item = try XCTUnwrap(fixture.library.items.first)
        try await fixture.store.save(for: fixture.media, position: 42, volume: 70)
        await fixture.library.toggleFavorite(item)
        XCTAssertEqual(fixture.library.continueWatching.count, 1)

        try await fixture.operations.clearHistory()
        XCTAssertTrue(fixture.library.continueWatching.isEmpty)
        XCTAssertEqual(fixture.library.roots.count, 1)
        XCTAssertEqual(fixture.library.items.count, 1)
        XCTAssertEqual(fixture.library.favorites.count, 1)
        XCTAssertEqual(fixture.library.items.first?.playbackPosition, 0)
        XCTAssertFalse(fixture.library.isReplacingRecords)
        XCTAssertEqual(try Data(contentsOf: fixture.media), Data("original media".utf8))
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    @MainActor
    func testHistoryClearFailurePreservesVisibleCheckpointAndAllowsRetry() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try await fixture.store.save(for: fixture.media, position: 42, volume: 70)
        await fixture.library.refresh()
        let connection = try DatabaseQueue(path: fixture.databasePath)
        try await connection.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_history_delete BEFORE DELETE ON playback_history
                BEGIN SELECT RAISE(ABORT, 'forced history clear failure'); END
                """)
        }
        do {
            try await fixture.operations.clearHistory()
            XCTFail("The history clear must surface database failure")
        } catch let error as DatabaseError {
            fixture.player.reportHistoryClearError(error)
        }
        XCTAssertNotNil(fixture.player.historyClearError)
        XCTAssertFalse(fixture.operations.isWorking)
        XCTAssertFalse(fixture.library.isReplacingRecords)
        XCTAssertEqual(fixture.library.continueWatching.first?.playbackPosition, 42)
        let item = try XCTUnwrap(fixture.library.items.first)
        await fixture.library.toggleFavorite(item)
        XCTAssertEqual(fixture.library.favorites.count, 1)

        try await connection.write { db in try db.execute(sql: "DROP TRIGGER fail_history_delete") }
        try await fixture.operations.clearHistory()
        XCTAssertNil(fixture.player.historyClearError)
        XCTAssertTrue(fixture.library.continueWatching.isEmpty)
        XCTAssertEqual(fixture.library.favorites.count, 1)
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    @MainActor
    func testRecordClearDrainsScansAndPreferencesAndAllowsIntentionalReimport() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let item = try XCTUnwrap(fixture.library.items.first)
        for index in 0..<100 {
            try Data("new \(index)".utf8).write(to: fixture.root.appending(path: "new-\(index).mp4"))
        }
        fixture.sync.start()
        fixture.library.addFolder(fixture.root)
        fixture.library.setCategory(.movie, for: item)
        try await fixture.operations.clearRecords()
        XCTAssertTrue(fixture.library.items.isEmpty)
        XCTAssertTrue(fixture.library.roots.isEmpty)
        XCTAssertFalse(fixture.library.isScanning)
        XCTAssertFalse(fixture.library.isReplacingRecords)
        XCTAssertNil(fixture.library.undoNotice)
        try await Task.sleep(for: .milliseconds(900))
        let rootsAfterSync = try await fixture.store.sourceRoots(mountedVolumeIDs: [])
        XCTAssertTrue(rootsAfterSync.isEmpty, "A queued reconciliation must not recreate the cleared source")

        fixture.library.addFolder(fixture.root)
        try await waitUntil { fixture.library.items.count == 101 && !fixture.library.isScanning }
        XCTAssertTrue(fixture.library.items.allSatisfy { $0.manualCategory == nil })
        XCTAssertEqual(try Data(contentsOf: fixture.media), Data("original media".utf8))
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    @MainActor
    func testFailedRecordClearRestoresLibraryWritesAndBackgroundSync() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let connection = try DatabaseQueue(path: fixture.databasePath)
        try await connection.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_source_delete BEFORE DELETE ON media_sources
                BEGIN SELECT RAISE(ABORT, 'forced reset failure'); END
                """)
        }
        fixture.sync.start()
        do {
            try await fixture.operations.clearRecords()
            XCTFail("The failed reset must be reported")
        } catch is DatabaseError { }
        XCTAssertFalse(fixture.operations.isWorking)
        XCTAssertFalse(fixture.library.isReplacingRecords)
        let item = try XCTUnwrap(fixture.library.items.first)
        await fixture.library.toggleFavorite(item)
        XCTAssertTrue(fixture.library.items.first?.isFavorite == true)
        try Data("new after failed reset".utf8).write(to: fixture.root.appending(path: "new.mp4"))
        try await waitUntil { fixture.library.items.count == 2 }
        XCTAssertNil(fixture.library.errorMessage)
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    @MainActor
    func testRecordImportUsesTheSameBoundaryAndRecoversAfterInvalidArchive() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let item = try XCTUnwrap(fixture.library.items.first)
        await fixture.library.toggleFavorite(item)
        let archive = try await fixture.player.exportLibraryArchive()
        try await fixture.operations.clearRecords()
        do {
            _ = try await fixture.operations.importArchive(Data("not an archive".utf8))
            XCTFail("Invalid import must fail without leaving writers suspended")
        } catch { }
        XCTAssertFalse(fixture.library.isReplacingRecords)
        XCTAssertFalse(fixture.operations.isWorking)
        fixture.library.addFolder(fixture.root)
        try await waitUntil { fixture.library.items.count == 1 && !fixture.library.isScanning }
        let result = try await fixture.operations.importArchive(archive)
        XCTAssertEqual(result.importedFileCount, 1)
        XCTAssertTrue(fixture.library.items.first?.isFavorite == true)
        XCTAssertEqual(try Data(contentsOf: fixture.media), Data("original media".utf8))
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    func testArchivePreparationNewSelectionWinsOverLateReadAndPreview() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let data = try await fixture.player.exportLibraryArchive()
        let readGate = RecordScanGate()
        let readStarted = expectation(description: "old archive read started")
        let preparation = MediaLibraryImportPreparation { url in
            if url.lastPathComponent == "old.json" {
                readStarted.fulfill()
                await readGate.wait()
            }
            return data
        }
        var obsoletePreviewCalls = 0
        let oldRead = preparation.prepare(from: fixture.root.appending(path: "old.json")) { bytes in
            obsoletePreviewCalls += 1
            return try await fixture.player.previewLibraryArchive(bytes)
        }
        await fulfillment(of: [readStarted], timeout: 2)
        let current = preparation.prepare(from: fixture.root.appending(path: "new.json")) { bytes in
            try await fixture.player.previewLibraryArchive(bytes)
        }
        await current.value
        XCTAssertEqual(preparation.prepared?.data, data)
        await readGate.release()
        await oldRead.value
        XCTAssertEqual(obsoletePreviewCalls, 0)
        XCTAssertNotNil(preparation.prepared)

        let previewGate = RecordScanGate()
        let previewStarted = expectation(description: "old database preview started")
        let oldPreview = preparation.prepare(from: fixture.root.appending(path: "new.json")) { _ in
            previewStarted.fulfill()
            await previewGate.wait()
            throw CocoaError(.fileReadCorruptFile)
        }
        await fulfillment(of: [previewStarted], timeout: 2)
        let latest = preparation.prepare(from: fixture.root.appending(path: "latest.json")) { bytes in
            try await fixture.player.previewLibraryArchive(bytes)
        }
        await latest.value
        await previewGate.release()
        await oldPreview.value
        XCTAssertNotNil(preparation.prepared, "An obsolete failure must not replace the latest confirmation")
        preparation.cancel()
        XCTAssertNil(preparation.prepared, "Dismissing confirmation releases the archive bytes")
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    func testArchivePreparationCloseDropsPendingResultAndFailureCanRetry() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let archive = fixture.root.appending(path: "backup.json")
        try Data("invalid JSON".utf8).write(to: archive)
        let preparation = MediaLibraryImportPreparation()
        await preparation.prepare(from: archive) { data in
            try await fixture.player.previewLibraryArchive(data)
        }.value
        if case .failed = preparation.phase { } else { XCTFail("Invalid backup must show a failure") }
        try await fixture.operations.exportArchive(to: archive)
        var archiveObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: archive)) as? [String: Any])
        var files = try XCTUnwrap(archiveObject["files"] as? [[String: Any]])
        files[0]["isFavorite"] = true
        archiveObject["files"] = files
        try JSONSerialization.data(withJSONObject: archiveObject).write(to: archive)
        let gate = RecordScanGate()
        let started = expectation(description: "preview suspended while settings closes")
        let pending = preparation.prepare(from: archive) { data in
            started.fulfill()
            await gate.wait()
            return try await fixture.player.previewLibraryArchive(data)
        }
        await fulfillment(of: [started], timeout: 2)
        preparation.cancel()
        await gate.release()
        await pending.value
        if case .idle = preparation.phase { } else { XCTFail("Closing Settings must prevent a late confirmation") }
        await preparation.prepare(from: archive) { data in
            try await fixture.player.previewLibraryArchive(data)
        }.value
        XCTAssertEqual(preparation.prepared?.preview.matchedFileCount, 1)
        await fixture.library.refresh()
        XCTAssertEqual(fixture.library.items.count, 1)
        XCTAssertTrue(fixture.library.favorites.isEmpty, "Preview must not apply the archive's favorite change")
        preparation.cancel()
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    func testCancelledArchiveReaderStopsBeforeOpeningFile() async throws {
        let gate = RecordScanGate()
        let read = Task {
            await gate.wait()
            return try await MediaLibraryArchive.readForImport(from: URL(filePath: "/missing-bomu-backup.json"))
        }
        read.cancel()
        await gate.release()
        do {
            _ = try await read.value
            XCTFail("A cancelled reader must not read or report a file error")
        } catch is CancellationError { }
    }

    func testPrivateFolderImmediatelyRefreshesSavedHistoryAndPreservesLibraryFacts() async throws {
        let started = expectation(description: "privacy update leaves scan running")
        let gate = RecordScanGate()
        let fixture = try await makeRecordOperationFixture(scanner: GatedRecordScanner(
            gate: gate, didStart: started))
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let item = try XCTUnwrap(fixture.library.items.first)
        try await fixture.store.save(for: fixture.media, position: 42, volume: 70)
        await fixture.library.toggleFavorite(item)
        XCTAssertEqual(fixture.library.continueWatching.count, 1)

        fixture.library.addFolder(fixture.root)
        await fulfillment(of: [started], timeout: 2)
        let updated = expectation(description: "privacy rule completes during scan")
        let update = Task {
            defer { updated.fulfill() }
            try await fixture.operations.excludeHistory(in: fixture.root)
        }
        await fulfillment(of: [updated], timeout: 2)
        XCTAssertTrue(fixture.library.isScanning)
        await gate.release()
        try await update.value
        XCTAssertTrue(fixture.library.continueWatching.isEmpty,
                      "Accepting a privacy rule must immediately remove the visible saved position")
        XCTAssertEqual(fixture.library.items.first?.playbackPosition, 0)
        XCTAssertEqual(fixture.library.items.count, 1)
        XCTAssertEqual(fixture.library.favorites.count, 1)
        XCTAssertEqual(fixture.library.roots.count, 1)
        try await fixture.store.save(for: fixture.media, position: 55, volume: 70)
        let excludedHistory = try await fixture.store.history(for: fixture.media)
        XCTAssertNil(excludedHistory)
        let rules = try await fixture.player.historyExcludedFolders()
        let rule = try XCTUnwrap(rules.first)
        try await fixture.operations.removeHistoryExclusion(rule)
        XCTAssertTrue(fixture.library.continueWatching.isEmpty, "Removing a rule must not resurrect history")
        try await fixture.store.save(for: fixture.media, position: 67, volume: 70)
        await fixture.library.refresh()
        XCTAssertEqual(fixture.library.continueWatching.first?.playbackPosition, 67)
        XCTAssertEqual(try Data(contentsOf: fixture.media), Data("original media".utf8))
        await fixture.operations.shutdown()
        do {
            try await fixture.operations.excludeHistory(in: fixture.root)
            XCTFail("Shutdown must reject new privacy writes")
        } catch is CancellationError { }
        do {
            try await fixture.operations.removeHistoryExclusion(rule)
            XCTFail("Shutdown must reject rule removal")
        } catch is CancellationError { }
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    func testPrivateFolderFailureRollsBackRuleAndRecoversVisibleHistory() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        try await fixture.store.save(for: fixture.media, position: 42, volume: 70)
        await fixture.library.refresh()
        let connection = try DatabaseQueue(path: fixture.databasePath)
        try await connection.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_privacy_delete BEFORE DELETE ON playback_history
                BEGIN SELECT RAISE(ABORT, 'forced privacy failure'); END
                """)
        }
        do {
            try await fixture.operations.excludeHistory(in: fixture.root)
            XCTFail("A failed privacy transaction must not report success")
        } catch let error as DatabaseError {
            fixture.player.reportDataManagementError(error)
        }
        let rules = try await fixture.player.historyExcludedFolders()
        XCTAssertTrue(rules.isEmpty, "Rule insertion must roll back with checkpoint deletion")
        XCTAssertEqual(fixture.library.continueWatching.first?.playbackPosition, 42)
        XCTAssertNotNil(fixture.player.dataManagementError)
        XCTAssertFalse(fixture.operations.isWorking)
        try await connection.write { db in try db.execute(sql: "DROP TRIGGER fail_privacy_delete") }
        try await fixture.operations.excludeHistory(in: fixture.root)
        XCTAssertTrue(fixture.library.continueWatching.isEmpty)
        XCTAssertNil(fixture.player.dataManagementError)
        XCTAssertFalse(fixture.operations.isWorking)
        XCTAssertEqual(try Data(contentsOf: fixture.media), Data("original media".utf8))
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    func testArchiveExportIncludesCurrentCheckpointAndAcceptedPreferencesWithoutCancellingScan() async throws {
        let started = expectation(description: "scanner remains active during export")
        let gate = RecordScanGate()
        let fixture = try await makeRecordOperationFixture(scanner: GatedRecordScanner(
            gate: gate, didStart: started))
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        let item = try XCTUnwrap(fixture.library.items.first)
        await fixture.library.toggleFavorite(item)
        fixture.player.open(fixture.media)
        try await waitUntil { fixture.engine.requests.count == 1 }
        let requestID = fixture.engine.requests[0].id
        fixture.engine.onEvent?(.loaded(requestID))
        fixture.engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 52.5, duration: 100,
            isPaused: true, isSeeking: false, isBuffering: false, isSeekable: true, volume: 70
        )))
        fixture.library.addFolder(fixture.root)
        await fulfillment(of: [started], timeout: 2)
        fixture.library.setCategory(.movie, for: item)
        let destination = fixture.root.appending(path: "export.json")
        let exported = expectation(description: "export does not wait for scan completion")
        let export = Task {
            defer { exported.fulfill() }
            try await fixture.operations.exportArchive(to: destination)
        }
        await fulfillment(of: [exported], timeout: 2)
        XCTAssertTrue(fixture.library.isScanning)
        XCTAssertFalse(fixture.library.isReplacingRecords)
        await gate.release()
        try await export.value
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(MediaLibraryArchive.self, from: Data(contentsOf: destination))
        let saved = try XCTUnwrap(archive.files.first)
        XCTAssertEqual(saved.history?.position, 52.5)
        XCTAssertEqual(saved.history?.volume, 70)
        XCTAssertTrue(saved.isFavorite)
        XCTAssertEqual(saved.manualCategory, .movie)
        XCTAssertEqual(fixture.engine.requests.count, 1)
        XCTAssertFalse(fixture.operations.isWorking)
        XCTAssertEqual(try Data(contentsOf: fixture.media), Data("original media".utf8))
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    func testArchiveExportPreservesExistingBackupOnCheckpointFailureAndRecovers() async throws {
        let fixture = try await makeRecordOperationFixture()
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.player.open(fixture.media)
        try await waitUntil { fixture.engine.requests.count == 1 }
        let requestID = fixture.engine.requests[0].id
        fixture.engine.onEvent?(.loaded(requestID))
        fixture.engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 63, duration: 100,
            isPaused: true, isSeeking: false, isBuffering: false, isSeekable: true, volume: 70
        )))
        let destination = fixture.root.appending(path: "backup.json")
        let originalBackup = Data("previous backup must survive".utf8)
        try originalBackup.write(to: destination)
        let connection = try DatabaseQueue(path: fixture.databasePath)
        try await connection.write { db in
            try db.execute(sql: """
                CREATE TRIGGER fail_export_checkpoint BEFORE INSERT ON playback_history
                BEGIN SELECT RAISE(ABORT, 'forced checkpoint failure'); END
                """)
        }
        do {
            try await fixture.operations.exportArchive(to: destination)
            XCTFail("Export must not silently use stale history after a failed checkpoint")
        } catch let error as DatabaseError {
            fixture.player.reportDataManagementError(error)
        }
        XCTAssertEqual(try Data(contentsOf: destination), originalBackup)
        XCTAssertNotNil(fixture.player.persistenceError)
        XCTAssertNotNil(fixture.player.dataManagementError)
        XCTAssertFalse(fixture.operations.isWorking)
        XCTAssertFalse(fixture.library.isReplacingRecords)
        try await connection.write { db in try db.execute(sql: "DROP TRIGGER fail_export_checkpoint") }
        try await fixture.operations.exportArchive(to: destination)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(MediaLibraryArchive.self, from: Data(contentsOf: destination))
        XCTAssertEqual(archive.files.first?.history?.position, 63)
        XCTAssertNil(fixture.player.persistenceError)
        XCTAssertNil(fixture.player.dataManagementError)

        let unreachable = fixture.root.appending(path: "missing/backup.json")
        do {
            try await fixture.operations.exportArchive(to: unreachable)
            XCTFail("A destination write failure must be reported")
        } catch { }
        XCTAssertFalse(fixture.operations.isWorking)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreachable.path))
        XCTAssertEqual(try Data(contentsOf: fixture.media), Data("original media".utf8))
        await fixture.operations.shutdown()
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    @MainActor
    func testRecordOperationShutdownWaitsForAcceptedClearAndRejectsNewOperations() async throws {
        let started = expectation(description: "manual scanner started")
        let gate = RecordScanGate()
        let fixture = try await makeRecordOperationFixture(scanner: GatedRecordScanner(
            gate: gate, didStart: started))
        defer {
            fixture.defaults.removePersistentDomain(forName: fixture.suite)
            try? FileManager.default.removeItem(at: fixture.root)
        }
        fixture.library.addFolder(fixture.root)
        await fulfillment(of: [started], timeout: 2)
        let clearing = Task { try await fixture.operations.clearRecords() }
        try await waitUntil { fixture.operations.isWorking && fixture.library.isReplacingRecords }
        do {
            try await fixture.operations.clearRecords()
            XCTFail("An overlapping destructive operation must be rejected")
        } catch { }
        let item = try XCTUnwrap(fixture.library.items.first)
        fixture.library.addFolder(fixture.root)
        fixture.library.setCategory(.movie, for: item)
        await fixture.library.toggleFavorite(item)
        var didShutDown = false
        let shuttingDown = Task {
            await fixture.operations.shutdown()
            didShutDown = true
        }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(didShutDown, "Exit must wait while the accepted clear is draining its scan")
        await gate.release()
        await shuttingDown.value
        try await clearing.value
        XCTAssertTrue(fixture.library.items.isEmpty)
        do {
            try await fixture.operations.clearRecords()
            XCTFail("Shutdown must reject new record operations")
        } catch is CancellationError { }
        await fixture.sync.stop()
        await fixture.library.shutdown()
        await fixture.player.shutdown()
    }

    @MainActor
    private func makeRecordOperationFixture(
        scanner: (any MediaLibraryScanning)? = nil
    ) async throws -> RecordOperationFixture {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let media = root.appending(path: "original.mp4")
        try Data("original media".utf8).write(to: media)
        let databasePath = root.appending(path: "library.sqlite").path
        let store = try PlaybackHistoryStore(path: databasePath)
        for try await _ in MediaLibraryScanner(historyStore: store).scan(folder: root).events { }
        let library = MediaLibraryModel(store: store, thumbnailCache: nil, scanner: scanner)
        await library.refresh()
        let suite = "Bomu.RecordOperations.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine, historyStore: store,
                                 preferences: PlaybackPreferences(defaults: defaults))
        let sync = MediaLibrarySyncCoordinator(historyStore: store) { await library.refresh() }
        let operations = MediaLibraryRecordOperations(library: library, sync: sync, player: player)
        return RecordOperationFixture(root: root, media: media, databasePath: databasePath,
            suite: suite, defaults: defaults, store: store, library: library, player: player,
            engine: engine, sync: sync, operations: operations)
    }

    private struct RecordOperationFixture {
        let root: URL
        let media: URL
        let databasePath: String
        let suite: String
        let defaults: UserDefaults
        let store: PlaybackHistoryStore
        let library: MediaLibraryModel
        let player: PlayerModel
        let engine: RecordingPlaybackEngine
        let sync: MediaLibrarySyncCoordinator
        let operations: MediaLibraryRecordOperations
    }

    private func waitUntilStartupSettles(_ player: PlayerModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while player.startupState == .preparing || player.startupState == .notStarted {
            guard clock.now < deadline else { throw PreparationFailure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !condition() {
            guard clock.now < deadline else { throw PreparationFailure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private enum PreparationFailure: Error {
        case timedOut
    }
}


private actor FailingLibraryStore: MediaLibraryPersisting {
    enum Failure: Error { case expected }

    private let failingClearAllCalls: Set<Int>
    private var clearAllCallCount = 0
    private(set) var saveCount = 0

    init(failingClearAllCalls: Set<Int> = []) {
        self.failingClearAllCalls = failingClearAllCalls
    }

    func history(for url: URL) async throws -> PlaybackHistory? { nil }

    func save(for url: URL, position: Double, audioTrackID: Int?, subtitleTrackID: Int?,
              volume: Double, updatedAt: Date) async throws {
        saveCount += 1
    }

    func clearAll() async throws {
        clearAllCallCount += 1
        if failingClearAllCalls.contains(clearAllCallCount) { throw Failure.expected }
    }

    func setHistoryExcludedFolder(_ folder: URL, excluded: Bool) async throws { }
    func removeHistoryExcludedFolder(_ folder: HistoryExcludedFolder) async throws { }
    func historyExcludedFolders() async throws -> [HistoryExcludedFolder] { [] }

    func clearLibraryRecords() async throws { throw Failure.expected }

    func exportArchive(settings: MediaLibraryArchive.Settings) async throws -> Data {
        throw Failure.expected
    }

    func previewArchiveImport(_ data: Data) async throws -> MediaLibraryImportPreview {
        throw Failure.expected
    }

    func importArchive(_ data: Data) async throws -> MediaLibraryImportResult {
        throw Failure.expected
    }
}

private actor BlockingHistoryStore: PlaybackHistoryPersisting {
    private var saveStarted = false
    private var saveStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var pendingSave: CheckedContinuation<Void, Never>?

    func history(for url: URL) async throws -> PlaybackHistory? { nil }

    func save(for url: URL, position: Double, audioTrackID: Int?, subtitleTrackID: Int?,
              volume: Double, updatedAt: Date) async throws {
        saveStarted = true
        let waiters = saveStartWaiters
        saveStartWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { pendingSave = $0 }
    }

    func clearAll() async throws { }

    func waitUntilSaveStarts() async {
        if saveStarted { return }
        await withCheckedContinuation { saveStartWaiters.append($0) }
    }

    func finishPendingSave() {
        pendingSave?.resume()
        pendingSave = nil
    }
}

private actor FailingHistoryStore: PlaybackHistoryPersisting {
    enum Failure: LocalizedError {
        case checkpoint
        var errorDescription: String? { "Injected checkpoint failure." }
    }

    private(set) var saveCount = 0

    func history(for url: URL) async throws -> PlaybackHistory? { nil }

    func save(for url: URL, position: Double, audioTrackID: Int?, subtitleTrackID: Int?,
              volume: Double, updatedAt: Date) async throws {
        saveCount += 1
        throw Failure.checkpoint
    }

    func clearAll() async throws { }
}

private actor ConflictingHistoryStore: PlaybackHistoryPersisting {
    private(set) var saveCount = 0

    func history(for url: URL) async throws -> PlaybackHistory? {
        throw PlaybackHistoryError.ambiguousMediaIdentity
    }

    func save(for url: URL, position: Double, audioTrackID: Int?, subtitleTrackID: Int?,
              volume: Double, updatedAt: Date) async throws {
        saveCount += 1
        throw PlaybackHistoryError.ambiguousMediaIdentity
    }

    func clearAll() async throws { }
}

private actor RecordScanGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private struct GatedRecordScanner: MediaLibraryScanning {
    let gate: RecordScanGate
    let didStart: XCTestExpectation

    func scan(folder: URL, includingSubfolders: Bool) -> MediaLibraryScan {
        let (events, continuation) = AsyncThrowingStream<MediaLibraryScanEvent, Error>.makeStream()
        let task = Task {
            didStart.fulfill()
            await gate.wait()
            continuation.finish()
        }
        return MediaLibraryScan(events: events, task: task)
    }
}

