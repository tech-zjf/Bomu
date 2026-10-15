import Foundation

/// Commands enqueue user intent; events confirm the resulting media state.
/// Startup and shutdown complete only when their native resources are ready or released.
@MainActor
protocol PlaybackEngine: AnyObject {
    var onEvent: ((PlaybackEvent) -> Void)? { get set }
    func prepare() async throws
    func open(_ request: PlaybackRequest, options: PlaybackOpenOptions)
    func setPaused(_ request: PlaybackPauseRequest)
    func seek(_ request: PlaybackSeekRequest)
    func setVolume(_ volume: Double)
    func setSpeed(_ speed: Double)
    func setAudioTrack(id: Int, requestID: UInt64)
    func setSubtitleTrack(id: Int, requestID: UInt64)
    func addExternalSubtitle(_ url: URL, requestID: UInt64)
    func setSubtitleDelay(_ seconds: Double, requestID: UInt64)
    func stop()
    func shutdown() async
}

extension PlaybackEngine {
    func open(_ request: PlaybackRequest) {
        open(request, options: PlaybackOpenOptions())
    }
}
