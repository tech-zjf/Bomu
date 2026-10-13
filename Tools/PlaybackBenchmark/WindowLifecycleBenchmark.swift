import AppKit
import QuartzCore
import SwiftUI

/// Exercises the actual feature UI without adding a test entry point to Bomu.
@MainActor
final class WindowLifecycleBenchmark: NSObject, NSWindowDelegate {
    private var enteredFullScreen = 0
    private var exitedFullScreen = 0
    private var transitionFailure: String?
    private weak var observedWindow: NSWindow?
    private var observationStarted: Double = 0
    private var soakVisibility: WindowVisibilityMeasurement?

    func run(media: URL, output: URL, scenario: WindowScenario,
             cycles: Int, soakSeconds: Double) async throws {
        let screens = NSScreen.screens
        var report = WindowLifecycleReport(scenario: scenario,
            requestedCycles: cycles, requestedSoakSeconds: soakSeconds,
            screens: try screens.map(DisplayMeasurement.init))
        let engine = MPVPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false, screen: NSScreen.main)
        switch scenario {
        case .singleWindow: window.title = "Bomu · 单窗口播放测试（静音）"
        case .displayTransitions: window.title = "Bomu · 窗口组合测试（自动全屏 / 跨屏，静音）"
        }
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.delegate = self
        window.contentView = NSHostingView(rootView: PlayerScreen(player: player, videoView: engine.videoView))
        defer { window.delegate = nil; window.contentView = nil; window.close() }
        let started = CACurrentMediaTime()
        do {
            if scenario == .displayTransitions {
                try require(screens.count >= 2, "Window migration acceptance requires at least two connected displays")
            }
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate()
            print("Window test ready: active=\(NSApplication.shared.isActive), key=\(window.isKeyWindow), visible=\(window.occlusionState.contains(.visible)), activeSpace=\(window.isOnActiveSpace)")
            fflush(nil)
            try await waitUntil("visible test window") {
                window.occlusionState.contains(.visible) && window.isOnActiveSpace
            }
            try await Task.sleep(for: .seconds(1))
            player.prepare()
            try await waitUntil("player prepared") { player.isPrepared || player.startupError != nil }
            try require(player.startupError == nil, "Player initialization failed: \(player.startupError ?? "")")
            player.setVolume(0)
            player.open(media)
            try await waitUntil("first frame in production UI") {
                player.canControlPlayback && (player.state.snapshot?.position ?? 0) > 0.2
            }
            try require((player.state.snapshot?.duration ?? 0) >= 600, "Window stress needs a continuous long sample")
            for cycle in 1...cycles {
                var migratedDisplayID: UInt32?
                if scenario == .displayTransitions {
                    migratedDisplayID = try await migrate(window, cycle: cycle, screens: screens)
                }

                // Pausing through the production model pins and redraws the real SwiftUI controls.
                // Native acknowledgement is required; optimistic UI state alone cannot pass.
                player.togglePause()
                try await waitUntil("cycle \(cycle) pause") { player.state.snapshot?.isPaused == true }
                guard let pauseID = player.state.snapshot?.pauseCommandID else {
                    throw BenchmarkError.failed("Paused snapshot disappeared")
                }
                try await Task.sleep(for: .milliseconds(100))
                var enterTime: Double?
                if scenario == .displayTransitions {
                    enterTime = try await transition(window, fullScreen: true)
                }
                player.togglePause()
                try await waitUntil("cycle \(cycle) resume") {
                    player.state.snapshot?.isPaused == false && (player.state.snapshot?.pauseCommandID ?? 0) > pauseID
                }
                guard let resumeID = player.state.snapshot?.pauseCommandID else {
                    throw BenchmarkError.failed("Resumed snapshot disappeared")
                }
                var exitTime: Double?
                if scenario == .displayTransitions {
                    exitTime = try await transition(window, fullScreen: false)
                }
                let frameCount = (await engine.diagnostics()).videoFrameCount
                try await waitUntil("cycle \(cycle) backing scale") {
                    engine.videoView.layer?.contentsScale == window.backingScaleFactor
                }
                try await waitForNewFrame(engine, after: frameCount)
                let checkpoint = try await WindowCheckpoint.read(window: window, engine: engine,
                    player: player, started: started)
                if let migratedDisplayID {
                    try require(checkpoint.displayID == migratedDisplayID, "Fullscreen returned to a different display")
                }
                try require(checkpoint.process.windowVisible, "The stress window is occluded")
                report.rounds.append(WindowRound(cycle: cycle, enterFullScreenMilliseconds: enterTime,
                    exitFullScreenMilliseconds: exitTime, pauseCommandID: pauseID,
                    resumeCommandID: resumeID, checkpoint: checkpoint))
                try report.save(to: output)
                if cycle.isMultiple(of: 10) || cycle == cycles {
                    print("Window cycles completed: \(cycle)/\(cycles)")
                    fflush(nil)
                }
            }
            print("Uninterrupted production-UI playback: \(soakSeconds) seconds")
            fflush(nil)
            try await soak(window: window, engine: engine, player: player,
                started: started, seconds: soakSeconds, output: output, report: &report)
            player.stop()
            try await waitUntilIdle(engine)
            try await Task.sleep(for: .milliseconds(500))
            let before = await engine.diagnostics()
            let processBefore = try ProcessSample.read(window: window)
            try await Task.sleep(for: .seconds(5))
            let after = await engine.diagnostics()
            report.stopped = ActivityMeasurement(phase: "production-ui-stopped",
                process: [processBefore, try ProcessSample.read(window: window)], before: before, after: after)
            try require(before.videoFrameCount == after.videoFrameCount && before.drawCount == after.drawCount
                && before.snapshotCount == after.snapshotCount, "Stopped playback continued rendering or sampling")
            await player.shutdown()
            report.shutdown = await engine.diagnostics()
            try require(report.shutdown?.coreAlive == false && report.shutdown?.renderContextAlive == false,
                "Window benchmark resources were not released")
            report.completed = true
        } catch {
            await player.shutdown()
            report.shutdown = await engine.diagnostics()
            report.failure = String(describing: error)
            try report.save(to: output)
            throw error
        }
        try report.save(to: output)
    }

    func windowDidEnterFullScreen(_ notification: Notification) { enteredFullScreen += 1 }
    func windowDidExitFullScreen(_ notification: Notification) { exitedFullScreen += 1 }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === observedWindow else { return }
        soakVisibility?.record(isVisible: window.occlusionState.contains(.visible),
            elapsedSeconds: CACurrentMediaTime() - observationStarted)
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { transitionFailure = "Failed to enter fullscreen" }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { transitionFailure = "Failed to exit fullscreen" }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return false
    }

    private func migrate(_ window: NSWindow, cycle: Int, screens: [NSScreen]) async throws -> UInt32 {
        let screen = screens[cycle % screens.count]
        let displayID = try DisplayMeasurement.id(of: screen)
        let size = NSSize(width: 900 + cycle % 5 * 40, height: 600 + cycle % 3 * 30)
        let rect = NSRect(x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2, width: size.width, height: size.height)
        window.setFrame(window.frameRect(forContentRect: rect), display: true)
        try await waitUntil("cycle \(cycle) display migration") {
            guard let current = window.screen else { return false }
            return try DisplayMeasurement.id(of: current) == displayID
        }
        return displayID
    }

    private func transition(_ window: NSWindow, fullScreen: Bool) async throws -> Double {
        let count = fullScreen ? enteredFullScreen : exitedFullScreen
        let start = CACurrentMediaTime()
        print("Fullscreen \(fullScreen ? "enter" : "exit"): active=\(NSApplication.shared.isActive), key=\(window.isKeyWindow), visible=\(window.occlusionState.contains(.visible)), activeSpace=\(window.isOnActiveSpace)")
        fflush(nil)
        window.toggleFullScreen(nil)
        try await waitUntil(fullScreen ? "native fullscreen entry" : "native fullscreen exit") {
            (fullScreen ? self.enteredFullScreen : self.exitedFullScreen) > count
        }
        try require(window.styleMask.contains(.fullScreen) == fullScreen, "Fullscreen acknowledgement disagrees with window state")
        return (CACurrentMediaTime() - start) * 1_000
    }

    private func soak(window: NSWindow, engine: MPVPlaybackEngine, player: PlayerModel,
                      started: Double, seconds: Double, output: URL,
                      report: inout WindowLifecycleReport) async throws {
        observationStarted = started
        observedWindow = window
        soakVisibility = WindowVisibilityMeasurement(isVisible: window.occlusionState.contains(.visible),
            elapsedSeconds: CACurrentMediaTime() - started)
        defer {
            soakVisibility?.finish(isVisible: window.occlusionState.contains(.visible),
                elapsedSeconds: CACurrentMediaTime() - started)
            report.soakVisibility = soakVisibility
            observedWindow = nil
        }
        report.soak.append(try await WindowCheckpoint.read(window: window, engine: engine, player: player, started: started))
        try require(soakVisibility?.wasInterrupted == false, "Continuous playback started occluded")
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .seconds(min(10, max(0, deadline - CACurrentMediaTime()))))
            guard let previous = report.soak.last else {
                throw BenchmarkError.failed("Missing initial soak checkpoint")
            }
            let checkpoint = try await WindowCheckpoint.read(window: window, engine: engine, player: player, started: started)
            soakVisibility?.record(isVisible: checkpoint.process.windowVisible,
                elapsedSeconds: checkpoint.elapsedSeconds)
            report.soakVisibility = soakVisibility
            try require(soakVisibility?.wasInterrupted == false, "Continuous playback was interrupted by occlusion")
            let elapsed = checkpoint.process.uptime - previous.process.uptime
            try require(checkpoint.positionSeconds - previous.positionSeconds > elapsed * 0.8,
                "Playback position stopped advancing")
            let frames = checkpoint.playback.videoFrameCount - previous.playback.videoFrameCount
            try require(Double(frames) >= elapsed * 25, "Uninterrupted 30 fps playback fell below 25 submitted frames/s")
            report.soak.append(checkpoint)
            try report.save(to: output)
        }
        soakVisibility?.record(isVisible: window.occlusionState.contains(.visible),
            elapsedSeconds: CACurrentMediaTime() - started)
        try require(soakVisibility?.wasInterrupted == false, "Continuous playback ended with occlusion")
    }

    private func waitUntil(_ description: String, timeout: Double = 15,
                           _ predicate: () throws -> Bool) async throws {
        let deadline = CACurrentMediaTime() + timeout
        while try !predicate() {
            if let transitionFailure { throw BenchmarkError.failed(transitionFailure) }
            if CACurrentMediaTime() >= deadline { throw BenchmarkError.failed("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
    }

    private func waitForNewFrame(_ engine: MPVPlaybackEngine, after count: UInt64) async throws {
        let deadline = CACurrentMediaTime() + 5
        while (await engine.diagnostics()).videoFrameCount <= count {
            if CACurrentMediaTime() >= deadline { throw BenchmarkError.failed("No new video frame after playback resumed") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func waitUntilIdle(_ engine: MPVPlaybackEngine) async throws {
        let deadline = CACurrentMediaTime() + 5
        while true {
            let value = await engine.diagnostics()
            if value.idle == true && value.videoOutputConfigured == false { return }
            if CACurrentMediaTime() >= deadline { throw BenchmarkError.failed("Stop did not reach native idle") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw BenchmarkError.failed(message) }
    }
}
