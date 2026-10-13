import Foundation

/// Commands enqueue user intent; events confirm the resulting media state.
/// Startup and shutdown complete only when their native resources are ready or released.
@MainActor
protocol PlaybackEngine: AnyObject {
    var onEvent: ((PlaybackEvent) -> Void)? { get set }
    func prepare() async throws
    func open(_ request: PlaybackRequest)
    func setPaused(_ request: PlaybackPauseRequest)
    func seek(_ request: PlaybackSeekRequest)
    func setVolume(_ volume: Double)
    func stop()
    func shutdown() async
}
