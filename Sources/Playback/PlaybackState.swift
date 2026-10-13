import Foundation

/// Values crossing the engine boundary contain no native handles or view objects.
struct PlaybackRequest: Equatable, Sendable {
    let id: UInt64
    let url: URL
}

/// Identifies an asynchronous pause intent within a file request.
struct PlaybackPauseRequest: Equatable, Sendable {
    let requestID: UInt64
    let commandID: UInt64
    let isPaused: Bool
}

/// Preserve relative intent until it reaches the engine's authoritative seek queue.
/// Progress snapshots confirm observed position; they are not a basis for queued skips.
struct PlaybackSeekRequest: Equatable, Sendable {
    enum Target: Equatable, Sendable {
        case absolute(Double)
        case relative(Double)
    }

    let requestID: UInt64
    let target: Target
}

struct PlaybackSnapshot: Equatable, Sendable {
    let requestID: UInt64
    var pauseCommandID: UInt64
    var position: Double
    var duration: Double?
    var isPaused: Bool
    var isSeeking: Bool
    var isBuffering: Bool
    var isSeekable: Bool
    var volume: Double
}

enum PlaybackEvent: Equatable, Sendable {
    case loaded(UInt64)
    case snapshot(PlaybackSnapshot)
    case ended(UInt64)
    case failed(UInt64, String)
}

/// The current request is authoritative. Late events from replaced files have no effect.
struct PlaybackState: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case idle
        case opening
        case ready
        case ended
        case failed(String)
    }

    private(set) var request: PlaybackRequest?
    private(set) var phase: Phase = .idle
    private(set) var snapshot: PlaybackSnapshot?

    mutating func open(_ request: PlaybackRequest) {
        self.request = request
        phase = .opening
        snapshot = nil
    }

    mutating func stop() {
        request = nil
        snapshot = nil
        phase = .idle
    }

    mutating func receive(_ event: PlaybackEvent) {
        switch event {
        case .loaded(let id):
            guard request?.id == id, phase == .opening else { return }
            phase = .ready
        case .snapshot(let value):
            guard request?.id == value.requestID, phase == .ready else { return }
            // Once a newer command is observed, an older command's snapshot cannot roll it back.
            if let snapshot, value.pauseCommandID < snapshot.pauseCommandID { return }
            snapshot = value
        case .ended(let id):
            guard request?.id == id, phase == .ready else { return }
            phase = .ended
        case .failed(let id, let message):
            guard request?.id == id else { return }
            phase = .failed(message)
            snapshot = nil
        }
    }
}
