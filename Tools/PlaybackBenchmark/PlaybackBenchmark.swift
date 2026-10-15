import AppKit
import Darwin
import QuartzCore

/// Runs production playback/render code in a dedicated AppKit event loop.
@MainActor
final class PlaybackBenchmark {
    func run(media: URL, syncMedia: URL, output: URL) async throws {
        var report = BenchmarkReport()
        do {
            for name in ["h264-1080p", "h265-main10-1080p", "h265-main10-4k"] {
                print("First-frame measurements: \(name)")
                fflush(nil)
                for iteration in 1...10 {
                    report.firstFrames.append(try await firstFrame(
                        media.appendingPathComponent(name + ".mp4"), name: name, iteration: iteration))
                }
            }
            print("Resource lifecycle, 100 replacements and 100 resizes")
            fflush(nil)
            try await resourceLifecycle(media: media, report: &report)
            print("60 fps synchronization fixture (muted; submission timing only)")
            fflush(nil)
            try await synchronizationFixture(syncMedia, report: &report)
            report.completed = true
        } catch {
            report.failure = String(describing: error)
            try report.save(to: output)
            throw error
        }
        try report.save(to: output)
    }

    private func firstFrame(_ url: URL, name: String, iteration: Int) async throws -> FirstFrameMeasurement {
        let engine = MPVPlaybackEngine()
        let window = makeWindow(engine)
        defer { window.contentView = nil; window.close() }
        do {
            try await engine.prepare()
            engine.setVolume(0)
            let before = await engine.diagnostics()
            try require(before.firstVideoFrameUptime == nil, "Idle draws must not count as media frames")
            try await waitUntil("first-frame window visible") { window.occlusionState.contains(.visible) }
            let started = CACurrentMediaTime()
            let powerBeforeOpen = try ProcessSample.read(window: window)
            engine.open(PlaybackRequest(id: 1, url: url))
            let first = try await waitForDiagnostics(engine) { $0.firstVideoFrameUptime != nil }
            let powerAfterFirstFrame = try ProcessSample.read(window: window)
            guard let submitted = first.firstVideoFrameUptime else {
                throw BenchmarkError.failed("Missing first media-frame timestamp")
            }
            try require(submitted >= started, "First frame must follow open")
            let measurement = FirstFrameMeasurement(sample: name, iteration: iteration,
                milliseconds: (submitted - started) * 1_000,
                decoder: first.hardwareDecoder, width: first.videoWidth, height: first.videoHeight,
                taskEnergyCounterDelta: ProcessSample.counterDelta(
                    start: powerBeforeOpen.taskEnergyCounterRaw,
                    end: powerAfterFirstFrame.taskEnergyCounterRaw
                ),
                gpuUtilisationCounterDelta: ProcessSample.counterDelta(
                    start: powerBeforeOpen.gpuUtilisationCounterRaw,
                    end: powerAfterFirstFrame.gpuUtilisationCounterRaw
                ))
            await engine.shutdown()
            let closed = await engine.diagnostics()
            try require(!closed.coreAlive, "Core must be released after shutdown")
            try require(!closed.renderContextAlive, "Render context must be released after shutdown")
            try require(closed.graphicsContextAlive == false, "CGL context must be released after shutdown")
            return measurement
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    private func resourceLifecycle(media: URL, report: inout BenchmarkReport) async throws {
        let engine = MPVPlaybackEngine()
        let window = makeWindow(engine)
        var state = PlaybackState()
        engine.onEvent = { state.receive($0) }
        defer { window.contentView = nil; window.close() }
        do {
            try await engine.prepare()
            engine.setVolume(0)
            window.makeKeyAndOrderFront(nil)
            try await waitUntil("resource window visible") { window.occlusionState.contains(.visible) }
            report.activity.append(try await sampleActivity("prepared-idle", engine: engine, window: window, seconds: 3))
            let h264 = media.appendingPathComponent("h264-1080p.mp4")
            let h265 = media.appendingPathComponent("h265-main10-1080p.mp4")
            let request = PlaybackRequest(id: 1, url: h264)
            state.open(request)
            engine.open(request)
            _ = try await waitForDiagnostics(engine) { $0.videoFrameCount > 3 }
            let playing = try await sampleActivity("playing-1080p", engine: engine, window: window, seconds: 8)
            report.activity.append(playing)
            try require(playing.process.allSatisfy(\.windowVisible), "Playback was occluded; visible-load baseline is invalid")
            try require(playing.after.videoFrameCount - playing.before.videoFrameCount >= 200,
                        "Visible playback did not submit enough frames for the 30 fps sample")
            try validateTiming(playing)
            engine.setPaused(PlaybackPauseRequest(requestID: request.id, commandID: 1, isPaused: true))
            try await waitUntil("paused snapshot") { state.snapshot?.isPaused == true }
            report.activity.append(try await sampleActivity("paused", engine: engine, window: window, seconds: 3))
            engine.setPaused(PlaybackPauseRequest(requestID: request.id, commandID: 2, isPaused: false))
            window.orderOut(nil)
            try await waitUntil("playing snapshot") { state.snapshot?.isPaused == false }
            report.activity.append(try await sampleActivity("hidden-playing", engine: engine, window: window, seconds: 3))
            window.makeKeyAndOrderFront(nil)
            try await waitUntil("replacement window visible") { window.occlusionState.contains(.visible) }

            // Each replacement reaches decoded playback. This is different from 100 queued commands.
            for index in 1...100 {
                let next = PlaybackRequest(id: UInt64(index + 1), url: index.isMultiple(of: 2) ? h264 : h265)
                state.open(next)
                engine.open(next)
                try await waitUntil("replacement \(index) playing") { state.snapshot?.requestID == next.id && (state.snapshot?.position ?? 0) > 0.2 }
                if index.isMultiple(of: 10) {
                    report.switches.append(SwitchCheckpoint(completed: index,
                        process: try ProcessSample.read(window: window), playback: await engine.diagnostics()))
                }
            }

            // Keep geometry fixed during memory sampling; exercise resize separately.
            for index in 1...100 {
                window.setContentSize(NSSize(width: 900 + index % 5 * 40, height: 600 + index % 7 * 20))
                try await Task.sleep(for: .milliseconds(25))
            }
            report.completedResizes = 100

            state.stop()
            engine.stop()
            _ = try await waitForDiagnostics(engine) { $0.idle == true && $0.videoOutputConfigured == false }
            _ = try await waitForDiagnostics(engine) {
                !$0.gpuRenderTiming.supported || $0.gpuRenderTiming.pendingQueryCount == 0
            }
            try await Task.sleep(for: .milliseconds(500))
            let stopped = try await sampleActivity("stopped", engine: engine, window: window, seconds: 5)
            report.activity.append(stopped)
            try require(stopped.after.videoFrameCount == stopped.before.videoFrameCount, "Stopped videoFrameCount must remain constant")
            try require(stopped.after.snapshotCount == stopped.before.snapshotCount, "Stopped snapshotCount must remain constant")
            try require(stopped.after.drawCount == stopped.before.drawCount, "Stopped drawCount must remain constant")
            if stopped.before.gpuRenderTiming.supported {
                try require(stopped.before.gpuRenderTiming.pendingQueryCount == 0
                            && stopped.after.gpuRenderTiming.pendingQueryCount == 0,
                            "GPU render timestamp queries must settle before and during the stopped interval")
                try require(stopped.after.gpuRenderTiming.sampleCount == stopped.before.gpuRenderTiming.sampleCount
                            && stopped.after.gpuRenderTiming.intervalNanoseconds == stopped.before.gpuRenderTiming.intervalNanoseconds,
                            "Stopped GPU render intervals must remain constant")
            }
            await engine.shutdown()
            let closed = await engine.diagnostics()
            try require(!closed.coreAlive, "Core must be released after shutdown")
            try require(!closed.renderContextAlive, "Render context must be released after shutdown")
            try require(closed.graphicsContextAlive == false, "CGL context must be released after shutdown")
            report.activity.append(try await sampleActivity("shutdown", engine: engine, window: window, seconds: 3))
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    private func makeWindow(_ engine: MPVPlaybackEngine) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered,
                              defer: false, screen: NSScreen.main)
        window.title = "Bomu · 播放测试（彩条为测试素材，静音）"
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        window.contentView = engine.videoView
        window.makeKeyAndOrderFront(nil)
        return window
    }

    private func synchronizationFixture(_ url: URL, report: inout BenchmarkReport) async throws {
        let engine = MPVPlaybackEngine()
        let window = makeWindow(engine)
        window.title = "Bomu · 同步素材时序测试（白块闪光，静音）"
        defer { window.contentView = nil; window.close() }
        do {
            try await engine.prepare()
            engine.setVolume(0)
            try await waitUntil("sync fixture window visible") { window.occlusionState.contains(.visible) }
            engine.open(PlaybackRequest(id: 1, url: url))
            _ = try await waitForDiagnostics(engine) { $0.videoFrameCount > 3 }
            let activity = try await sampleActivity("sync-fixture-60fps", engine: engine, window: window, seconds: 12)
            report.activity.append(activity)
            try require(activity.process.allSatisfy(\.windowVisible), "Sync fixture was occluded")
            try require(activity.after.videoFrameCount - activity.before.videoFrameCount >= 650,
                        "Sync fixture did not sustain the expected frame submission rate")
            try validateTiming(activity)
            await engine.shutdown()
            let closed = await engine.diagnostics()
            try require(!closed.coreAlive && !closed.renderContextAlive && closed.graphicsContextAlive == false,
                        "Sync fixture resources must be released")
        } catch {
            await engine.shutdown()
            throw error
        }
    }

    private func validateTiming(_ activity: ActivityMeasurement) throws {
        try require(activity.after.videoSyncMode == "audio" && activity.after.videoTimingOffset == 0,
                    "Nonblocking rendering requires audio timing with zero advance offset")
        guard let after = activity.after.frameTiming else {
            throw BenchmarkError.failed("No target-time measurements were returned")
        }
        let beforeCount = activity.before.frameTiming?.sampleCount ?? 0
        let beforeEarly = activity.before.frameTiming?.earlyFrameCount ?? 0
        try require(after.sampleCount > beforeCount, "No new frame targets were measured")
        try require(after.earlyFrameCount == beforeEarly, "Frames were submitted more than 2 ms before their target")
        try require(after.minimumErrorMilliseconds > -1_000 && after.maximumErrorMilliseconds < 1_000,
                    "Frame target clock contract or rendering deadline is invalid")
        let gpuBefore = activity.before.gpuRenderTiming
        let gpuAfter = activity.after.gpuRenderTiming
        if gpuAfter.supported {
            try require(gpuAfter.sampleCount > gpuBefore.sampleCount,
                        "GPU timestamp queries returned no completed OpenGL render intervals")
            try require(gpuAfter.intervalNanoseconds > gpuBefore.intervalNanoseconds,
                        "OpenGL render interval did not advance during active playback")
        }
    }

    private func sampleActivity(_ name: String, engine: MPVPlaybackEngine,
                                window: NSWindow, seconds: Double) async throws -> ActivityMeasurement {
        let before = await engine.diagnostics()
        var process = [try ProcessSample.read(window: window)]
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            process.append(try ProcessSample.read(window: window))
        }
        return ActivityMeasurement(phase: name, process: process, before: before, after: await engine.diagnostics())
    }

    private func waitForDiagnostics(_ engine: MPVPlaybackEngine,
                                    matching predicate: (PlaybackDiagnostics) -> Bool) async throws -> PlaybackDiagnostics {
        let deadline = CACurrentMediaTime() + 10
        while CACurrentMediaTime() < deadline {
            let value = await engine.diagnostics()
            if predicate(value) { return value }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw BenchmarkError.failed("Timed out waiting for playback diagnostics")
    }

    private func waitUntil(_ description: String, _ predicate: () -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 10
        while !predicate() {
            if CACurrentMediaTime() >= deadline { throw BenchmarkError.failed("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw BenchmarkError.failed(message) }
    }
}
