import XCTest

final class WindowVisibilityMeasurementTests: XCTestCase {
    func testShortOcclusionBetweenVisibleCheckpointsRemainsAnInterruption() {
        var measurement = WindowVisibilityMeasurement(isVisible: true, elapsedSeconds: 0)
        measurement.record(isVisible: false, elapsedSeconds: 4)
        measurement.record(isVisible: true, elapsedSeconds: 5)
        measurement.record(isVisible: true, elapsedSeconds: 10)
        measurement.finish(isVisible: true, elapsedSeconds: 10)
        XCTAssertTrue(measurement.wasInterrupted)
        XCTAssertEqual(measurement.changes, [
            .init(elapsedSeconds: 0, isVisible: true),
            .init(elapsedSeconds: 4, isVisible: false),
            .init(elapsedSeconds: 5, isVisible: true)
        ])
        XCTAssertEqual(measurement.endedAtSeconds, 10)
    }

    func testInitialAndFinalOcclusionCannotPass() {
        let hidden = WindowVisibilityMeasurement(isVisible: false, elapsedSeconds: 3)
        XCTAssertTrue(hidden.wasInterrupted)
        var measurement = WindowVisibilityMeasurement(isVisible: true, elapsedSeconds: 0)
        measurement.finish(isVisible: false, elapsedSeconds: 10)
        XCTAssertTrue(measurement.wasInterrupted)
        XCTAssertEqual(measurement.changes.last, .init(elapsedSeconds: 10, isVisible: false))
    }

    func testNotificationsAfterObservationEndsCannotAlterSavedEvidence() throws {
        var measurement = WindowVisibilityMeasurement(isVisible: true, elapsedSeconds: 2)
        measurement.record(isVisible: true, elapsedSeconds: 4)
        measurement.finish(isVisible: true, elapsedSeconds: 12)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let evidence = try encoder.encode(measurement)
        measurement.record(isVisible: false, elapsedSeconds: 13)
        measurement.finish(isVisible: false, elapsedSeconds: 14)
        XCTAssertFalse(measurement.wasInterrupted)
        XCTAssertEqual(measurement.changes.count, 1)
        XCTAssertEqual(try encoder.encode(measurement), evidence)
    }
}
