import Foundation

@MainActor
final class RecordingPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEvent) -> Void)?
    var requests: [PlaybackRequest] = []
    var openOptions: [PlaybackOpenOptions] = []
    var pauses: [Bool] = []
    var mutes: [PlaybackMuteRequest] = []
    var seeks: [PlaybackSeekRequest] = []
    var volumes: [Double] = []
    var speeds: [Double] = []
    var audioTracks: [Int] = []
    var subtitleTracks: [Int] = []
    var audioTrackRequests: [TrackCommand] = []
    var subtitleTrackRequests: [TrackCommand] = []
    var externalSubtitleRequests: [SubtitleCommand] = []
    var subtitleDelays: [SubtitleDelayCommand] = []
    var subtitleScales: [SubtitleScaleCommand] = []
    var stopCount = 0
    var shutdownCount = 0
    var shouldFailPreparation = false
    func prepare() async throws {
        await Task.yield()
        if shouldFailPreparation { throw PreparationFailure.engineUnavailable }
    }
    func open(_ request: PlaybackRequest, options: PlaybackOpenOptions) {
        requests.append(request)
        openOptions.append(options)
    }
    func setPaused(_ request: PlaybackPauseRequest) { pauses.append(request.isPaused) }
    func setMuted(_ request: PlaybackMuteRequest) { mutes.append(request) }
    func seek(_ request: PlaybackSeekRequest) { seeks.append(request) }
    func setVolume(_ volume: Double) { volumes.append(volume) }
    func setSpeed(_ speed: Double) { speeds.append(speed) }
    func setAudioTrack(id: Int, requestID: UInt64) {
        audioTracks.append(id)
        audioTrackRequests.append(TrackCommand(id: id, requestID: requestID))
    }
    func setSubtitleTrack(id: Int, requestID: UInt64) {
        subtitleTracks.append(id)
        subtitleTrackRequests.append(TrackCommand(id: id, requestID: requestID))
    }
    func addExternalSubtitle(_ url: URL, requestID: UInt64) {
        externalSubtitleRequests.append(SubtitleCommand(url: url, requestID: requestID))
    }
    func setSubtitleDelay(_ seconds: Double, requestID: UInt64) {
        subtitleDelays.append(SubtitleDelayCommand(seconds: seconds, requestID: requestID))
    }
    func setSubtitleScale(_ scale: Double, requestID: UInt64) {
        subtitleScales.append(SubtitleScaleCommand(scale: scale, requestID: requestID))
    }
    func stop() { stopCount += 1 }
    func shutdown() async { shutdownCount += 1 }

    private enum PreparationFailure: Error, LocalizedError {
        case engineUnavailable
        var errorDescription: String? { "The playback engine is unavailable." }
    }

    struct TrackCommand: Equatable {
        let id: Int
        let requestID: UInt64
    }

    struct SubtitleCommand: Equatable {
        let url: URL
        let requestID: UInt64
    }

    struct SubtitleScaleCommand: Equatable {
        let scale: Double
        let requestID: UInt64
    }

    struct SubtitleDelayCommand: Equatable {
        let seconds: Double
        let requestID: UInt64
    }
}

@MainActor
func waitUntilPrepared(_ player: PlayerModel) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !player.isPrepared {
        if let error = player.startupError { throw PlaybackPreparationFailure.failed(error) }
        guard clock.now < deadline else { throw PlaybackPreparationFailure.timedOut }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private enum PlaybackPreparationFailure: Error {
    case failed(String)
    case timedOut
}
