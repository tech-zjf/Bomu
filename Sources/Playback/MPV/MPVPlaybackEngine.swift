import AppKit

/// Translates the native boundary once, before events enter feature state.
@MainActor
final class MPVPlaybackEngine: PlaybackEngine {
    var onEvent: ((PlaybackEvent) -> Void)?
    var videoView: NSView { session.videoView }
    private let session = BMMPVSession()

    init() {
        session.onUpdate = { [weak self] update in
            // BMMPVSession guarantees main-queue delivery; this assertion checks that contract.
            MainActor.assumeIsolated {
                self?.receive(update)
            }
        }
    }

    func prepare() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.prepare { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func open(_ request: PlaybackRequest) { session.open(request.url, requestID: request.id) }
    func setPaused(_ request: PlaybackPauseRequest) {
        session.setPaused(request.isPaused, requestID: request.requestID, commandID: request.commandID)
    }
    func seek(_ request: PlaybackSeekRequest) {
        switch request.target {
        case .absolute(let seconds):
            session.seek(seconds: seconds, relative: false, requestID: request.requestID)
        case .relative(let seconds):
            session.seek(seconds: seconds, relative: true, requestID: request.requestID)
        }
    }
    func setVolume(_ volume: Double) { session.setVolume(volume) }
    func setSpeed(_ speed: Double) { session.setSpeed(speed) }
    func setAudioTrack(id: Int, requestID: UInt64) { session.setAudioTrackID(Int64(id), requestID: requestID) }
    func setSubtitleTrack(id: Int, requestID: UInt64) { session.setSubtitleTrackID(Int64(id), requestID: requestID) }
    func addExternalSubtitle(_ url: URL, requestID: UInt64) {
        session.addExternalSubtitleURL(url, requestID: requestID)
    }
    func setSubtitleDelay(_ seconds: Double, requestID: UInt64) {
        session.setSubtitleDelay(seconds, requestID: requestID)
    }
    func stop() { session.stop() }

    func shutdown() async {
        session.onUpdate = nil
        await withCheckedContinuation { continuation in
            session.shutdown { continuation.resume() }
        }
    }

    /// Development diagnostics use the same owners and queues as normal playback.
    /// They are not playback state and are never sampled by the product UI.
    func diagnostics() async -> PlaybackDiagnostics {
        await withCheckedContinuation { continuation in
            session.collectDiagnostics { value in
                continuation.resume(returning: PlaybackDiagnostics(value))
            }
        }
    }

    private func receive(_ update: BMPlaybackUpdate) {
        switch update.kind {
        case .loaded:
            onEvent?(.loaded(update.requestID))
        case .snapshot:
            onEvent?(.snapshot(PlaybackSnapshot(
                requestID: update.requestID,
                pauseCommandID: update.pauseCommandID,
                position: update.position,
                duration: update.duration?.doubleValue,
                isPaused: update.paused,
                isSeeking: update.seeking,
                isBuffering: update.buffering,
                isSeekable: update.seekable,
                volume: update.volume,
                speed: update.speed,
                audioTrackID: update.audioTrackID?.intValue,
                subtitleTrackID: update.subtitleTrackID?.intValue,
                subtitleDelay: update.subtitleDelay,
                tracks: update.tracks.compactMap { value in
                    let kindValue = value.trackType == "sub" ? "subtitle" : value.trackType
                    guard let kind = PlaybackTrack.Kind(rawValue: kindValue) else { return nil }
                    return PlaybackTrack(id: Int(value.trackID), kind: kind, language: value.language,
                                         title: value.title, isSelected: value.selected, isExternal: value.external)
                }
            )))
        case .ended:
            onEvent?(.ended(update.requestID))
        case .failed:
            let kind: PlaybackFailure.Kind
            switch update.failureKind {
            case .unavailable: kind = .unavailable
            case .permissionDenied: kind = .permissionDenied
            case .unsupportedOrDamaged: kind = .unsupportedOrDamaged
            case .engine: kind = .engine
            @unknown default:
                assertionFailure("Unmapped native playback failure")
                kind = .engine
            }
            onEvent?(.failed(update.requestID, PlaybackFailure(kind: kind, detail: update.message)))
        case .commandFailed:
            let kind: PlaybackCommandFailure.Kind
            switch update.commandFailureKind {
            case .audioTrack: kind = .audioTrack
            case .subtitle: kind = .subtitle
            @unknown default:
                assertionFailure("Unmapped native playback command failure")
                kind = .subtitle
            }
            onEvent?(.commandFailed(update.requestID,
                                    PlaybackCommandFailure(kind: kind, detail: update.message)))
        @unknown default:
            assertionFailure("Unmapped native playback event")
        }
    }
}
