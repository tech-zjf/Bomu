import Foundation

/// Records AppKit-reported visibility transitions throughout the soak interval.
/// Returning to visible cannot erase an interruption between periodic checkpoints.
struct WindowVisibilityMeasurement: Encodable {
    struct Change: Encodable, Equatable {
        let elapsedSeconds: Double
        let isVisible: Bool
    }

    let method = "Initial/final state, NSWindowDelegate occlusion notifications, and checkpoint observations"
    let startedAtSeconds: Double
    private(set) var endedAtSeconds: Double?
    private(set) var changes: [Change]

    var wasInterrupted: Bool { changes.contains { !$0.isVisible } }

    init(isVisible: Bool, elapsedSeconds: Double) {
        startedAtSeconds = elapsedSeconds
        changes = [Change(elapsedSeconds: elapsedSeconds, isVisible: isVisible)]
    }

    mutating func record(isVisible: Bool, elapsedSeconds: Double) {
        guard endedAtSeconds == nil, changes.last?.isVisible != isVisible else { return }
        changes.append(Change(elapsedSeconds: elapsedSeconds, isVisible: isVisible))
    }

    mutating func finish(isVisible: Bool, elapsedSeconds: Double) {
        guard endedAtSeconds == nil else { return }
        record(isVisible: isVisible, elapsedSeconds: elapsedSeconds)
        endedAtSeconds = elapsedSeconds
    }
}
