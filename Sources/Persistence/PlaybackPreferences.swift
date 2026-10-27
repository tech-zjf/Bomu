import Foundation
import Observation

/// Owns small user preferences whose scope is the whole local player installation.
@MainActor @Observable
final class PlaybackPreferences {
    nonisolated static let supportedSubtitleScales = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    static let supportedSpeeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    private enum Key {
        static let automaticallyPlayNext = "playback.automaticallyPlayNext"
        static let resumeFromLastPosition = "playback.resumeFromLastPosition"
        static let pauseOnReturn = "playback.pauseOnReturn"
        static let defaultSpeed = "playback.defaultSpeed"
        static let subtitleScale = "subtitles.defaultScale"
        static let subtitleDelay = "subtitles.defaultDelay"
        static let browserDensity = "library.browserDensity"
    }

    @ObservationIgnored private let defaults: UserDefaults

    var browserDensity: MediaBrowserDensity {
        didSet { defaults.set(browserDensity.rawValue, forKey: Key.browserDensity) }
    }

    var automaticallyPlayNext: Bool {
        didSet { defaults.set(automaticallyPlayNext, forKey: Key.automaticallyPlayNext) }
    }

    var resumeFromLastPosition: Bool {
        didSet { defaults.set(resumeFromLastPosition, forKey: Key.resumeFromLastPosition) }
    }

    var pauseOnReturn: Bool {
        didSet { defaults.set(pauseOnReturn, forKey: Key.pauseOnReturn) }
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

    var defaultSubtitleScale: Double {
        didSet {
            let normalized = Self.normalizedSubtitleScale(defaultSubtitleScale)
            guard normalized != defaultSubtitleScale else {
                defaults.set(defaultSubtitleScale, forKey: Key.subtitleScale)
                return
            }
            defaultSubtitleScale = normalized
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        browserDensity = defaults.string(forKey: Key.browserDensity)
            .flatMap(MediaBrowserDensity.init(rawValue:)) ?? .comfortable
        automaticallyPlayNext = defaults.object(forKey: Key.automaticallyPlayNext) as? Bool ?? true
        resumeFromLastPosition = defaults.object(forKey: Key.resumeFromLastPosition) as? Bool ?? true
        pauseOnReturn = defaults.object(forKey: Key.pauseOnReturn) as? Bool ?? false
        defaultSpeed = Self.normalizedSpeed(defaults.object(forKey: Key.defaultSpeed) as? Double ?? 1)
        defaultSubtitleScale = Self.normalizedSubtitleScale(
            defaults.object(forKey: Key.subtitleScale) as? Double ?? 1
        )
        defaultSubtitleDelay = Self.normalizedSubtitleDelay(
            defaults.object(forKey: Key.subtitleDelay) as? Double ?? 0
        )
    }

    var archiveSnapshot: MediaLibraryArchive.Settings {
        MediaLibraryArchive.Settings(automaticallyPlayNext: automaticallyPlayNext,
            resumeFromLastPosition: resumeFromLastPosition,
            defaultSpeed: defaultSpeed, defaultSubtitleDelay: defaultSubtitleDelay,
            pauseOnReturn: pauseOnReturn, defaultSubtitleScale: defaultSubtitleScale,
            browserDensity: browserDensity)
    }

    func applyArchiveSettings(_ settings: MediaLibraryArchive.Settings) {
        browserDensity = settings.browserDensity ?? .comfortable
        automaticallyPlayNext = settings.automaticallyPlayNext
        resumeFromLastPosition = settings.resumeFromLastPosition
        pauseOnReturn = settings.pauseOnReturn ?? false
        defaultSpeed = settings.defaultSpeed
        defaultSubtitleDelay = settings.defaultSubtitleDelay
        defaultSubtitleScale = settings.defaultSubtitleScale ?? 1
    }

    private static func normalizedSpeed(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return supportedSpeeds.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1
    }

    private static func normalizedSubtitleScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return supportedSubtitleScales.min(by: { abs($0 - value) < abs($1 - value) }) ?? 1
    }

    private static func normalizedSubtitleDelay(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(30, max(-30, value))
    }
}
