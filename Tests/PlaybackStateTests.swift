import XCTest

// The hostless BomuLogicTests target compiles the same production state/model
// files directly. No application entry point, AppKit renderer or native core is linked.

final class PlaybackStateTests: XCTestCase {
    func testLateEventsCannotReplaceNewFile() {
        var state = PlaybackState()
        state.open(request(1))
        state.receive(.loaded(1))
        state.open(request(2))
        state.receive(.failed(1, PlaybackFailure(kind: .engine)))
        state.receive(.loaded(1))
        state.receive(.snapshot(snapshot(1)))
        state.receive(.ended(1))
        XCTAssertEqual(state.phase, .opening)
        XCTAssertNil(state.snapshot)
        state.receive(.loaded(2))
        state.receive(.snapshot(snapshot(2)))
        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.snapshot?.requestID, 2)
    }

    func testStopInvalidatesQueuedEvents() {
        var state = PlaybackState()
        state.open(request(1))
        state.stop()
        state.receive(.loaded(1))
        state.receive(.failed(1, PlaybackFailure(kind: .engine)))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.request)
    }

    func testCurrentFailureRetainsBoundedDiagnosticDetail() {
        var state = PlaybackState()
        state.open(request(4))
        let detail = String(repeating: "decoder error ", count: 40)

        state.receive(.failed(4, PlaybackFailure(kind: .unsupportedOrDamaged, detail: detail)))

        guard case .failed(let failure) = state.phase else {
            return XCTFail("Expected the active request failure")
        }
        XCTAssertEqual(failure.kind, .unsupportedOrDamaged)
        XCTAssertEqual(failure.detail?.count, 300)
        XCTAssertNil(PlaybackFailure(kind: .unavailable, detail: "/private/media/file.mkv").detail)
        XCTAssertNil(PlaybackFailure(kind: .permissionDenied, detail: "/private/media/file.mkv").detail)
    }

    func testSnapshotCannotReviveEndedPlayback() {
        var state = PlaybackState()
        state.open(request(1))
        state.receive(.loaded(1))
        state.receive(.ended(1))
        state.receive(.snapshot(snapshot(1)))
        XCTAssertEqual(state.phase, .ended)
        XCTAssertNil(state.snapshot)
    }

    private func request(_ id: UInt64) -> PlaybackRequest {
        PlaybackRequest(id: id, url: URL(fileURLWithPath: "/sample-\(id).mp4"))
    }

    private func snapshot(_ id: UInt64) -> PlaybackSnapshot {
        PlaybackSnapshot(requestID: id, pauseCommandID: 0, position: 3, duration: 15, isPaused: false,
                         isSeeking: false, isBuffering: false, isSeekable: true, volume: 100)
    }
}

@MainActor
final class PlayerModelTests: XCTestCase {
    func testOnlyLatestOpenIsSubmittedAfterStartup() async throws {
        let engine = RecordingEngine()
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
        let engine = RecordingEngine()
        let player = PlayerModel(engine: engine)
        let delayedIntent = try XCTUnwrap(player.beginInputResolution())
        let newerURL = URL(fileURLWithPath: "/newer-selection.mp4")
        player.open(newerURL)

        player.open([URL(fileURLWithPath: "/late-drop.mp4")], for: delayedIntent)

        XCTAssertEqual(player.state.request?.url, newerURL)
        XCTAssertEqual(player.queue.items, [newerURL])
        try await waitUntilPrepared(player)
        XCTAssertEqual(engine.requests.map(\.url), [newerURL])
        await player.shutdown()
    }

    func testStartupFailureIsVisibleAndRejectsMediaRequests() async throws {
        let engine = RecordingEngine()
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
        let engine = RecordingEngine()
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
        player.seek(to: -20)
        player.seek(to: 100)
        player.seek(to: .nan)
        XCTAssertEqual(engine.seeks, [
            PlaybackSeekRequest(requestID: id, target: .absolute(0)),
            PlaybackSeekRequest(requestID: id, target: .absolute(15))
        ])
        await player.shutdown()
    }

    func testShutdownPreventsPendingOpenAndRunsOnce() async {
        let engine = RecordingEngine()
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
        let engine = RecordingEngine()
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
        let engine = RecordingEngine()
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

        XCTAssertEqual(player.persistenceError, "Injected checkpoint failure.")
        XCTAssertEqual(player.startupState, .shutDown)
        XCTAssertEqual(engine.shutdownCount, 1, "A failed save must not retain the native playback resources")
        let saveCount = await store.saveCount
        XCTAssertEqual(saveCount, 1, "Shutdown attempts the final checkpoint exactly once")
    }

    func testSavedPlaybackStateFlushesOnShutdownAndReopensFromFreshStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "history.sqlite")
        let store = try PlaybackHistoryStore(path: databaseURL.path)
        let url = directory.appending(path: "resume.mkv")
        try Data("resume media".utf8).write(to: url)
        try await store.save(for: url, position: 42, audioTrackID: 3,
                             subtitleTrackID: 5, volume: 37)
        let engine = RecordingEngine()
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
        XCTAssertEqual(engine.seeks, [PlaybackSeekRequest(requestID: requestID, target: .absolute(42))])
        XCTAssertEqual(engine.audioTracks, [3])
        XCTAssertEqual(engine.subtitleTracks, [5])

        engine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: requestID, pauseCommandID: 0, position: 47.5, duration: 120,
            isPaused: true, isSeeking: false, isBuffering: false, isSeekable: true,
            volume: 28, audioTrackID: 4, subtitleTrackID: 6
        )))
        player.setSpeed(1.5)
        player.setSpeed(6)
        player.setSpeed(.infinity)
        XCTAssertEqual(engine.speeds, [1, 1.5, 4])
        await player.shutdown()

        let reopenedStore = try PlaybackHistoryStore(path: databaseURL.path)
        let saved = try await reopenedStore.history(for: url)
        XCTAssertEqual(saved?.position, 47.5)
        XCTAssertEqual(saved?.audioTrackID, 4)
        XCTAssertEqual(saved?.subtitleTrackID, 6)
        XCTAssertEqual(saved?.volume, 28)

        let restartedEngine = RecordingEngine()
        let restartedPlayer = PlayerModel(engine: restartedEngine, historyStore: reopenedStore)
        restartedPlayer.open(url)
        try await waitUntilPrepared(restartedPlayer)
        try await waitUntil { restartedEngine.requests.count == 1 }
        let restartedRequestID = try XCTUnwrap(restartedEngine.requests.first?.id)
        XCTAssertEqual(restartedEngine.volumes, [28], "A fresh player applies the saved volume before opening")
        restartedEngine.onEvent?(.loaded(restartedRequestID))
        XCTAssertEqual(restartedEngine.audioTracks, [4])
        XCTAssertEqual(restartedEngine.subtitleTracks, [6])
        restartedEngine.onEvent?(.snapshot(PlaybackSnapshot(
            requestID: restartedRequestID, pauseCommandID: 0, position: 0.2, duration: 120,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 28
        )))
        XCTAssertEqual(restartedEngine.seeks,
                       [PlaybackSeekRequest(requestID: restartedRequestID, target: .absolute(47.5))])
        await restartedPlayer.shutdown()
    }

    func testPlaybackProgressCheckpointIsWrittenDuringPlayback() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mkv")
        try Data("periodic checkpoint".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = RecordingEngine()
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
        let engine = RecordingEngine()
        let player = PlayerModel(engine: engine, historyStore: store, preferences: preferences)

        player.continuePlayback(url)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let continuedID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(continuedID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: continuedID, pauseCommandID: 0,
            position: 0.2, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))
        try await waitUntil { engine.seeks.count == 1 }
        XCTAssertEqual(engine.seeks.first?.target, .absolute(42))

        player.playFromBeginning(url)
        try await waitUntil { engine.requests.count == 2 }
        let beginningID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(beginningID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: beginningID, pauseCommandID: 0,
            position: 0.1, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(engine.seeks.map(\.target), [.absolute(42)])
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

        let engine = RecordingEngine()
        let player = PlayerModel(engine: engine, historyStore: store,
                                 preferences: PlaybackPreferences(defaults: defaults))
        player.open([url, nextURL])
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let originalQueue = player.queue
        XCTAssertEqual(originalQueue.items.map(\.lastPathComponent), ["episode-1.mp4", "episode-2.mp4"])
        let endedRequestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(endedRequestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: endedRequestID, pauseCommandID: 0,
            position: 0.2, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))
        try await waitUntil { engine.seeks == [PlaybackSeekRequest(requestID: endedRequestID, target: .absolute(42))] }
        engine.onEvent?(.ended(endedRequestID))
        XCTAssertEqual(player.state.phase, .ended)

        player.replay()
        try await waitUntil { engine.requests.count == 2 }
        let replayRequestID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(replayRequestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: replayRequestID, pauseCommandID: 0,
            position: 0.2, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))

        XCTAssertEqual(engine.seeks.map(\.target), [.absolute(42)],
                       "Replay is an explicit start-from-beginning action, regardless of the resume preference")
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
        let engine = RecordingEngine()
        let player = PlayerModel(engine: engine, historyStore: store,
                                 preferences: PlaybackPreferences(defaults: defaults))

        player.continuePlayback(url)
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }
        let failedRequestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.failed(failedRequestID, PlaybackFailure(kind: .unsupportedOrDamaged)))
        XCTAssertEqual(player.state.phase, .failed(PlaybackFailure(kind: .unsupportedOrDamaged)))

        player.retryCurrentMedia()
        try await waitUntil { engine.requests.count == 2 }
        let retriedRequestID = try XCTUnwrap(engine.requests.last?.id)
        engine.onEvent?(.loaded(retriedRequestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: retriedRequestID, pauseCommandID: 0,
            position: 0.2, duration: 120, isPaused: false, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 70)))
        try await waitUntil { engine.seeks.count == 1 }

        XCTAssertEqual(engine.seeks.first?.target, .absolute(42))
        await player.shutdown()
    }

    func testQueueAdvancesOnlyAfterNaturalEndAndCanRecoverFromFailure() async throws {
        let engine = RecordingEngine()
        let player = PlayerModel(engine: engine)
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
        engine.onEvent?(.ended(engine.requests[0].id))
        try await waitUntil { engine.requests.count == 2 }
        XCTAssertEqual(engine.requests[1].url, second)
        XCTAssertEqual(player.queue.currentURL, second)

        engine.onEvent?(.failed(engine.requests[1].id, PlaybackFailure(kind: .unsupportedOrDamaged)))
        XCTAssertEqual(player.state.phase, .failed(PlaybackFailure(kind: .unsupportedOrDamaged)))
        player.playQueueItem(at: 0)
        try await waitUntil { engine.requests.count == 3 }
        XCTAssertEqual(engine.requests[2].url, first)

        player.stop()
        XCTAssertEqual(player.state.phase, .idle)
        XCTAssertEqual(engine.requests.count, 3, "Manual stop does not advance the queue")
        await player.shutdown()
    }

    func testStopCancelsPendingBatchImportBeforeItCanOpenMedia() async throws {
        let engine = RecordingEngine()
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
        let engine = RecordingEngine()
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
        let player = PlayerModel(engine: engine, preferences: preferences)
        player.open([first, second])
        try await waitUntilPrepared(player)
        try await waitUntil { engine.requests.count == 1 }

        let requestID = engine.requests[0].id
        engine.onEvent?(.loaded(requestID))
        XCTAssertEqual(engine.speeds, [1.5])
        XCTAssertEqual(engine.subtitleDelays, [.init(seconds: -0.5, requestID: requestID)])
        engine.onEvent?(.ended(requestID))
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertEqual(player.state.phase, .ended)
        await player.shutdown()
    }

    func testClearingHistoryDoesNotRecreateTheActiveFileRecord() async throws {
        let engine = RecordingEngine()
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

        await player.clearPlaybackHistory()

        XCTAssertNil(player.historyClearError)
        let clearedWhilePlaying = try await store.history(for: url)
        XCTAssertNil(clearedWhilePlaying)
        await player.shutdown()
        let clearedAfterShutdown = try await store.history(for: url)
        XCTAssertNil(clearedAfterShutdown)
    }

    func testFailedLibraryClearRestoresActiveHistoryPersistence() async throws {
        let engine = RecordingEngine()
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
        let engine = RecordingEngine()
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

        await player.clearPlaybackHistory()
        await player.clearPlaybackHistory()
        XCTAssertNotNil(player.historyClearError)

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
        let engine = RecordingEngine()
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

        player.selectAudioTrack(5)
        player.selectSubtitleTrack(8)
        player.addExternalSubtitle(URL(filePath: "/media/external subtitle.srt"))
        player.adjustSubtitleDelay(by: 0.5)
        player.adjustSubtitleDelay(by: 0.5)
        player.resetSubtitleDelay()

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
        let engine = RecordingEngine()
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
        let engine = RecordingEngine()
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
        player.seek(to: 90)
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

    func testSeekCapabilityGatesBothAbsoluteAndRelativeCommands() async throws {
        let engine = RecordingEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/first.mp4"))
        try await waitUntilPrepared(player)
        let id = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(id))
        var snapshot = PlaybackSnapshot(requestID: id, pauseCommandID: 0, position: 3, duration: 15,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: false, volume: 100)
        for duration in [Double?.some(15), nil] {
            snapshot.duration = duration
            snapshot.isSeekable = duration == nil
            engine.onEvent?(.snapshot(snapshot))
            XCTAssertTrue(player.canControlPlayback)
            XCTAssertFalse(player.canSeek)
            player.seek(to: 10)
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
        let engine = RecordingEngine()
        let player = PlayerModel(engine: engine)
        player.open(URL(fileURLWithPath: "/paused.mp4"))
        try await waitUntilPrepared(player)
        let requestID = try XCTUnwrap(engine.requests.first?.id)
        engine.onEvent?(.loaded(requestID))
        engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: requestID, pauseCommandID: 0,
            position: 12, duration: 90, isPaused: true, isSeeking: false,
            isBuffering: false, isSeekable: true, volume: 100)))

        player.seek(to: 45)

        XCTAssertEqual(engine.seeks, [PlaybackSeekRequest(requestID: requestID, target: .absolute(45))])
        XCTAssertTrue(engine.pauses.isEmpty, "Seeking must not implicitly resume paused media")
        await player.shutdown()
    }

    private func waitUntilPrepared(_ player: PlayerModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !player.isPrepared {
            if let error = player.startupError { throw PreparationFailure.failed(error) }
            guard clock.now < deadline else { throw PreparationFailure.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
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
        case failed(String)
        case timedOut
    }
}

@MainActor
private final class RecordingEngine: PlaybackEngine {
    var onEvent: ((PlaybackEvent) -> Void)?
    var requests: [PlaybackRequest] = []
    var pauses: [Bool] = []
    var seeks: [PlaybackSeekRequest] = []
    var volumes: [Double] = []
    var speeds: [Double] = []
    var audioTracks: [Int] = []
    var subtitleTracks: [Int] = []
    var audioTrackRequests: [TrackCommand] = []
    var subtitleTrackRequests: [TrackCommand] = []
    var externalSubtitleRequests: [SubtitleCommand] = []
    var subtitleDelays: [SubtitleDelayCommand] = []
    var shutdownCount = 0
    var shouldFailPreparation = false
    func prepare() async throws {
        await Task.yield()
        if shouldFailPreparation { throw PreparationFailure.engineUnavailable }
    }
    func open(_ request: PlaybackRequest) { requests.append(request) }
    func setPaused(_ request: PlaybackPauseRequest) { pauses.append(request.isPaused) }
    func seek(_ request: PlaybackSeekRequest) { seeks.append(request) }
    func setVolume(_ volume: Double) { volumes.append(volume) }
    func setSpeed(_ speed: Double) { speeds.append(speed) }
    func setAudioTrack(id: Int, requestID: UInt64) {
        audioTracks.append(id)
        audioTrackRequests.append(TrackCommand(id: id, requestID: requestID))
    }
    func setSubtitleTrack(id: Int, requestID: UInt64) {
        subtitleTracks.append(id)
        subtitleTrackRequests.append(TrackCommand(id: id, requestID: requestID))
    }
    func addExternalSubtitle(_ url: URL, requestID: UInt64) {
        externalSubtitleRequests.append(SubtitleCommand(url: url, requestID: requestID))
    }
    func setSubtitleDelay(_ seconds: Double, requestID: UInt64) {
        subtitleDelays.append(SubtitleDelayCommand(seconds: seconds, requestID: requestID))
    }
    func stop() {}
    func shutdown() async { shutdownCount += 1 }

    private enum PreparationFailure: Error, LocalizedError {
        case engineUnavailable
        var errorDescription: String? { "The playback engine is unavailable." }
    }

    struct TrackCommand: Equatable {
        let id: Int
        let requestID: UInt64
    }

    struct SubtitleCommand: Equatable {
        let url: URL
        let requestID: UInt64
    }

    struct SubtitleDelayCommand: Equatable {
        let seconds: Double
        let requestID: UInt64
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
