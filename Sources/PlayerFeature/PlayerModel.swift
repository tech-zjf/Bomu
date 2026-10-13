import Foundation
import Observation

/// Owns one logical playback session independently of SwiftUI view identity.
@MainActor @Observable
final class PlayerModel {
    private(set) var state = PlaybackState()
    private(set) var startupError: String?
    private(set) var isPrepared = false
    private(set) var isShuttingDown = false
    private var pendingPause: PlaybackPauseRequest?
    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private var nextRequestID: UInt64 = 0
    @ObservationIgnored private var nextPauseCommandID: UInt64 = 0
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    var canControlPlayback: Bool { state.phase == .ready && state.snapshot != nil }
    var canSeek: Bool {
        canControlPlayback && state.snapshot?.isSeekable == true && state.snapshot?.duration != nil
    }
    var isPaused: Bool {
        if let pendingPause { return pendingPause.isPaused }
        if let snapshot = state.snapshot { return snapshot.isPaused }
        return true
    }

    init(engine: any PlaybackEngine) {
        self.engine = engine
        engine.onEvent = { [weak self] event in self?.receive(event) }
    }

    func prepare() {
        guard startupTask == nil, !isShuttingDown else { return }
        startupTask = Task { [weak self, engine] in
            do {
                try await engine.prepare()
                guard let self, !self.isShuttingDown else { return }
                self.isPrepared = true
                if let request = self.state.request { engine.open(request) }
            } catch {
                self?.startupError = error.localizedDescription
            }
        }
    }

    func open(_ url: URL) {
        guard !isShuttingDown, startupError == nil else { return }
        nextRequestID += 1
        let request = PlaybackRequest(id: nextRequestID, url: url)
        pendingPause = nil
        state.open(request)
        if isPrepared { engine.open(request) }
        prepare()
    }

    func togglePause() {
        if state.phase == .ended, let request = state.request {
            open(request.url)
            return
        }
        guard canControlPlayback, let request = state.request else { return }
        nextPauseCommandID += 1
        let pause = PlaybackPauseRequest(requestID: request.id,
            commandID: nextPauseCommandID, isPaused: !isPaused)
        pendingPause = pause
        engine.setPaused(pause)
    }

    func seek(to seconds: Double) {
        guard canSeek, let request = state.request,
              let duration = state.snapshot?.duration, seconds.isFinite else { return }
        engine.seek(PlaybackSeekRequest(requestID: request.id, target: .absolute(min(duration, max(0, seconds)))))
    }

    func skip(by seconds: Double) {
        guard canSeek, let request = state.request, seconds.isFinite, seconds != 0 else { return }
        engine.seek(PlaybackSeekRequest(requestID: request.id, target: .relative(seconds)))
    }

    func setVolume(_ volume: Double) {
        guard !isShuttingDown, isPrepared, volume.isFinite else { return }
        engine.setVolume(min(100, max(0, volume)))
    }

    func stop() {
        guard !isShuttingDown else { return }
        state.stop()
        pendingPause = nil
        if isPrepared { engine.stop() }
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        isShuttingDown = true
        engine.onEvent = nil
        pendingPause = nil
        state.stop()
        let task = Task { [startupTask, engine] in
            // Initialization owns resources until it returns, even when the window closes early.
            await startupTask?.value
            await engine.shutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func receive(_ event: PlaybackEvent) {
        guard !isShuttingDown else { return }
        state.receive(event)
        guard state.phase == .ready else { pendingPause = nil; return }
        if let pendingPause, let snapshot = state.snapshot,
           snapshot.requestID == pendingPause.requestID,
           snapshot.pauseCommandID == pendingPause.commandID,
           snapshot.isPaused == pendingPause.isPaused {
            self.pendingPause = nil
        }
    }
}
