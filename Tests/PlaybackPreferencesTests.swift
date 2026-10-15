import Foundation
import XCTest

@MainActor
final class PlaybackPreferencesTests: XCTestCase {
    func testDefaultsAndValidatedValuesPersistAcrossInstances() {
        let suite = "Bomu.PlaybackPreferencesTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("An isolated preferences domain should be available")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertTrue(preferences.automaticallyPlayNext)
        XCTAssertTrue(preferences.resumeFromLastPosition)
        XCTAssertEqual(preferences.defaultSpeed, 1)
        XCTAssertEqual(preferences.defaultSubtitleDelay, 0)

        preferences.automaticallyPlayNext = false
        preferences.resumeFromLastPosition = false
        preferences.defaultSpeed = 1.3
        preferences.defaultSubtitleDelay = 45

        let restored = PlaybackPreferences(defaults: defaults)
        XCTAssertFalse(restored.automaticallyPlayNext)
        XCTAssertFalse(restored.resumeFromLastPosition)
        XCTAssertEqual(restored.defaultSpeed, 1.25)
        XCTAssertEqual(restored.defaultSubtitleDelay, 30)
    }
}
