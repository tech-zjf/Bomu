import MediaPlayer
import XCTest

@MainActor
final class NowPlayingControllerTests: XCTestCase {
    func testSystemNowPlayingPublishesWaitingPauseAndSpeedWithoutChangingIntent() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let system = RecordingNowPlayingSystem()
        let controller = NowPlayingController(player: player, system: system)
        controller.update()
        XCTAssertEqual(system.deactivations, 0, "An inactive controller must not touch system ownership")
        player.open(URL(filePath: "/private/media/session.mp4"))
        try await waitUntilPrepared(player)
        let id = try XCTUnwrap(player.state.request?.id)
        engine.onEvent?(.loaded(id))
        var snapshot = PlaybackSnapshot(requestID: id, pauseCommandID: 0, position: 4, duration: 60,
            isPaused: false, isSeeking: false, isBuffering: false, isSeekable: true, volume: 80, speed: 1.25)
        engine.onEvent?(.snapshot(snapshot))
        controller.update()
        XCTAssertEqual(system.publications.last?.playbackState, .playing)
        XCTAssertEqual(system.publications.last?.rate, 1.25)
        XCTAssertEqual(system.publications.last?.title, "session")
        XCTAssertFalse(system.nextEnabled)
        XCTAssertFalse(system.previousEnabled)
        controller.update()
        XCTAssertEqual(system.publications.count, 1, "An unchanged position must not flood the system")

        snapshot.isBuffering = true
        engine.onEvent?(.snapshot(snapshot))
        controller.update()
        XCTAssertEqual(system.publications.last?.playbackState, .interrupted)
        XCTAssertEqual(system.publications.last?.rate, 0)
        XCTAssertFalse(player.isPaused)
        XCTAssertTrue(engine.pauses.isEmpty, "Publishing a stall must not submit a pause command")

        player.togglePause()
        controller.update()
        XCTAssertEqual(system.publications.last?.playbackState, .paused)
        XCTAssertEqual(system.publications.last?.rate, 0)
        snapshot.isBuffering = false
        snapshot.isPaused = true
        snapshot.pauseCommandID = 1
        snapshot.speed = 2
        snapshot.duration = nil
        engine.onEvent?(.snapshot(snapshot))
        controller.update()
        let paused = try XCTUnwrap(system.publications.last)
        XCTAssertEqual(paused.defaultRate, 2, "Speed changes must publish even while the playback rate is zero")
        XCTAssertNil(paused.information[MPMediaItemPropertyPlaybackDuration])
        XCTAssertNil(paused.information[MPNowPlayingInfoPropertyAssetURL], "Do not publish the private file path")

        player.stop()
        controller.update()
        controller.update()
        XCTAssertEqual(system.deactivations, 1)
        await player.shutdown()
    }

    func testSystemMediaCallbacksCannotCrossRequestOrRegistrationBoundaries() async throws {
        let engine = RecordingPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let system = RecordingNowPlayingSystem()
        let controller = NowPlayingController(player: player, system: system)
        let url = URL(filePath: "/media/same-name.mp4")
        for iteration in 0..<2 {
            player.open(url)
            try await waitUntilPrepared(player)
            let id = try XCTUnwrap(player.state.request?.id)
            if iteration == 1 {
                system.handlers[0](.togglePause)
                XCTAssertTrue(engine.pauses.isEmpty, "Reject old commands even before the new registration is installed")
            }
            engine.onEvent?(.loaded(id))
            engine.onEvent?(.snapshot(PlaybackSnapshot(requestID: id, pauseCommandID: 0,
                position: 0, duration: 15, isPaused: false, isSeeking: false,
                isBuffering: false, isSeekable: true, volume: 80)))
            controller.update()
        }
        XCTAssertEqual(system.handlers.count, 2)
        XCTAssertEqual(system.publications.count, 2, "A new request with the same title/time still needs publication")
        system.handlers[0](.pause)
        XCTAssertTrue(engine.pauses.isEmpty)
        system.handlers[1](.pause)
        XCTAssertEqual(engine.pauses, [true])
        controller.deactivate()
        system.handlers[1](.play)
        XCTAssertEqual(engine.pauses, [true])
        controller.update()
        XCTAssertEqual(system.handlers.count, 3)
        system.handlers[1](.play)
        XCTAssertEqual(engine.pauses, [true], "Reactivating the same file must not revive an old registration")
        system.handlers[2](.play)
        XCTAssertEqual(engine.pauses, [true, false])
        controller.shutdown()
        controller.update()
        system.handlers[2](.pause)
        XCTAssertEqual(system.handlers.count, 3, "Late UI updates must not reactivate media keys during app shutdown")
        XCTAssertEqual(engine.pauses, [true, false])
        await player.shutdown()
    }

}

@MainActor
private final class RecordingNowPlayingSystem: NowPlayingSystem {
    var handlers: [@MainActor (NowPlayingCommand) -> Void] = []
    var publications: [NowPlayingMetadata] = []
    var deactivations = 0
    var nextEnabled = false
    var previousEnabled = false

    func activate(handler: @escaping @MainActor (NowPlayingCommand) -> Void) {
        handlers.append(handler)
    }
    func setQueueAvailability(next: Bool, previous: Bool) {
        nextEnabled = next
        previousEnabled = previous
    }
    func publish(_ metadata: NowPlayingMetadata) { publications.append(metadata) }
    func deactivate() { deactivations += 1 }
}
