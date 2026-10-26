import AppKit
import XCTest

/// Opt-in desktop measurement. A separate launcher must verify and open the canonical Debug app
/// in one window before this test runs; XCTest must never launch or terminate the player here.
@MainActor
final class LibraryHitchUITests: XCTestCase {
    @available(macOS 26.0, *)
    func testLibraryScrollWhilePlaying() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let applicationURL = projectRoot
            .appending(path: ".build/DerivedData/Build/Products/Debug/Bomu.app")
            .resolvingSymlinksInPath().standardizedFileURL
        let bundle = try XCTUnwrap(Bundle(url: applicationURL))
        let bundleIdentifier = try XCTUnwrap(bundle.bundleIdentifier)
        let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        XCTAssertEqual(instances.count, 1, "Run exactly one Bomu instance before measuring")
        guard instances.count == 1, let instance = instances.first else { return }
        XCTAssertEqual(instance.bundleURL?.resolvingSymlinksInPath().standardizedFileURL,
                       applicationURL, "The running player must be the verified Debug package")
        guard instance.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == applicationURL else { return }

        let application = XCUIApplication(url: applicationURL)
        XCTAssertEqual(application.windows.count, 1, "Use one ordinary player window")
        guard application.windows.count == 1 else { return }
        let results = application.scrollViews["bomu.library.results"]
        XCTAssertTrue(results.waitForExistence(timeout: 5),
                      "Open a populated Library page and keep playback active before measuring")
        guard results.exists else { return }
        let playbackControl = application.buttons["bomu.playback.togglePause"]
        XCTAssertEqual(playbackControl.label, "Pause", "Playback must be active during scrolling")
        guard playbackControl.label == "Pause" else { return }

        measure(metrics: [XCTHitchMetric(application: application)]) {
            results.swipeUp()
            results.swipeDown()
        }
    }
}
