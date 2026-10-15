import MediaPlayer

/// Owns system playback commands only while this app has a ready media item.
@MainActor
final class NowPlayingController {
    private let player: PlayerModel
    private let commandCenter = MPRemoteCommandCenter.shared()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var lastPublishedAt = Date.distantPast
    private var lastPublishedPosition: Double?
    private var lastPublishedTitle: String?
    private var lastPublishedDuration: Double?
    private var lastPublishedRate: Double?

    init(player: PlayerModel) {
        self.player = player
    }

    func update() {
        guard player.state.phase == .ready, let snapshot = player.state.snapshot,
              let request = player.state.request else {
            deactivate()
            return
        }
        activateIfNeeded()
        commandCenter.nextTrackCommand.isEnabled = player.queue.nextURL != nil
        commandCenter.previousTrackCommand.isEnabled = player.queue.previousURL != nil

        let title = request.url.deletingPathExtension().lastPathComponent
        let rate = player.isPaused ? 0 : snapshot.speed
        let now = Date()
        let shouldPublish = title != lastPublishedTitle || snapshot.duration != lastPublishedDuration ||
            rate != lastPublishedRate || abs(snapshot.position - (lastPublishedPosition ?? -1)) >= 0.8 ||
            now.timeIntervalSince(lastPublishedAt) >= 1
        guard shouldPublish else { return }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.position,
            MPNowPlayingInfoPropertyPlaybackRate: rate,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: snapshot.speed
        ]
        if let duration = snapshot.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        lastPublishedAt = now
        lastPublishedPosition = snapshot.position
        lastPublishedTitle = title
        lastPublishedDuration = snapshot.duration
        lastPublishedRate = rate
    }

    func deactivate() {
        for (command, target) in targets { command.removeTarget(target) }
        targets.removeAll()
        commandCenter.playCommand.isEnabled = false
        commandCenter.pauseCommand.isEnabled = false
        commandCenter.togglePlayPauseCommand.isEnabled = false
        commandCenter.nextTrackCommand.isEnabled = false
        commandCenter.previousTrackCommand.isEnabled = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        lastPublishedAt = .distantPast
        lastPublishedPosition = nil
        lastPublishedTitle = nil
        lastPublishedDuration = nil
        lastPublishedRate = nil
    }

    private func activateIfNeeded() {
        guard targets.isEmpty else { return }
        register(commandCenter.playCommand) { [weak self] in self?.play() }
        register(commandCenter.pauseCommand) { [weak self] in self?.pause() }
        register(commandCenter.togglePlayPauseCommand) { [weak self] in self?.togglePause() }
        register(commandCenter.nextTrackCommand) { [weak self] in self?.player.playNext() }
        register(commandCenter.previousTrackCommand) { [weak self] in self?.player.playPrevious() }
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.isEnabled = true
    }

    private func register(_ command: MPRemoteCommand, action: @escaping @MainActor () -> Void) {
        let target = command.addTarget { [weak self] _ in
            Task { @MainActor [weak self] in
                guard self != nil else { return }
                action()
            }
            return .success
        }
        targets.append((command, target))
    }

    private func play() {
        if player.isPaused { player.togglePause() }
    }

    private func pause() {
        if !player.isPaused { player.togglePause() }
    }

    private func togglePause() { player.togglePause() }
}
