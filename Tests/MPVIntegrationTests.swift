@testable import Bomu
import AppKit
import ImageIO
import SwiftUI
import XCTest

/// Runs the real bundled libmpv and the same OpenGL surface as the application.
/// Audible output, calibrated color and multi-display behavior still require manual acceptance.
@MainActor
final class MPVIntegrationTests: XCTestCase {
    func testPlaybackOverlaySurvivesOneHundredWindowResizes() async throws {
        let window = try await applicationHostWindow()
        let originalContent = try XCTUnwrap(window.contentView)
        let originalFrame = window.frame
        let screenKey = NSDeviceDescriptionKey("NSScreenNumber")
        let originalScreen = try XCTUnwrap(window.screen?.deviceDescription[screenKey] as? NSNumber)
        let originalWindowNumber = window.windowNumber
        let engine = MPVPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let nowPlaying = NowPlayingController(player: player)
        window.contentView = NSHostingView(rootView: PlayerScreen(
            player: player,
            videoView: engine.videoView,
            nowPlaying: nowPlaying,
            isFavorite: false,
            canToggleFavorite: false,
            onToggleFavorite: {},
            onReturnToLibrary: {}
        ))
        defer {
            nowPlaying.deactivate()
            window.contentView = originalContent
            window.setFrame(originalFrame, display: true)
        }

        do {
            player.prepare()
            try await waitUntil { player.isPrepared || player.startupError != nil }
            XCTAssertNil(player.startupError)
            player.setVolume(0)
            player.open(try fixture("h264-sdr"))
            try await waitUntil { player.canControlPlayback }
            try await waitUntil { (player.state.snapshot?.position ?? 0) > 0.3 }
            let positionBeforeResizing = try XCTUnwrap(player.state.snapshot?.position)

            let sizes = [NSSize(width: 960, height: 640), NSSize(width: 1280, height: 800),
                         NSSize(width: 1440, height: 900)]
            for index in 0..<100 {
                window.setContentSize(sizes[index % sizes.count])
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(16))
                XCTAssertEqual(window.windowNumber, originalWindowNumber)
                XCTAssertEqual(window.screen?.deviceDescription[screenKey] as? NSNumber, originalScreen)
                XCTAssertEqual(NSApplication.shared.windows.filter { $0.canBecomeMain && $0.isVisible }.count, 1)
            }

            XCTAssertEqual(player.state.snapshot?.isPaused, false,
                           "Repeated layout changes must not pause active playback")
            XCTAssertGreaterThan(try XCTUnwrap(player.state.snapshot?.position), positionBeforeResizing + 0.2,
                                 "Playback must continue to advance during the resize sequence")

            let active = await engine.diagnostics()
            XCTAssertEqual(active.coreCreationCount, 1, "Window resizing must reuse the playback core")
            XCTAssertEqual(active.renderContextCreationCount, 1,
                           "The SwiftUI video host must retain its render context across layout changes")
            XCTAssertGreaterThan(active.videoFrameCount, 0, "The overlaid video surface must submit real frames")

            await player.shutdown()
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
            XCTAssertEqual(closed.graphicsContextAlive, false)
        } catch {
            await player.shutdown()
            throw error
        }
    }

    func testFinderDropProviderResolvesFileAndDirectoryURLs() async throws {
        _ = try await applicationHostWindow()
        let root = FileManager.default.temporaryDirectory.appending(path: "Bomu 拖放 \(UUID().uuidString)")
        let nested = root.appending(path: "媒体 文件")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "Episode 10 中文 file.mp4")
        let nestedFile = nested.appending(path: "Episode 2 中文 file.mkv")
        try Data().write(to: file)
        try Data().write(to: nestedFile)

        let providers = [NSItemProvider(object: file as NSURL), NSItemProvider(object: nested as NSURL)]
        var inputs: [URL] = []
        for provider in providers {
            let loaded = await FileURLProviderRequest().load(from: provider)
            inputs.append(try XCTUnwrap(loaded))
        }

        let discovered = try MediaFileDiscovery.expand(inputs)
        XCTAssertEqual(discovered.map(\.lastPathComponent), [
            "Episode 2 中文 file.mkv",
            "Episode 10 中文 file.mp4"
        ])
    }

    func testRealPlaybackPauseSeekReplaceAndRelease() async throws {
        let window = try await applicationHostWindow()
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
            XCTAssertEqual(configuration.graphicsContextAlive, true)
            engine.setVolume(0)
            let first = PlaybackRequest(id: 1, url: try fixture("h264-sdr"))
            state.open(first)
            engine.open(first)
            try await waitUntil { (state.snapshot?.position ?? 0) > 0.3 }
            XCTAssertEqual(state.phase, .ready)
            XCTAssertEqual(try XCTUnwrap(state.snapshot?.duration), 15, accuracy: 0.1)
            let audioTrack = try XCTUnwrap(state.snapshot?.tracks.first { $0.kind == .audio })
            XCTAssertTrue(audioTrack.isSelected)
            engine.setAudioTrack(id: audioTrack.id, requestID: first.id)
            engine.setSpeed(1.5)
            try await waitUntil { abs((state.snapshot?.speed ?? 1) - 1.5) < 0.01 }
            engine.setSpeed(1)
            try await waitUntil { abs((state.snapshot?.speed ?? 0) - 1) < 0.01 }
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
            guard case .failed(let playbackFailure) = state.phase else {
                return XCTFail("Corrupt media should produce a playback failure")
            }
            XCTAssertEqual(playbackFailure.kind, .unsupportedOrDamaged,
                           "A decoder/demux rejection should be presented as unsupported or damaged media")
            XCTAssertFalse(playbackFailure.detail?.isEmpty ?? true)
            XCTAssertLessThanOrEqual(playbackFailure.detail?.count ?? 0, 300)
            let recovered = PlaybackRequest(id: 4, url: try fixture("h264-sdr"))
            state.open(recovered)
            var firstRestoredPosition: Double?
            engine.onEvent = { event in
                if case .snapshot(let snapshot) = event, snapshot.requestID == recovered.id,
                   firstRestoredPosition == nil {
                    firstRestoredPosition = snapshot.position
                }
                state.receive(event)
            }
            let restoredPosition = try XCTUnwrap(PlaybackStartPosition(seconds: 5))
            engine.open(recovered, options: PlaybackOpenOptions(startPosition: restoredPosition))
            try await waitUntil { state.snapshot?.requestID == 4 && (state.snapshot?.position ?? 0) > 0.3 }
            XCTAssertEqual(try XCTUnwrap(firstRestoredPosition), 5, accuracy: 0.4,
                           "The first native snapshot must begin at the restored position")
            engine.seek(PlaybackSeekRequest(requestID: recovered.id, target: .absolute(14.8)))
            try await waitUntil { state.phase == .ended }
            state.stop()
            engine.stop()
            await engine.shutdown()
            XCTAssertEqual(state.phase, .idle)
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
            XCTAssertEqual(closed.graphicsContextAlive, false)
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
                XCTAssertEqual(closed.graphicsContextAlive, false)
            } catch {
                await engine.shutdown()
                throw error
            }
        }
    }

    func testThumbnailCacheExtractsAFrameFromLocalVideo() async throws {
        let source = try fixture("h264-sdr")
        let original = try Data(contentsOf: source)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = MediaThumbnailCache(directory: directory, timeout: .seconds(10))

        let thumbnail = try await cache.thumbnail(mediaFileID: 1, contentRevision: "fixture-v1",
                                                  sourceURL: source)
        let imageSource = try XCTUnwrap(CGImageSourceCreateWithURL(thumbnail as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))

        XCTAssertGreaterThan(image.width, 0)
        XCTAssertGreaterThan(image.height, 0)
        XCTAssertEqual(try Data(contentsOf: source), original, "Thumbnail extraction must preserve source media")
    }

    func testRealAudioTrackSelectionUsesCurrentTrackIDs() async throws {
        let window = try await applicationHostWindow()
        let originalContent = try XCTUnwrap(window.contentView)
        let engine = MPVPlaybackEngine()
        let player = PlayerModel(engine: engine)
        window.contentView = engine.videoView
        defer { window.contentView = originalContent }

        do {
            player.prepare()
            try await waitUntil { player.isPrepared || player.startupError != nil }
            XCTAssertNil(player.startupError)
            player.setVolume(0)
            player.open(try fixture("mixed-audio-tracks"))
            try await waitUntil {
                player.canControlPlayback && player.state.snapshot?.tracks.filter { $0.kind == .audio }.count == 2
            }
            player.togglePause()
            try await waitUntil { player.state.snapshot?.isPaused == true }

            let audioTracks = try XCTUnwrap(player.state.snapshot?.tracks.filter { $0.kind == .audio })
            let initialTrack = try XCTUnwrap(audioTracks.first(where: \.isSelected))
            let alternateTrack = try XCTUnwrap(audioTracks.first { $0.id != initialTrack.id })
            let trackRequestID = try XCTUnwrap(player.state.request?.id)
            player.selectAudioTrack(alternateTrack.id, requestID: trackRequestID)
            try await waitUntil {
                player.state.snapshot?.audioTrackID == alternateTrack.id
                    && player.state.snapshot?.tracks.first { $0.id == alternateTrack.id }?.isSelected == true
            }

            player.selectAudioTrack(initialTrack.id, requestID: trackRequestID)
            try await waitUntil {
                player.state.snapshot?.audioTrackID == initialTrack.id
                    && player.state.snapshot?.tracks.first { $0.id == initialTrack.id }?.isSelected == true
            }

            await player.shutdown()
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
            XCTAssertEqual(closed.graphicsContextAlive, false)
        } catch {
            await player.shutdown()
            throw error
        }
    }

    func testSavedAudioTrackAndPositionRestoreInNewNativeSession() async throws {
        let window = try await applicationHostWindow()
        let originalContent = try XCTUnwrap(window.contentView)
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            window.contentView = originalContent
            try? FileManager.default.removeItem(at: directory)
        }
        let media = directory.appending(path: "恢复测试.mp4")
        try FileManager.default.copyItem(at: fixture("mixed-audio-tracks"), to: media)
        let store = try PlaybackHistoryStore(path: directory.appending(path: "history.sqlite").path)

        let firstEngine = MPVPlaybackEngine()
        let firstPlayer = PlayerModel(engine: firstEngine, historyStore: store)
        window.contentView = firstEngine.videoView
        do {
            firstPlayer.prepare()
            try await waitUntil { firstPlayer.isPrepared || firstPlayer.startupError != nil }
            XCTAssertNil(firstPlayer.startupError)
            firstPlayer.setVolume(0)
            firstPlayer.open(media)
            try await waitUntil {
                firstPlayer.canControlPlayback
                    && firstPlayer.state.snapshot?.tracks.filter { $0.kind == .audio }.count == 2
            }
            firstPlayer.togglePause()
            try await waitUntil { firstPlayer.state.snapshot?.isPaused == true }

            let initialTrack = try XCTUnwrap(firstPlayer.state.snapshot?.tracks.first {
                $0.kind == .audio && $0.isSelected
            })
            let restoredTrack = try XCTUnwrap(firstPlayer.state.snapshot?.tracks.first {
                $0.kind == .audio && $0.id != initialTrack.id
            })
            firstPlayer.selectAudioTrack(restoredTrack.id, requestID: try XCTUnwrap(firstPlayer.state.request?.id))
            try await waitUntil {
                firstPlayer.state.snapshot?.audioTrackID == restoredTrack.id
                    && firstPlayer.state.snapshot?.tracks.first { $0.id == restoredTrack.id }?.isSelected == true
            }
            firstPlayer.seek(to: 1.2, requestID: try XCTUnwrap(firstPlayer.state.request?.id))
            try await waitUntil { self.hasSettledPosition(firstPlayer, seconds: 1.2) }
            XCTAssertTrue(firstPlayer.state.snapshot?.isPaused == true)
            await firstPlayer.shutdown()

            let saved = try await store.history(for: media)
            XCTAssertEqual(saved?.audioTrackID, restoredTrack.id)
            XCTAssertEqual(saved?.position ?? -1, 1.2, accuracy: 0.2)
            let firstClosed = await firstEngine.diagnostics()
            XCTAssertFalse(firstClosed.coreAlive)
            XCTAssertFalse(firstClosed.renderContextAlive)
            XCTAssertEqual(firstClosed.graphicsContextAlive, false)

            let secondEngine = MPVPlaybackEngine()
            let secondPlayer = PlayerModel(engine: secondEngine, historyStore: store)
            window.contentView = secondEngine.videoView
            do {
                secondPlayer.prepare()
                try await waitUntil { secondPlayer.isPrepared || secondPlayer.startupError != nil }
                XCTAssertNil(secondPlayer.startupError)
                secondPlayer.setVolume(0)
                secondPlayer.open(media)
                try await waitUntil {
                    secondPlayer.state.snapshot?.audioTrackID == restoredTrack.id
                        && secondPlayer.state.snapshot?.tracks.first { $0.id == restoredTrack.id }?.isSelected == true
                        && self.hasSettledPosition(secondPlayer, seconds: 1.2)
                }
                await secondPlayer.shutdown()
                let secondClosed = await secondEngine.diagnostics()
                XCTAssertFalse(secondClosed.coreAlive)
                XCTAssertFalse(secondClosed.renderContextAlive)
                XCTAssertEqual(secondClosed.graphicsContextAlive, false)
            } catch {
                await secondPlayer.shutdown()
                throw error
            }
        } catch {
            await firstPlayer.shutdown()
            throw error
        }
    }

    func testMPEG2ProgramStreamPausedAbsoluteSeekSettlesAtRequestedPosition() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "mpeg2-pal-program-stream", withExtension: "mpg", subdirectory: "Fixtures"
        ))
        let engine = MPVPlaybackEngine()
        let player = PlayerModel(engine: engine)
        var positionBeforeSeek: Double?
        do {
            player.prepare()
            try await waitUntil { player.isPrepared || player.startupError != nil }
            XCTAssertNil(player.startupError)
            player.setVolume(0)
            player.open(url)
            try await waitUntil { player.canSeek && (player.state.snapshot?.position ?? 0) > 0.5 }
            player.togglePause()
            try await waitUntil { player.state.snapshot?.isPaused == true }
            positionBeforeSeek = player.state.snapshot?.position
            player.seek(to: 3, requestID: try XCTUnwrap(player.state.request?.id))
            try await waitUntil { self.hasSettledPosition(player, seconds: 3) }
            XCTAssertTrue(player.state.snapshot?.isPaused == true)
            XCTAssertEqual(player.state.snapshot?.position ?? -1, 3, accuracy: 0.2)
            await player.shutdown()
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
            XCTAssertEqual(closed.graphicsContextAlive, false)
        } catch {
            let snapshot = player.state.snapshot
            let failure = "beforeSeek=\(positionBeforeSeek?.description ?? "nil"), position=\(snapshot?.position.description ?? "nil"), seeking=\(snapshot?.isSeeking.description ?? "nil"), paused=\(snapshot?.isPaused.description ?? "nil"). Error: \(error)"
            await player.shutdown()
            XCTFail("Paused MPEG-2 seek failed. Snapshot: \(failure)")
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
            guard case .failed(let missingFailure) = state.phase else {
                return XCTFail("Missing media should produce a playback failure")
            }
            XCTAssertNil(missingFailure.detail, "Unavailable media must not expose native path text")
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

            let unreadable = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("mp4")
            try FileManager.default.copyItem(at: media, to: unreadable)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadable.path)
                try? FileManager.default.removeItem(at: unreadable)
            }
            let deniedRequest = PlaybackRequest(id: 3, url: unreadable)
            state.open(deniedRequest)
            engine.open(deniedRequest)
            try await waitUntil { if case .failed = state.phase { return true }; return false }
            guard case .failed(let permissionFailure) = state.phase else {
                return XCTFail("Unreadable media should produce a permission failure")
            }
            XCTAssertEqual(permissionFailure.kind, .permissionDenied)
            XCTAssertNil(permissionFailure.detail, "Permission failures must not expose media paths")
            try await waitUntil {
                let diagnostics = await engine.diagnostics()
                return diagnostics.idle == true && diagnostics.videoOutputConfigured == false
            }

            let recovered = PlaybackRequest(id: 4, url: media)
            state.open(recovered)
            engine.open(recovered)
            try await waitUntil { state.snapshot?.requestID == 4 && (state.snapshot?.position ?? 0) > 0.2 }
            let active = await engine.diagnostics()
            XCTAssertEqual(active.coreCreationCount, 1)
            XCTAssertEqual(active.renderContextCreationCount, 1)
            XCTAssertEqual(active.openCount, 2, "Unavailable and unreadable requests never reach loadfile")
            await engine.shutdown()
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
            XCTAssertEqual(closed.graphicsContextAlive, false)
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
            player.seek(to: 3, requestID: try XCTUnwrap(player.state.request?.id))
            try await waitUntil { self.hasSettledPosition(player, seconds: 3) }

            player.skip(by: 2)
            player.skip(by: 2)
            player.skip(by: -1)
            try await waitUntil { self.hasSettledPosition(player, seconds: 6) }
            XCTAssertEqual(player.state.snapshot?.isPaused, true)
            player.seek(to: 9, requestID: try XCTUnwrap(player.state.request?.id))
            player.skip(by: -2)
            player.skip(by: 1)
            try await waitUntil { self.hasSettledPosition(player, seconds: 8) }

            player.open(media)
            try await waitUntil { player.canSeek && player.state.snapshot?.requestID != firstID }
            player.togglePause()
            try await waitUntil { player.state.snapshot?.isPaused == true }
            player.seek(to: 3, requestID: try XCTUnwrap(player.state.request?.id))
            try await waitUntil { self.hasSettledPosition(player, seconds: 3) }
            player.seek(to: 12, requestID: firstID)
            engine.seek(PlaybackSeekRequest(requestID: firstID, target: .absolute(12)))
            engine.seek(PlaybackSeekRequest(requestID: firstID, target: .relative(4)))
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(hasSettledPosition(player, seconds: 3), "Old-file seeks must not affect the replacement")
            await player.shutdown()
            let closed = await engine.diagnostics()
            XCTAssertFalse(closed.coreAlive)
            XCTAssertFalse(closed.renderContextAlive)
            XCTAssertEqual(closed.graphicsContextAlive, false)
        } catch {
            await player.shutdown()
            throw error
        }
    }

    func testSavedPlaybackStateRestoresPositionInNewNativeSession() async throws {
        let store = try PlaybackHistoryStore(path: ":memory:")
        let media = try fixture("h264-sdr")
        let firstEngine = MPVPlaybackEngine()
        let firstPlayer = PlayerModel(engine: firstEngine, historyStore: store)
        do {
            firstPlayer.prepare()
            try await waitUntil { firstPlayer.isPrepared || firstPlayer.startupError != nil }
            XCTAssertNil(firstPlayer.startupError)
            firstPlayer.setVolume(0)
            firstPlayer.open(media)
            try await waitUntil { firstPlayer.canSeek }
            firstPlayer.seek(to: 6, requestID: try XCTUnwrap(firstPlayer.state.request?.id))
            try await waitUntil { self.hasSettledPosition(firstPlayer, seconds: 6) }
            firstPlayer.togglePause()
            try await waitUntil { firstPlayer.state.snapshot?.isPaused == true }
            await firstPlayer.shutdown()

            let saved = try await store.history(for: media)
            XCTAssertEqual(saved?.position ?? -1, 6, accuracy: 0.3)

            let secondEngine = MPVPlaybackEngine()
            let secondPlayer = PlayerModel(engine: secondEngine, historyStore: store)
            do {
                secondPlayer.prepare()
                try await waitUntil { secondPlayer.isPrepared || secondPlayer.startupError != nil }
                XCTAssertNil(secondPlayer.startupError)
                secondPlayer.setVolume(0)
                secondPlayer.open(media)
                try await waitUntil { self.hasSettledPosition(secondPlayer, seconds: 6) }
                XCTAssertTrue(secondPlayer.canSeek)
                await secondPlayer.shutdown()
                let closed = await secondEngine.diagnostics()
                XCTAssertFalse(closed.coreAlive)
                XCTAssertFalse(closed.renderContextAlive)
                XCTAssertEqual(closed.graphicsContextAlive, false)
            } catch {
                await secondPlayer.shutdown()
                throw error
            }
        } catch {
            await firstPlayer.shutdown()
            throw error
        }
    }

    private func hasSettledPosition(_ player: PlayerModel, seconds: Double) -> Bool {
        guard let snapshot = player.state.snapshot else { return false }
        return !snapshot.isSeeking && abs(snapshot.position - seconds) < 0.15
    }

    private func applicationHostWindow() async throws -> NSWindow {
        XCTAssertTrue(NSApplication.shared.isRunning, "Rendering tests require the Bomu application host")
        try await waitUntil { NSApplication.shared.windows.contains { $0.canBecomeMain && $0.isVisible } }
        let hostWindows = NSApplication.shared.windows.filter { $0.canBecomeMain && $0.isVisible }
        guard hostWindows.count == 1, let window = hostWindows.first else {
            throw NSError(domain: "Bomu.IntegrationWindow", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected exactly one visible application host window"])
        }
        return window
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
