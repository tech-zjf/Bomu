import MediaPlayer

/// Owns system playback commands only while this app has a ready media item.
@MainActor
final class NowPlayingController {
    private let player: PlayerModel
    private let system: any NowPlayingSystem
    private var registrationID: UUID?
    private var requestID: UInt64?
    private var isShutDown = false
    private var lastPublishedAt = Date.distantPast
    private var lastPublished: NowPlayingMetadata?

    init(player: PlayerModel, system: (any NowPlayingSystem)? = nil) {
        self.player = player
        self.system = system ?? SystemNowPlaying()
    }

    func update() {
        guard !isShutDown, player.canControlPlayback, let snapshot = player.state.snapshot,
              let request = player.state.request else {
            deactivate()
            return
        }
        activateIfNeeded(requestID: request.id)
        system.setQueueAvailability(next: player.queue.nextURL != nil,
                                    previous: player.queue.previousURL != nil)

        let metadata = NowPlayingMetadata(request: request, snapshot: snapshot, isPaused: player.isPaused)
        let now = Date()
        guard metadata.requiresPublication(after: lastPublished,
                                           elapsed: now.timeIntervalSince(lastPublishedAt)) else { return }
        system.publish(metadata)
        lastPublishedAt = now
        lastPublished = metadata
    }

    func shutdown() {
        isShutDown = true
        deactivate()
    }

    func deactivate() {
        // Invalidate queued callbacks before releasing their native command targets.
        let wasActive = registrationID != nil
        registrationID = nil
        requestID = nil
        if wasActive { system.deactivate() }
        lastPublishedAt = .distantPast
        lastPublished = nil
    }

    private func activateIfNeeded(requestID: UInt64) {
        guard self.requestID != requestID || registrationID == nil else { return }
        deactivate()
        let registrationID = UUID()
        self.registrationID = registrationID
        self.requestID = requestID
        system.activate { [weak self] command in
            guard let self, self.registrationID == registrationID,
                  self.player.state.request?.id == requestID,
                  self.player.canControlPlayback else { return }
            switch command {
            case .play:
                if self.player.isPaused { self.player.togglePause() }
            case .pause:
                if !self.player.isPaused { self.player.togglePause() }
            case .togglePause: self.player.togglePause()
            case .next: self.player.playNext()
            case .previous: self.player.playPrevious()
            }
            self.update()
        }
    }
}

struct NowPlayingMetadata: Equatable {
    let requestID: UInt64
    let title: String
    let position: Double
    let duration: Double?
    let rate: Double
    let defaultRate: Double
    let playbackState: MPNowPlayingPlaybackState

    init(request: PlaybackRequest, snapshot: PlaybackSnapshot, isPaused: Bool) {
        requestID = request.id
        title = request.url.deletingPathExtension().lastPathComponent
        position = snapshot.position
        duration = snapshot.duration
        defaultRate = snapshot.speed
        if isPaused {
            playbackState = .paused
            rate = 0
        } else if snapshot.isBuffering || snapshot.isSeeking {
            playbackState = .interrupted
            rate = 0
        } else {
            playbackState = .playing
            rate = snapshot.speed
        }
    }

    func requiresPublication(after previous: Self?, elapsed: TimeInterval) -> Bool {
        guard let previous else { return true }
        return requestID != previous.requestID || title != previous.title || duration != previous.duration
            || rate != previous.rate || defaultRate != previous.defaultRate
            || playbackState != previous.playbackState || abs(position - previous.position) >= 0.8
            || elapsed >= 1
    }

    var information: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: defaultRate
        ]
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        return info
    }
}

enum NowPlayingCommand { case play, pause, togglePause, next, previous }

/// The platform boundary keeps hostless checks away from the shared system command center.
@MainActor
protocol NowPlayingSystem {
    func activate(handler: @escaping @MainActor (NowPlayingCommand) -> Void)
    func setQueueAvailability(next: Bool, previous: Bool)
    func publish(_ metadata: NowPlayingMetadata)
    func deactivate()
}

@MainActor
private final class SystemNowPlaying: NowPlayingSystem {
    private let commandCenter = MPRemoteCommandCenter.shared()
    private let infoCenter = MPNowPlayingInfoCenter.default()
    private var targets: [(MPRemoteCommand, Any)] = []

    func activate(handler: @escaping @MainActor (NowPlayingCommand) -> Void) {
        guard targets.isEmpty else { return }
        register(commandCenter.playCommand, action: .play, handler: handler)
        register(commandCenter.pauseCommand, action: .pause, handler: handler)
        register(commandCenter.togglePlayPauseCommand, action: .togglePause, handler: handler)
        register(commandCenter.nextTrackCommand, action: .next, handler: handler)
        register(commandCenter.previousTrackCommand, action: .previous, handler: handler)
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
    }

    func setQueueAvailability(next: Bool, previous: Bool) {
        commandCenter.nextTrackCommand.isEnabled = next
        commandCenter.previousTrackCommand.isEnabled = previous
    }

    func publish(_ metadata: NowPlayingMetadata) {
        infoCenter.nowPlayingInfo = metadata.information
        infoCenter.playbackState = metadata.playbackState
    }

    func deactivate() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        infoCenter.playbackState = .stopped
        infoCenter.nowPlayingInfo = nil
    }

    private func register(_ command: MPRemoteCommand, action: NowPlayingCommand,
                          handler: @escaping @MainActor (NowPlayingCommand) -> Void) {
        let target = command.addTarget { _ in
            Task { @MainActor in handler(action) }
            return .success
        }
        targets.append((command, target))
    }
}
