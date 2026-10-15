import Foundation
import Observation

/// Owns small user preferences whose scope is the whole local player installation.
@MainActor @Observable
final class PlaybackPreferences {
    static let supportedSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private enum Key {
        static let automaticallyPlayNext = "playback.automaticallyPlayNext"
        static let resumeFromLastPosition = "playback.resumeFromLastPosition"
        static let defaultSpeed = "playback.defaultSpeed"
        static let subtitleDelay = "subtitles.defaultDelay"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var automaticallyPlayNext: Bool {
        didSet { defaults.set(automaticallyPlayNext, forKey: Key.automaticallyPlayNext) }
    }

    var resumeFromLastPosition: Bool {
        didSet { defaults.set(resumeFromLastPosition, forKey: Key.resumeFromLastPosition) }
    }

    var defaultSpeed: Double {
        didSet {
            let normalized = Self.normalizedSpeed(defaultSpeed)
            guard normalized != defaultSpeed else {
                defaults.set(defaultSpeed, forKey: Key.defaultSpeed)
                return
            }
            defaultSpeed = normalized
        }
    }

    var defaultSubtitleDelay: Double {
        didSet {
            let normalized = Self.normalizedSubtitleDelay(defaultSubtitleDelay)
            guard normalized != defaultSubtitleDelay else {
                defaults.set(defaultSubtitleDelay, forKey: Key.subtitleDelay)
                return
            }
            defaultSubtitleDelay = normalized
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        automaticallyPlayNext = defaults.object(forKey: Key.automaticallyPlayNext) as? Bool ?? true
        resumeFromLastPosition = defaults.object(forKey: Key.resumeFromLastPosition) as? Bool ?? true
        defaultSpeed = Self.normalizedSpeed(defaults.object(forKey: Key.defaultSpeed) as? Double ?? 1)
        defaultSubtitleDelay = Self.normalizedSubtitleDelay(
            defaults.object(forKey: Key.subtitleDelay) as? Double ?? 0
        )
    }

    var archiveSnapshot: MediaLibraryArchive.Settings {
        MediaLibraryArchive.Settings(automaticallyPlayNext: automaticallyPlayNext,
            resumeFromLastPosition: resumeFromLastPosition,
            defaultSpeed: defaultSpeed, defaultSubtitleDelay: defaultSubtitleDelay)
    }

    func applyArchiveSettings(_ settings: MediaLibraryArchive.Settings) {
        automaticallyPlayNext = settings.automaticallyPlayNext
        resumeFromLastPosition = settings.resumeFromLastPosition
        defaultSpeed = settings.defaultSpeed
        defaultSubtitleDelay = settings.defaultSubtitleDelay
    }

    private static func normalizedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return supportedSpeeds.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1
    }

    private static func normalizedSubtitleDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(30, max(-30, value))
    }
}
