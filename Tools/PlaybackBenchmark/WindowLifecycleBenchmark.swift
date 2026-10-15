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
    private var visibilityObservation: WindowVisibilityMeasurement?
    private var visibilityNotificationCount = 0
    private var sleepNotificationCount = 0
    private var wakeNotificationCount = 0
    private var sleepObservers: [NSObjectProtocol] = []

    func run(media: URL, output: URL, scenario: WindowScenario,
             cycles: Int, soakSeconds: Double, suiteDirectory: URL? = nil,
             previewSeconds: Double = 0, initialDisplayID: UInt32? = nil,
             replacementMedia: URL? = nil, activationGraceSeconds: Double = 0,
             minimizeRestoreProbe: Bool = true, syncMedia: URL? = nil) async throws {
        let manifest = try suiteDirectory.map { try MediaSuiteManifest.read(from: $0) }
        if scenario == .b11Suite {
            guard manifest?.suite == "bomu-b11", syncMedia?.isFileURL == true, soakSeconds >= 1_800,
                  cycles == 100 else {
                throw BenchmarkError.failed("B11 requires its 60-case suite, synchronization fixture, 100 file switches and a 1,800-second soak")
            }
            let workspaceNotifications = NSWorkspace.shared.notificationCenter
            sleepObservers = [
                workspaceNotifications.addObserver(forName: NSWorkspace.willSleepNotification,
                    object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.sleepNotificationCount += 1 }
                    },
                workspaceNotifications.addObserver(forName: NSWorkspace.didWakeNotification,
                    object: nil, queue: .main) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.wakeNotificationCount += 1 }
                    },
            ]
        }
        let expectedOpenCount = UInt64((manifest?.samples.count ?? 0)
            + (scenario == .b11Suite ? cycles : 0) + 1)
        let screens = NSScreen.screens
        let selectedScreen: NSScreen?
        if let initialDisplayID {
            selectedScreen = try screens.first { try DisplayMeasurement.id(of: $0) == initialDisplayID }
        } else {
            selectedScreen = NSScreen.main
        }
        guard let selectedScreen else { throw BenchmarkError.failed("Initial display is unavailable") }
        let selectedDisplayID = try DisplayMeasurement.id(of: selectedScreen)
        var report = WindowLifecycleReport(scenario: scenario,
            requestedCycles: cycles, requestedSoakSeconds: soakSeconds,
            screens: try screens.map(DisplayMeasurement.init), requestedMediaPreviewSeconds: previewSeconds,
            requestedInitialDisplayID: initialDisplayID)
        let engine = MPVPlaybackEngine()
        let player = PlayerModel(engine: engine)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
            defer: false, screen: selectedScreen)
        switch scenario {
        case .singleWindow: window.title = "Bomu · 单窗口播放测试（静音）"
        case .mediaSuite: window.title = "Bomu · 30 个素材测试（单窗口，静音）"
        case .b11Suite: window.title = "Bomu · B11 回归（60 个素材，单窗口）"
        case .replacementBurst: window.title = "Bomu · 快速替换 / 取消测试（单窗口，静音）"
        case .displayTransitions: window.title = "Bomu · 窗口组合测试（自动全屏 / 跨屏，静音）"
        }
        window.isReleasedWhenClosed = false
        // Keep this one development window visible while the user works elsewhere.
        // Set its level once; never reactivate it in response to lost focus/occlusion.
        // The shipping player's window policy is unchanged.
        if scenario != .displayTransitions { window.level = .floating }
        window.collectionBehavior = [.fullScreenPrimary]
        if scenario == .displayTransitions { window.collectionBehavior.insert(.moveToActiveSpace) }
        window.delegate = self
        window.contentView = NSHostingView(rootView: PlayerScreen(player: player,
            videoView: engine.videoView, nowPlaying: NowPlayingController(player: player),
            onReturnToLibrary: { player.stop() }))
        recordWindowLocation(window, event: "created")
        defer {
            for observer in sleepObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
            sleepObservers.removeAll()
            window.delegate = nil
            window.contentView = nil
            window.close()
        }
        let started = CACurrentMediaTime()
        do {
            if scenario == .displayTransitions {
                try require(screens.count >= 2, "Window migration acceptance requires at least two connected displays")
            }
            if initialDisplayID != nil {
                let frame = window.frame
                let visibleFrame = selectedScreen.visibleFrame
                window.setFrameOrigin(NSPoint(x: visibleFrame.midX - frame.width / 2,
                    y: visibleFrame.midY - frame.height / 2))
            } else {
                window.center()
            }
            NSApplication.shared.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            recordWindowLocation(window, event: "orderedFront")
            print("Window test ready: active=\(NSApplication.shared.isActive), key=\(window.isKeyWindow), visible=\(window.occlusionState.contains(.visible)), activeSpace=\(window.isOnActiveSpace)")
            fflush(nil)
            // Desktop launch/activation may require a user or accessibility action.
            // Allow that startup handoff without weakening any playback deadline.
            do {
                try await waitUntil("active visible test window", timeout: 15) {
                    NSApplication.shared.isActive && window.isKeyWindow
                        && window.occlusionState.contains(.visible) && window.isOnActiveSpace
                }
            } catch {
                let screenID = try window.screen.map(DisplayMeasurement.id(of:))
                throw BenchmarkError.failed(
                    "Test window did not activate (appActive=\(NSApplication.shared.isActive), key=\(window.isKeyWindow), " +
                    "visible=\(window.occlusionState.contains(.visible)), activeSpace=\(window.isOnActiveSpace), " +
                    "screenID=\(screenID.map { String($0) } ?? "nil"), frame=\(NSStringFromRect(window.frame))): \(error)"
                )
            }
            if activationGraceSeconds > 0 {
                print("Visible test window ready for desktop handoff: \(activationGraceSeconds) seconds")
                fflush(nil)
                try await Task.sleep(for: .seconds(activationGraceSeconds))
                try require(window.occlusionState.contains(.visible) && window.isOnActiveSpace,
                    "Test window became occluded during the desktop handoff")
            }
            try await Task.sleep(for: .seconds(1))
            guard let activeScreen = window.screen,
                  try DisplayMeasurement.id(of: activeScreen) == selectedDisplayID else {
                throw BenchmarkError.failed("Window moved away from its initial display during startup")
            }
            player.prepare()
            try await waitUntil("player prepared") { player.isPrepared || player.startupError != nil }
            try require(player.startupError == nil, "Player initialization failed: \(player.startupError ?? "")")
            player.setVolume(0)
            if scenario == .replacementBurst {
                guard let replacementMedia else {
                    throw BenchmarkError.failed("Replacement-burst scenario requires MPEG-TS media")
                }
                try await runReplacementBurst(initialMedia: media, replacementMedia: replacementMedia,
                    window: window, engine: engine, player: player, output: output, report: &report)
                player.stop()
                try await waitUntilIdle(engine)
                await player.shutdown()
                report.shutdown = await engine.diagnostics()
                try require(report.shutdown?.coreAlive == false && report.shutdown?.renderContextAlive == false
                    && report.shutdown?.graphicsContextAlive == false,
                            "Replacement-burst resources were not released")
                report.completed = true
                try report.save(to: output)
                return
            }
            if let manifest, let suiteDirectory {
                try await checkMedia(manifest, directory: suiteDirectory, window: window,
                    engine: engine, player: player, started: started, previewSeconds: previewSeconds,
                    output: output, report: &report)
            }
            if scenario == .b11Suite, let manifest, let suiteDirectory {
                try await runFileSwitches(manifest.samples, directory: suiteDirectory,
                    window: window, engine: engine, player: player, started: started,
                    count: cycles, output: output, report: &report)
            }
            let soakMedia = scenario == .b11Suite ? (syncMedia ?? media) : media
            window.title = "Bomu · 暂停 / 恢复测试（单窗口，静音）"
            player.open(soakMedia)
            try await waitUntil("first frame in production UI") {
                player.canControlPlayback && (player.state.snapshot?.position ?? 0) > 0.2
            }
            if scenario == .b11Suite {
                try require((player.state.snapshot?.duration ?? 0) >= soakSeconds - 2,
                    "B11 synchronization fixture is shorter than the requested soak")
            } else {
                try require((player.state.snapshot?.duration ?? 0) >= 600, "Window stress needs a continuous long sample")
            }
            guard let initialScreen = window.screen else { throw BenchmarkError.failed("Missing initial display") }
            let initialDisplayID = try DisplayMeasurement.id(of: initialScreen)
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
                    player: player, started: started, expectedOpenCount: expectedOpenCount)
                if let migratedDisplayID {
                    try require(checkpoint.displayID == migratedDisplayID, "Fullscreen returned to a different display")
                } else {
                    try require(checkpoint.displayID == initialDisplayID, "Single-window test changed displays")
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
            window.title = "Bomu · 最小化 / 恢复检查（只操作当前窗口）"
            if minimizeRestoreProbe {
                try await probeOcclusion(window: window, engine: engine, started: started, report: &report)
            } else {
                report.minimizeRestoreProbeSkippedReason =
                    "Skipped to keep this acceptance on its selected display; minimize/restore requires a separate visible interaction."
            }
            try report.save(to: output)
            window.title = scenario == .b11Suite
                ? "Bomu · 音画同步持续测试（\(Int(soakSeconds / 60)) 分钟，自动静音）"
                : "Bomu · 持续播放测试（\(Int(soakSeconds)) 秒，静音）"
            print("Uninterrupted production-UI playback: \(soakSeconds) seconds")
            fflush(nil)
            try await soak(window: window, engine: engine, player: player,
                started: started, seconds: soakSeconds, expectedOpenCount: expectedOpenCount,
                output: output, report: &report)
            if scenario == .b11Suite {
                report.systemSleepWake = SystemSleepWakeMeasurement(
                    sleepNotifications: sleepNotificationCount, wakeNotifications: wakeNotificationCount,
                    recoveryEvidence: sleepNotificationCount > 0 && wakeNotificationCount > 0
                        ? "A real system sleep/wake occurred during playback; the subsequent continuous-playback checkpoints are the recovery evidence."
                        : "No real system sleep/wake occurred during this run; sleep recovery remains unverified.")
            }
            player.stop()
            try await waitUntilIdle(engine)
            try await waitForGPURenderQueriesToSettle(engine)
            try await Task.sleep(for: .milliseconds(500))
            let before = await engine.diagnostics()
            let processBefore = try ProcessSample.read(window: window)
            try await Task.sleep(for: .seconds(5))
            let after = await engine.diagnostics()
            report.stopped = ActivityMeasurement(phase: "production-ui-stopped",
                process: [processBefore, try ProcessSample.read(window: window)], before: before, after: after)
            try require(before.videoFrameCount == after.videoFrameCount && before.drawCount == after.drawCount
                && before.snapshotCount == after.snapshotCount, "Stopped playback continued rendering or sampling")
            if before.gpuRenderTiming.supported {
                try require(before.gpuRenderTiming.pendingQueryCount == 0
                            && after.gpuRenderTiming.pendingQueryCount == 0,
                            "GPU render timestamp queries must settle before and during the stopped interval")
                try require(after.gpuRenderTiming.sampleCount == before.gpuRenderTiming.sampleCount
                            && after.gpuRenderTiming.intervalNanoseconds == before.gpuRenderTiming.intervalNanoseconds,
                            "Stopped GPU render intervals must remain constant")
            }
            await player.shutdown()
            report.shutdown = await engine.diagnostics()
            try require(report.shutdown?.coreAlive == false && report.shutdown?.renderContextAlive == false
                && report.shutdown?.graphicsContextAlive == false,
                "Window benchmark resources were not released")
            let failedSamples = report.mediaSamples.filter { !$0.passed }.map { $0.sample.file }
            try require(failedSamples.isEmpty, "Media cases failed: \(failedSamples.joined(separator: ", "))")
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

    private func runFileSwitches(_ samples: [MediaSuiteManifest.Sample], directory: URL,
                                 window: NSWindow, engine: MPVPlaybackEngine, player: PlayerModel,
                                 started: Double, count: Int, output: URL,
                                 report: inout WindowLifecycleReport) async throws {
        guard samples.count == 60, samples.allSatisfy({
            $0.expected.outcome == .play && $0.expected.video != nil && $0.expected.audio != nil
        }) else { throw BenchmarkError.failed("B11 switch matrix must contain 60 audiovisual samples") }
        for index in 0..<count {
            let sample = samples[index % samples.count]
            let before = await engine.diagnostics()
            let began = CACurrentMediaTime()
            let file = directory.appendingPathComponent(sample.file)
            player.open(file)
            guard let requestID = player.state.request?.id else {
                throw BenchmarkError.failed("File switch did not create a playback request")
            }
            try await waitUntil("file switch \(index + 1) ready") {
                guard player.state.request?.id == requestID,
                      let snapshot = player.state.snapshot else { return false }
                if case .failed(let message) = player.state.phase {
                    throw BenchmarkError.failed("File switch failed for \(sample.file): \(message)")
                }
                return player.canControlPlayback && snapshot.position > 0.15
            }
            let after = await engine.diagnostics()
            guard let video = sample.expected.video, let audio = sample.expected.audio,
                  after.coreAlive, after.renderContextAlive,
                  after.coreCreationCount == 1, after.renderContextCreationCount == 1,
                  after.openCount == before.openCount + 1,
                  after.videoOutputConfigured == true,
                  after.videoWidth == video.width, after.videoHeight == video.height,
                  after.videoFrameCount > before.videoFrameCount,
                  after.audioSampleRate == audio.sampleRate,
                  after.audioChannelCount == audio.channels,
                  let outputRate = after.audioOutputSampleRate, outputRate > 0,
                  engine.videoView.window === window, window.occlusionState.contains(.visible) else {
                throw BenchmarkError.failed("File switch did not produce expected audio/video output: \(sample.file)")
            }
            report.fileSwitches.append(FileSwitchMeasurement(index: index + 1, file: sample.file,
                requestID: requestID, elapsedSeconds: CACurrentMediaTime() - began, diagnostics: after))
            if (index + 1).isMultiple(of: 10) || index + 1 == count {
                try report.save(to: output)
                print("B11 file switches: \(index + 1)/\(count)")
                fflush(nil)
            }
        }
    }

    private func runReplacementBurst(initialMedia: URL, replacementMedia: URL, window: NSWindow,
                                     engine: MPVPlaybackEngine, player: PlayerModel, output: URL,
                                     report: inout WindowLifecycleReport) async throws {
        window.title = "Bomu · 取消排队中的打开请求（静音）"
        player.open(initialMedia)
        try await waitUntil("initial playback") { player.canControlPlayback }
        var cancelledIDs: [UInt64] = []
        for _ in 0..<12 {
            player.open(replacementMedia)
            if let id = player.state.request?.id { cancelledIDs.append(id) }
        }
        player.stop()
        try await waitUntilIdle(engine)
        let stopped = await engine.diagnostics()
        try require(stopped.idle == true && stopped.videoOutputConfigured == false,
                    "Stop did not cancel pending replacement playback")
        try await Task.sleep(for: .milliseconds(500))
        try require(player.state.phase == .idle && player.state.request == nil,
                    "A stale callback restored a request after stop")

        var replacementIDs: [UInt64] = []
        for index in 0..<24 {
            player.open(index.isMultiple(of: 2) ? initialMedia : replacementMedia)
            if let id = player.state.request?.id { replacementIDs.append(id) }
        }
        guard let finalRequestID = player.state.request?.id else {
            throw BenchmarkError.failed("Final replacement request is missing")
        }
        var measurement = ReplacementBurstMeasurement(cancelledRequestIDs: cancelledIDs,
            replacementRequestIDs: replacementIDs, finalRequestID: finalRequestID,
            stoppedBeforeReplacement: true, before: stopped)
        report.replacementBurst = measurement
        try report.save(to: output)
        window.title = "Bomu · 验证最终 TS 请求与定位恢复（静音）"
        try await waitUntil("final replacement playing") {
            guard player.state.request?.id == finalRequestID,
                  let snapshot = player.state.snapshot else { return false }
            return snapshot.requestID == finalRequestID && !snapshot.isPaused && snapshot.position > 0.5
        }
        let playing = await engine.diagnostics()
        try require(playing.coreCreationCount == 1 && playing.renderContextCreationCount == 1,
                    "Rapid replacements recreated native resources")
        try require(engine.videoView.window === window && window.occlusionState.contains(.visible),
                    "Rapid replacement left the single test window")
        measurement.finalRequestPlayed = true
        measurement.playing = playing
        try await Task.sleep(for: .seconds(1))
        try require(player.state.request?.id == finalRequestID
            && player.state.snapshot?.requestID == finalRequestID
            && player.state.phase == .ready,
            "A stale open or callback replaced the final request after the burst")
        guard let duration = player.state.snapshot?.duration, duration > 1 else {
            throw BenchmarkError.failed("Final TS duration is unavailable")
        }
        player.togglePause()
        try await waitUntil("final TS paused") { player.state.snapshot?.isPaused == true }
        player.seek(to: duration * 0.6)
        try await waitUntil("final TS seek recovery") {
            guard let snapshot = player.state.snapshot else { return false }
            return snapshot.requestID == finalRequestID && snapshot.isPaused && !snapshot.isSeeking
                && abs(snapshot.position - duration * 0.6) < 0.2
        }
        measurement.seekRecovered = true
        measurement.afterSeek = await engine.diagnostics()
        report.replacementBurst = measurement
        try report.save(to: output)
        player.togglePause()
        try await waitUntil("final TS after resumed seek") {
            player.state.snapshot?.requestID == finalRequestID
                && player.state.snapshot?.isPaused == false
                && (player.state.snapshot?.position ?? 0) > duration * 0.6
        }
        try await waitForNewFrame(engine, after: measurement.afterSeek?.videoFrameCount ?? 0)
        try require(player.state.request?.id == finalRequestID && player.state.phase == .ready,
                    "Resuming the final TS request changed its authoritative identity")
    }

    func windowDidEnterFullScreen(_ notification: Notification) { enteredFullScreen += 1 }
    func windowDidExitFullScreen(_ notification: Notification) { exitedFullScreen += 1 }
    func windowDidMove(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        recordWindowLocation(window, event: "moved")
    }
    func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        recordWindowLocation(window, event: "changedScreen")
    }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === observedWindow else { return }
        visibilityNotificationCount += 1
        visibilityObservation?.record(isVisible: window.occlusionState.contains(.visible),
            elapsedSeconds: CACurrentMediaTime() - observationStarted)
    }
    func windowDidFailToEnterFullScreen(_ window: NSWindow) { transitionFailure = "Failed to enter fullscreen" }
    func windowDidFailToExitFullScreen(_ window: NSWindow) { transitionFailure = "Failed to exit fullscreen" }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        NSApplication.shared.terminate(nil)
        return false
    }

    private func recordWindowLocation(_ window: NSWindow, event: String) {
        print("Window location: event=\(event), uptime=\(CACurrentMediaTime()), number=\(window.windowNumber), frame=\(NSStringFromRect(window.frame)), screen=\(window.screen?.localizedName ?? "unknown"), active=\(NSApplication.shared.isActive), visible=\(window.occlusionState.contains(.visible))")
        fflush(nil)
    }

    private func checkMedia(_ manifest: MediaSuiteManifest, directory: URL, window: NSWindow,
                            engine: MPVPlaybackEngine, player: PlayerModel, started: Double,
                            previewSeconds: Double, output: URL, report: inout WindowLifecycleReport) async throws {
        beginVisibilityObservation(window, started: started)
        defer { report.mediaVisibility = finishVisibilityObservation(window) }
        for (index, sample) in manifest.samples.enumerated() {
            window.title = "Bomu · 素材 \(index + 1)/\(manifest.samples.count) · \(sample.file)（静音）"
            let result = try await MediaSuiteBenchmark.measure(sample, directory: directory,
                window: window, player: player, engine: engine, started: started)
            report.mediaSamples.append(result)
            report.mediaVisibility = visibilityObservation
            try report.save(to: output)
            // Cases are independent. Preserve a failed result and still exercise
            // the next file's recovery path; the overall run fails after teardown.
            try require(visibilityObservation?.wasInterrupted == false, "Media suite window was occluded")
            try require(result.displayID == report.mediaSamples.first?.displayID,
                "Media suite changed displays")
            print("Media suite \(result.passed ? "passed" : "FAILED"): \(index + 1)/\(manifest.samples.count) \(sample.file)")
            fflush(nil)
            // Optional time for actual visual inspection, applied uniformly to every case.
            // The file keeps playing; this interval is not part of the timed assertions.
            if previewSeconds > 0 { try await Task.sleep(for: .seconds(previewSeconds)) }
            try require(visibilityObservation?.wasInterrupted == false, "Media preview window was occluded")
        }
    }

    private func probeOcclusion(window: NSWindow, engine: MPVPlaybackEngine, started: Double,
                                report: inout WindowLifecycleReport) async throws {
        var probe = WindowOcclusionProbe()
        beginVisibilityObservation(window, started: started)
        defer {
            probe.visibility = finishVisibilityObservation(window)
            probe.notificationCount = visibilityNotificationCount
            report.occlusionProbe = probe
        }
        try require(window.occlusionState.contains(.visible), "Occlusion probe must start visible")
        probe.before = await engine.diagnostics()
        window.miniaturize(nil)
        // Only delegate notifications update this observation during the probe.
        // Polling is deliberately not allowed to stand in for the native callback.
        try await waitUntil("hidden-window delegate notification") {
            window.isMiniaturized && self.visibilityObservation?.changes.last?.isVisible == false
        }
        try await Task.sleep(for: .milliseconds(500))
        let hidden = await engine.diagnostics()
        probe.hidden = hidden
        window.deminiaturize(nil)
        try await waitUntil("restored-window delegate notification") {
            !window.isMiniaturized && self.visibilityObservation?.changes.last?.isVisible == true
                && self.visibilityNotificationCount >= 2
        }
        try await waitForNewFrame(engine, after: hidden.videoFrameCount)
        probe.restored = await engine.diagnostics()
        try require(visibilityObservation?.wasInterrupted == true,
            "Minimization was not retained as a visibility interruption")
        probe.completed = true
    }

    private func beginVisibilityObservation(_ window: NSWindow, started: Double) {
        observationStarted = started
        observedWindow = window
        visibilityNotificationCount = 0
        visibilityObservation = WindowVisibilityMeasurement(isVisible: window.occlusionState.contains(.visible),
            elapsedSeconds: CACurrentMediaTime() - started)
    }

    private func finishVisibilityObservation(_ window: NSWindow) -> WindowVisibilityMeasurement? {
        visibilityObservation?.finish(isVisible: window.occlusionState.contains(.visible),
            elapsedSeconds: CACurrentMediaTime() - observationStarted)
        observedWindow = nil
        return visibilityObservation
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
                      started: Double, seconds: Double, expectedOpenCount: UInt64, output: URL,
                      report: inout WindowLifecycleReport) async throws {
        beginVisibilityObservation(window, started: started)
        defer { report.soakVisibility = finishVisibilityObservation(window) }
        report.soak.append(try await WindowCheckpoint.read(window: window, engine: engine, player: player,
            started: started, expectedOpenCount: expectedOpenCount))
        try require(visibilityObservation?.wasInterrupted == false, "Continuous playback started occluded")
        let deadline = CACurrentMediaTime() + seconds
        while CACurrentMediaTime() < deadline {
            try await Task.sleep(for: .seconds(min(10, max(0, deadline - CACurrentMediaTime()))))
            guard let previous = report.soak.last else {
                throw BenchmarkError.failed("Missing initial soak checkpoint")
            }
            let checkpoint = try await WindowCheckpoint.read(window: window, engine: engine, player: player,
                started: started, expectedOpenCount: expectedOpenCount)
            visibilityObservation?.record(isVisible: checkpoint.process.windowVisible,
                elapsedSeconds: checkpoint.elapsedSeconds)
            report.soak.append(checkpoint)
            report.soakVisibility = visibilityObservation
            try report.save(to: output)
            try require(visibilityObservation?.wasInterrupted == false, "Continuous playback was interrupted by occlusion")
            try require(checkpoint.displayID == previous.displayID, "Continuous playback changed displays")
            let elapsed = checkpoint.process.uptime - previous.process.uptime
            try require(checkpoint.positionSeconds - previous.positionSeconds > elapsed * 0.8,
                "Playback position stopped advancing")
            let frames = checkpoint.playback.videoFrameCount - previous.playback.videoFrameCount
            let submittedFramesPerSecond = elapsed > 0 ? Double(frames) / elapsed : 0
            try require(submittedFramesPerSecond >= 25,
                String(format: "Uninterrupted 30 fps playback fell to %.2f submitted frames/s over %.2f seconds",
                    submittedFramesPerSecond, elapsed))
        }
        visibilityObservation?.record(isVisible: window.occlusionState.contains(.visible),
            elapsedSeconds: CACurrentMediaTime() - started)
        try require(visibilityObservation?.wasInterrupted == false, "Continuous playback ended with occlusion")
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

    private func waitForGPURenderQueriesToSettle(_ engine: MPVPlaybackEngine) async throws {
        let deadline = CACurrentMediaTime() + 10
        while true {
            let diagnostics = await engine.diagnostics()
            if !diagnostics.gpuRenderTiming.supported || diagnostics.gpuRenderTiming.pendingQueryCount == 0 {
                return
            }
            if CACurrentMediaTime() >= deadline {
                throw BenchmarkError.failed("GPU render timestamp queries did not settle after stop")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw BenchmarkError.failed(message) }
    }
}
