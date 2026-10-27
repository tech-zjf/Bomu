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
        let runningBundleComponents = instance.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        XCTAssertEqual(runningBundleComponents, applicationURL.pathComponents,
                       "The running player must be the verified Debug package")
        guard runningBundleComponents == applicationURL.pathComponents else { return }

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

        // The first invocation is XCTest's discarded warm-up. One subsequent sample is
        // exploratory evidence, not a statistically repeatable performance gate.
        let options = XCTMeasureOptions()
        options.iterationCount = 1
        // XCTest may be denied Desktop access even when the launcher can write there.
        // Use the per-user temporary directory so the observer can publish its phase.
        let phaseURL = FileManager.default.temporaryDirectory
            .appending(path: "bomu-library-hitch-phase-\(instance.processIdentifier).json")
        try FileManager.default.createDirectory(at: phaseURL.deletingLastPathComponent(),
                                               withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: phaseURL) }
        var invocation = 0
        var phaseWriteFailed = false
        measure(metrics: [XCTHitchMetric(application: application)], options: options) {
            invocation += 1
            let phase = invocation == 1 ? "warmup" : "recording"
            let startedAt = Date()
            let status: [String: Any] = [
                "phase": phase,
                "invocation": invocation,
                "pid": instance.processIdentifier,
                "startedAt": startedAt.timeIntervalSince1970,
                "deadline": startedAt.addingTimeInterval(20).timeIntervalSince1970,
            ]
            do {
                let data = try JSONSerialization.data(withJSONObject: status, options: .sortedKeys)
                try data.write(to: phaseURL, options: .atomic)
            } catch {
                phaseWriteFailed = true
                XCTFail("Cannot publish the bounded measurement phase: \(error)")
                return
            }
            // This runner only observes the app. CUA supplies scrolling during both
            // announced intervals; no XCTest launch, activation, input or termination.
            Thread.sleep(forTimeInterval: 20)
        }
        guard !phaseWriteFailed else { return }
        XCTAssertEqual(invocation, 2, "Recheck warm-up semantics if the toolchain changes")
        XCTAssertFalse(instance.isTerminated, "Discard measurements if the player exited")
        XCTAssertEqual(application.windows.count, 1, "The one-window precondition must remain true")
        XCTAssertTrue(results.exists, "Remain on the Library page throughout measurement")
        XCTAssertEqual(playbackControl.label, "Pause", "Playback must still be active")
    }
}
