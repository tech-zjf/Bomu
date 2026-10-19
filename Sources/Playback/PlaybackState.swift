import Foundation

/// Values crossing the engine boundary contain no native handles or view objects.
struct PlaybackRequest: Equatable, Sendable {
    let id: UInt64
    let url: URL
}

struct PlaybackStartPosition: Equatable, Sendable {
    let seconds: Double

    init?(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        self.seconds = seconds
    }
}

struct PlaybackOpenOptions: Equatable, Sendable {
    let startPosition: PlaybackStartPosition?

    init(startPosition: PlaybackStartPosition? = nil) {
        self.startPosition = startPosition
    }
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

struct PlaybackTrack: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case audio
        case subtitle
        case video
    }

    let id: Int
    let kind: Kind
    let language: String?
    let title: String?
    let isSelected: Bool
    let isExternal: Bool
}

struct PlaybackFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case unavailable
        case permissionDenied
        case unsupportedOrDamaged
        case engine
    }

    let kind: Kind
    let detail: String?

    init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        guard kind == .unsupportedOrDamaged || kind == .engine,
              let detail else {
            self.detail = nil
            return
        }
        let value = String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        self.detail = value.isEmpty ? nil : value
    }

    var title: String {
        switch kind {
        case .unavailable: String(localized: "failure.unavailable.title")
        case .permissionDenied: String(localized: "failure.permission.title")
        case .unsupportedOrDamaged: String(localized: "failure.decode.title")
        case .engine: String(localized: "failure.engine.title")
        }
    }

    var explanation: String {
        switch kind {
        case .unavailable: String(localized: "failure.unavailable.message")
        case .permissionDenied: String(localized: "failure.permission.message")
        case .unsupportedOrDamaged: String(localized: "failure.decode.message")
        case .engine: String(localized: "failure.engine.message")
        }
    }
}

struct PlaybackCommandFailure: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case audioTrack
        case subtitle
    }

    let kind: Kind
    let detail: String?

    init(kind: Kind, detail: String? = nil) {
        self.kind = kind
        guard let detail else {
            self.detail = nil
            return
        }
        let value = String(detail.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        self.detail = value.isEmpty ? nil : value
    }

    var title: String {
        switch kind {
        case .audioTrack: String(localized: "player.commandFailure.audio.title")
        case .subtitle: String(localized: "player.commandFailure.subtitle.title")
        }
    }

    var explanation: String {
        switch kind {
        case .audioTrack: String(localized: "player.commandFailure.audio.message")
        case .subtitle: String(localized: "player.commandFailure.subtitle.message")
        }
    }
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
    var speed: Double = 1
    var audioTrackID: Int? = nil
    var subtitleTrackID: Int? = nil
    var subtitleDelay: Double = 0
    var tracks: [PlaybackTrack] = []
}

enum PlaybackEvent: Equatable, Sendable {
    case loaded(UInt64)
    case snapshot(PlaybackSnapshot)
    case ended(UInt64)
    case failed(UInt64, PlaybackFailure)
    case commandFailed(UInt64, PlaybackCommandFailure)
}

/// The current request is authoritative. Late events from replaced files have no effect.
struct PlaybackState: Equatable, Sendable {
    enum Activity: Equatable, Sendable {
        case opening
        case seeking
        case buffering
    }

    enum Phase: Equatable, Sendable {
        case idle
        case opening
        case ready
        case ended
        case failed(PlaybackFailure)
    }

    private(set) var request: PlaybackRequest?
    private(set) var phase: Phase = .idle
    private(set) var snapshot: PlaybackSnapshot?
    private(set) var commandFailure: PlaybackCommandFailure?

    /// Presentation derives waiting from the current request; it never changes pause intent.
    var activity: Activity? {
        switch phase {
        case .opening: return .opening
        case .ready:
            guard let snapshot else { return .opening }
            if snapshot.isSeeking { return .seeking }
            if snapshot.isBuffering { return .buffering }
            return nil
        case .idle, .ended, .failed: return nil
        }
    }

    mutating func open(_ request: PlaybackRequest) {
        self.request = request
        phase = .opening
        snapshot = nil
        commandFailure = nil
    }

    mutating func stop() {
        request = nil
        snapshot = nil
        phase = .idle
        commandFailure = nil
    }

    mutating func dismissCommandFailure() {
        commandFailure = nil
    }

    /// Returns whether the event was accepted for the current request.
    @discardableResult
    mutating func receive(_ event: PlaybackEvent) -> Bool {
        switch event {
        case .loaded(let id):
            guard request?.id == id, phase == .opening else { return false }
            phase = .ready
            commandFailure = nil
            return true
        case .snapshot(let value):
            guard request?.id == value.requestID, phase == .ready else { return false }
            // Once a newer command is observed, an older command's snapshot cannot roll it back.
            if let snapshot, value.pauseCommandID < snapshot.pauseCommandID { return false }
            snapshot = value
            return true
        case .ended(let id):
            guard request?.id == id, phase == .ready else { return false }
            phase = .ended
            return true
        case .failed(let id, let failure):
            // File failure is valid while opening or ready. Ended and failed are
            // terminal for this request; late native events cannot replace them.
            guard request?.id == id, phase == .opening || phase == .ready else { return false }
            phase = .failed(failure)
            snapshot = nil
            commandFailure = nil
            return true
        case .commandFailed(let id, let failure):
            guard request?.id == id, phase == .ready else { return false }
            commandFailure = failure
            return true
        }
    }
}
