import XCTest

// The hostless BomuLogicTests target compiles the same production state/model
// files directly. No application entry point, AppKit renderer or native core is linked.

final class PlaybackStateTests: XCTestCase {
    func testLateEventsCannotReplaceNewFile() {
        var state = PlaybackState()
        state.open(request(1))
        state.receive(.loaded(1))
        state.open(request(2))
        state.receive(.failed(1, "old failure"))
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
        state.receive(.failed(1, "late failure"))
        XCTAssertEqual(state.phase, .idle)
        XCTAssertNil(state.request)
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
        XCTAssertEqual(player.state.phase, .idle)
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

    private func waitUntilPrepared(_ player: PlayerModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !player.isPrepared {
            if let error = player.startupError { throw PreparationFailure.failed(error) }
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
    var shutdownCount = 0
    func prepare() async throws { await Task.yield() }
    func open(_ request: PlaybackRequest) { requests.append(request) }
    func setPaused(_ request: PlaybackPauseRequest) { pauses.append(request.isPaused) }
    func seek(_ request: PlaybackSeekRequest) { seeks.append(request) }
    func setVolume(_ volume: Double) {}
    func stop() {}
    func shutdown() async { shutdownCount += 1 }
}
