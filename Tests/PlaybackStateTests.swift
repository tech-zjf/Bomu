import XCTest

// Pure playback state tests run without an app host or native playback core.

final class PlaybackStateTests: XCTestCase {
    func testWaitingActivityTracksCurrentEngineFactsWithoutChangingPause() {
        var state = PlaybackState()
        XCTAssertNil(state.activity)
        state.open(request(1))
        XCTAssertEqual(state.activity, .opening)
        state.receive(.loaded(1))
        XCTAssertEqual(state.activity, .opening, "Loaded alone has no timeline facts yet")

        var value = snapshot(1)
        value.isPaused = true
        value.isBuffering = true
        state.receive(.snapshot(value))
        XCTAssertEqual(state.activity, .buffering)
        XCTAssertEqual(state.snapshot?.isPaused, true)

        value.isSeeking = true
        state.receive(.snapshot(value))
        XCTAssertEqual(state.activity, .seeking, "Seeking explains waiting when both flags are set")
        value.isSeeking = false
        state.receive(.snapshot(value))
        XCTAssertEqual(state.activity, .buffering)
        value.isBuffering = false
        state.receive(.snapshot(value))
        XCTAssertNil(state.activity)
        XCTAssertEqual(state.snapshot?.isPaused, true, "Waiting completion must not resume playback")

        state.open(request(2))
        value.isSeeking = true
        state.receive(.snapshot(value))
        XCTAssertEqual(state.activity, .opening, "An obsolete seek cannot change the new request's activity")
        state.receive(.failed(2, PlaybackFailure(kind: .unavailable)))
        XCTAssertNil(state.activity)
        state.open(request(3))
        state.receive(.loaded(3))
        var ending = snapshot(3)
        ending.isBuffering = true
        state.receive(.snapshot(ending))
        state.receive(.ended(3))
        XCTAssertNil(state.activity, "Terminal state must not retain a waiting indicator")
        state.stop()
        XCTAssertNil(state.activity)
    }

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

    func testCommandFailureLeavesPlaybackReadyAndCanBeDismissed() {
        var state = PlaybackState()
        state.open(request(1))
        state.receive(.loaded(1))
        state.receive(.snapshot(snapshot(1)))
        let failure = PlaybackCommandFailure(kind: .subtitle, detail: "subtitle decoder error")

        state.receive(.commandFailed(1, failure))

        XCTAssertEqual(state.phase, .ready)
        XCTAssertEqual(state.snapshot, snapshot(1))
        XCTAssertEqual(state.commandFailure, failure)
        state.dismissCommandFailure()
        XCTAssertNil(state.commandFailure)
    }

    func testCommandFailureIsIgnoredForStaleOrUnreadyRequests() {
        var state = PlaybackState()
        state.open(request(1))
        let failure = PlaybackCommandFailure(kind: .audioTrack)

        state.receive(.commandFailed(1, failure))
        XCTAssertNil(state.commandFailure)

        state.receive(.loaded(1))
        state.open(request(2))
        state.receive(.commandFailed(1, failure))
        XCTAssertNil(state.commandFailure)
        XCTAssertEqual(state.phase, .opening)
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

    func testLateFailureCannotReplaceEndedPlayback() {
        var state = PlaybackState()
        state.open(request(1))
        state.receive(.loaded(1))
        state.receive(.snapshot(snapshot(1)))
        state.receive(.ended(1))

        state.receive(.failed(1, PlaybackFailure(kind: .engine, detail: "late queue event")))

        XCTAssertEqual(state.phase, .ended)
        XCTAssertEqual(state.snapshot, snapshot(1))
    }

    func testFirstFailureRemainsAuthoritativeForTheRequest() {
        var state = PlaybackState()
        state.open(request(1))
        let originalFailure = PlaybackFailure(kind: .unsupportedOrDamaged, detail: "decoder failed")
        state.receive(.failed(1, originalFailure))

        state.receive(.failed(1, PlaybackFailure(kind: .engine, detail: "later queue event")))
        state.receive(.loaded(1))

        XCTAssertEqual(state.phase, .failed(originalFailure))
    }

    private func request(_ id: UInt64) -> PlaybackRequest {
        PlaybackRequest(id: id, url: URL(fileURLWithPath: "/sample-\(id).mp4"))
    }

    private func snapshot(_ id: UInt64) -> PlaybackSnapshot {
        PlaybackSnapshot(requestID: id, pauseCommandID: 0, position: 3, duration: 15, isPaused: false,
                         isSeeking: false, isBuffering: false, isSeekable: true, volume: 100)
    }
}
