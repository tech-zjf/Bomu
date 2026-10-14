@testable import Bomu
import AppKit
import XCTest

/// Runs the real bundled libmpv and the same OpenGL surface as the application.
/// Audible output, calibrated color and multi-display behavior still require manual acceptance.
@MainActor
final class MPVIntegrationTests: XCTestCase {
    func testRealPlaybackPauseSeekReplaceAndRelease() async throws {
        XCTAssertTrue(NSApplication.shared.isRunning, "Rendering tests require the Bomu application host")
        try await waitUntil { NSApplication.shared.windows.contains { $0.canBecomeMain && $0.isVisible } }
        let hostWindows = NSApplication.shared.windows.filter { $0.canBecomeMain && $0.isVisible }
        guard hostWindows.count == 1, let window = hostWindows.first else {
            throw NSError(domain: "Bomu.IntegrationWindow", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected exactly one visible application host window"])
        }
        let originalContent = try XCTUnwrap(window.contentView)
        let originalFrame = window.frame
        let screenKey = NSDeviceDescriptionKey("NSScreenNumber")
        let originalScreen = try XCTUnwrap(window.screen?.deviceDescription[screenKey] as? NSNumber)
        let windowNumber = window.windowNumber
        let engine = MPVPlaybackEngine()
        /** 测试只借用宿主窗口的内容；退出时恢复，不另建窗口、置前或关闭应用窗口。 */
        window.contentView = engine.videoView
        defer {
            window.contentView = originalContent
            window.setFrame(originalFrame, display: true)
        }
        var state = PlaybackState()
        engine.onEvent = { state.receive($0) }
        do {
            try await engine.prepare()
            let configuration = await engine.diagnostics()
            XCTAssertEqual(configuration.videoSyncMode, "audio")
            XCTAssertEqual(configuration.videoTimingOffset, 0)
            XCTAssertEqual(configuration.coreCreationCount, 1)
            XCTAssertEqual(configuration.renderContextCreationCount, 1)
            engine.setVolume(0)
            let first = PlaybackRequest(id: 1, url: try fixture("h264-sdr"))
            state.open(first)
            engine.open(first)
            try await waitUntil { (state.snapshot?.position ?? 0) > 0.3 }
            XCTAssertEqual(state.phase, .ready)
            XCTAssertEqual(try XCTUnwrap(state.snapshot?.duration), 15, accuracy: 0.1)
            engine.setPaused(PlaybackPauseRequest(requestID: first.id, commandID: 1, isPaused: true))
            try await waitUntil { state.snapshot?.isPaused == true && state.snapshot?.pauseCommandID == 1 }
            engine.seek(PlaybackSeekRequest(requestID: first.id, target: .absolute(5)))
            try await waitUntil { abs((state.snapshot?.position ?? 0) - 5) < 0.3 }
            XCTAssertEqual(state.snapshot?.isPaused, true)
            let second = PlaybackRequest(id: 2, url: try fixture("h265-main10-sdr"))
            state.open(second)
            engine.open(second)
            try await waitUntil { state.snapshot?.requestID == 2 && (state.snapshot?.position ?? 0) > 0.3 }
            XCTAssertEqual(state.snapshot?.isPaused, false)
            XCTAssertEqual(state.snapshot?.pauseCommandID, 0, "Replacing the file resets pause acknowledgement")
            // A command from the previous file must not change the replacement's pause state.
            engine.setPaused(PlaybackPauseRequest(requestID: first.id, commandID: 2, isPaused: true))
            engine.setPaused(PlaybackPauseRequest(requestID: second.id, commandID: 3, isPaused: true))
            engine.setPaused(PlaybackPauseRequest(requestID: second.id, commandID: 4, isPaused: false))
            engine.setPaused(PlaybackPauseRequest(requestID: second.id, commandID: 3, isPaused: true))
            try await waitUntil { state.snapshot?.pauseCommandID == 4 }
            XCTAssertEqual(state.snapshot?.isPaused, false)
            for index in 0..<20 {
                window.setContentSize(NSSize(width: 900 + index * 3, height: 600 + index * 2))
                await Task.yield()
                XCTAssertEqual(window.screen?.deviceDescription[screenKey] as? NSNumber, originalScreen)
            }
            XCTAssertEqual(window.windowNumber, windowNumber)
            XCTAssertEqual(NSApplication.shared.windows.filter { $0.canBecomeMain && $0.isVisible }.count, 1)
            let invalid = PlaybackRequest(id: 3, url: try fixture("corrupt"))
            state.open(invalid)
            engine.open(invalid)
            try await waitUntil { if case .failed = state.phase { return true }; return false }
            let recovered = PlaybackRequest(id: 4, url: try fixture("h264-sdr"))
            state.open(recovered)
            engine.open(recovered)
            try await waitUntil { state.snapshot?.requestID == 4 && (state.snapshot?.position ?? 0) > 0.3 }
            engine.seek(PlaybackSeekRequest(requestID: recovered.id, target: .absolute(14.8)))
            try await waitUntil { state.phase == .ended }
            state.stop()
            engine.stop()
            await engine.shutdown()
            XCTAssertEqual(state.phase, .idle)
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
            XCTAssertEqual(closed.coreCreationCount, 1, "Replacing media and resizing must reuse the native core")
            XCTAssertEqual(closed.renderContextCreationCount, 1, "The surface owns one render context until shutdown")
            print("Native render test reused host window \(windowNumber), display \(originalScreen)")
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    func testShutdownDuringFileOpening() async throws {
        let url = try fixture("h264-sdr")
        for id in UInt64(1)...10 {
            let engine = MPVPlaybackEngine()
            do {
                try await engine.prepare()
                engine.setVolume(0)
                engine.open(PlaybackRequest(id: id, url: url))
                // Shutdown is queued immediately, before file-loaded is acknowledged.
                await engine.shutdown()
                let closed = await engine.diagnostics()
                XCTAssertFalse(closed.coreAlive)
                XCTAssertFalse(closed.renderContextAlive)
            } catch {
                await engine.shutdown()
                throw error
            }
        }
    }

    func testUnavailableReplacementStopsPreviousFileAndCanRecover() async throws {
        // This case uses the app's event loop but does not create or manipulate a window.
        let engine = MPVPlaybackEngine()
        var state = PlaybackState()
        engine.onEvent = { state.receive($0) }
        do {
            try await engine.prepare()
            engine.setVolume(0)
            let media = try fixture("h264-sdr")
            let first = PlaybackRequest(id: 1, url: media)
            state.open(first)
            engine.open(first)
            try await waitUntil { (state.snapshot?.position ?? 0) > 0.2 }

            let missing = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            let replacement = PlaybackRequest(id: 2, url: missing)
            state.open(replacement)
            engine.open(replacement)
            try await waitUntil { if case .failed = state.phase { return true }; return false }
            try await waitUntil {
                let diagnostics = await engine.diagnostics()
                return diagnostics.idle == true && diagnostics.videoOutputConfigured == false
            }
            XCTAssertNil(state.snapshot)
            XCTAssertEqual(state.request?.id, 2)
            // Let callbacks already queued before stop settle, then observe a quiet interval.
            try await Task.sleep(for: .milliseconds(200))
            let stopped = await engine.diagnostics()
            try await Task.sleep(for: .milliseconds(300))
            let quiet = await engine.diagnostics()
            XCTAssertEqual(quiet.snapshotCount, stopped.snapshotCount)
            XCTAssertEqual(quiet.videoFrameCount, stopped.videoFrameCount)

            let recovered = PlaybackRequest(id: 3, url: media)
            state.open(recovered)
            engine.open(recovered)
            try await waitUntil { state.snapshot?.requestID == 3 && (state.snapshot?.position ?? 0) > 0.2 }
            let active = await engine.diagnostics()
            XCTAssertEqual(active.coreCreationCount, 1)
            XCTAssertEqual(active.renderContextCreationCount, 1)
            XCTAssertEqual(active.openCount, 2, "The unreachable request never reaches loadfile")
            await engine.shutdown()
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    func testRapidReplacementKeepsLatestRequest() async throws {
        let engine = MPVPlaybackEngine()
        var state = PlaybackState()
        engine.onEvent = { state.receive($0) }
        do {
            try await engine.prepare()
            engine.setVolume(0)
            let url = try fixture("h264-sdr")
            for id in UInt64(1)...100 {
                let request = PlaybackRequest(id: id, url: url)
                state.open(request)
                engine.open(request)
            }
            try await waitUntil { state.snapshot?.requestID == 100 && (state.snapshot?.position ?? 0) > 0.2 }
            await engine.shutdown()
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    func testRapidRelativeAndAbsoluteSeeksUseNativePositionAndRejectReplacedFile() async throws {
        // Uses the native event loop and render surface without creating a test window.
        let engine = MPVPlaybackEngine()
        let player = PlayerModel(engine: engine)
        do {
            player.prepare()
            try await waitUntil { player.isPrepared || player.startupError != nil }
            XCTAssertNil(player.startupError)
            player.setVolume(0)
            let media = try fixture("h264-sdr")
            player.open(media)
            try await waitUntil { player.canSeek }
            let firstID = try XCTUnwrap(player.state.request?.id)
            player.togglePause()
            try await waitUntil { player.state.snapshot?.isPaused == true }
            player.seek(to: 3)
            try await waitUntil { self.hasSettledPosition(player, seconds: 3) }

            player.skip(by: 2)
            player.skip(by: 2)
            player.skip(by: -1)
            try await waitUntil { self.hasSettledPosition(player, seconds: 6) }
            XCTAssertEqual(player.state.snapshot?.isPaused, true)
            player.seek(to: 9)
            player.skip(by: -2)
            player.skip(by: 1)
            try await waitUntil { self.hasSettledPosition(player, seconds: 8) }

            player.open(media)
            try await waitUntil { player.canSeek && player.state.snapshot?.requestID != firstID }
            player.togglePause()
            try await waitUntil { player.state.snapshot?.isPaused == true }
            player.seek(to: 3)
            try await waitUntil { self.hasSettledPosition(player, seconds: 3) }
            engine.seek(PlaybackSeekRequest(requestID: firstID, target: .absolute(12)))
            engine.seek(PlaybackSeekRequest(requestID: firstID, target: .relative(4)))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(hasSettledPosition(player, seconds: 3), "Old-file seeks must not affect the replacement")
            await player.shutdown()
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
        } catch {
            await player.shutdown()
            throw error
        }
    }

    private func hasSettledPosition(_ player: PlayerModel, seconds: Double) -> Bool {
        guard let snapshot = player.state.snapshot else { return false }
        return !snapshot.isSeeking && abs(snapshot.position - seconds) < 0.15
    }

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "mp4", subdirectory: "Fixtures"))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !(await condition()) {
            if Date() >= deadline { throw NSError(domain: "Bomu.IntegrationTimeout", code: 1) }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
