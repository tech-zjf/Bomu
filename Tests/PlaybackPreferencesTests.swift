import Foundation
import XCTest

@MainActor
final class PlaybackPreferencesTests: XCTestCase {
    func testBrowserDensityPersistsAndArchivesIndependentlyOfPlaybackPreferences() throws {
        let suite = "Bomu.Density.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(preferences.browserDensity, .comfortable)
        preferences.defaultSpeed = 1.5
        preferences.browserDensity = .compact
        let reloaded = PlaybackPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.browserDensity, .compact)
        XCTAssertEqual(reloaded.defaultSpeed, 1.5)
        let encoded = try JSONEncoder().encode(reloaded.archiveSnapshot)
        let settings = try JSONDecoder().decode(MediaLibraryArchive.Settings.self, from: encoded)
        preferences.browserDensity = .comfortable
        preferences.applyArchiveSettings(settings)
        XCTAssertEqual(preferences.browserDensity, .compact)
        let legacy = Data(#"{"automaticallyPlayNext":true,"resumeFromLastPosition":true,"defaultSpeed":1,"defaultSubtitleDelay":0}"#.utf8)
        preferences.applyArchiveSettings(try JSONDecoder().decode(MediaLibraryArchive.Settings.self, from: legacy))
        XCTAssertEqual(preferences.browserDensity, .comfortable)
        var invalid = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        invalid["browserDensity"] = "unknown-density"
        XCTAssertThrowsError(try JSONDecoder().decode(MediaLibraryArchive.Settings.self,
            from: JSONSerialization.data(withJSONObject: invalid)),
            "Unknown archive enum values must fail instead of silently changing the restored layout")
    }

    func testReturnPauseArchiveRoundTripAndOldArchiveDefault() throws {
        let suite = "Bomu.ReturnArchive.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlaybackPreferences(defaults: defaults)
        preferences.pauseOnReturn = true
        preferences.defaultSubtitleScale = 1.5
        let data = try JSONEncoder().encode(preferences.archiveSnapshot)
        let restored = try JSONDecoder().decode(MediaLibraryArchive.Settings.self, from: data)
        XCTAssertEqual(restored.pauseOnReturn, true)
        preferences.pauseOnReturn = false
        preferences.applyArchiveSettings(restored)
        XCTAssertTrue(preferences.pauseOnReturn)
        XCTAssertEqual(preferences.defaultSubtitleScale, 1.5)
        let legacy = Data(#"{"automaticallyPlayNext":true,"resumeFromLastPosition":true,"defaultSpeed":1,"defaultSubtitleDelay":0}"#.utf8)
        preferences.applyArchiveSettings(try JSONDecoder().decode(MediaLibraryArchive.Settings.self, from: legacy))
        XCTAssertFalse(preferences.pauseOnReturn, "Old archives restore the documented continue-playing default")
        XCTAssertEqual(preferences.defaultSubtitleScale, 1)
    }

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
        XCTAssertFalse(preferences.pauseOnReturn)
        XCTAssertEqual(preferences.defaultSpeed, 1)
        XCTAssertEqual(preferences.defaultSubtitleDelay, 0)
        XCTAssertEqual(preferences.defaultSubtitleScale, 1)

        preferences.automaticallyPlayNext = false
        preferences.resumeFromLastPosition = false
        preferences.pauseOnReturn = true
        preferences.defaultSpeed = 1.3
        preferences.defaultSubtitleDelay = 45
        preferences.defaultSubtitleScale = 1.3

        let restored = PlaybackPreferences(defaults: defaults)
        XCTAssertFalse(restored.automaticallyPlayNext)
        XCTAssertFalse(restored.resumeFromLastPosition)
        XCTAssertTrue(restored.pauseOnReturn)
        XCTAssertEqual(restored.defaultSpeed, 1.25)
        XCTAssertEqual(restored.defaultSubtitleDelay, 30)
        XCTAssertEqual(restored.defaultSubtitleScale, 1.25)
    }
}
