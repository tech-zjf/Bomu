import AppKit
import QuartzCore

enum WindowScenario: String, Encodable {
    case singleWindow = "single-window"
    case displayTransitions = "display-transitions"

    var measurement: String {
        switch self {
        case .singleWindow:
            "Production PlayerScreen/PlayerModel; one stationary ordinary window; acknowledged pause/resume, then uninterrupted muted playback; no automatic resize, fullscreen or display migration"
        case .displayTransitions:
            "Production PlayerScreen/PlayerModel; one muted file; acknowledged native fullscreen transitions and display migrations, followed by uninterrupted playback"
        }
    }
}

/// Separate evidence from the fixed-geometry CPU baseline: fullscreen animations
/// and SwiftUI controls intentionally contribute work in this scenario.
struct WindowLifecycleReport: Encodable {
    let schemaVersion = 3
    let recordedAt = Date()
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    let logicalProcessors = ProcessInfo.processInfo.activeProcessorCount
    let physicalMemoryBytes = ProcessInfo.processInfo.physicalMemory
    let scenario: WindowScenario
    let measurement: String
    let requestedCycles: Int
    let requestedSoakSeconds: Double
    let screens: [DisplayMeasurement]
    var completed = false
    var failure: String?
    var rounds: [WindowRound] = []
    var soak: [WindowCheckpoint] = []
    var soakVisibility: WindowVisibilityMeasurement?
    var stopped: ActivityMeasurement?
    var shutdown: PlaybackDiagnostics?

    init(scenario: WindowScenario, requestedCycles: Int, requestedSoakSeconds: Double,
         screens: [DisplayMeasurement]) {
        self.scenario = scenario
        measurement = scenario.measurement
        self.requestedCycles = requestedCycles
        self.requestedSoakSeconds = requestedSoakSeconds
        self.screens = screens
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

struct DisplayMeasurement: Encodable {
    let id: UInt32
    let isBuiltIn: Bool
    let name: String
    let widthPoints: Double
    let heightPoints: Double
    let backingScale: Double
    let maximumFramesPerSecond: Int
    let colorSpace: String?

    @MainActor
    init(_ screen: NSScreen) throws {
        id = try Self.id(of: screen)
        isBuiltIn = CGDisplayIsBuiltin(id) != 0
        name = screen.localizedName
        widthPoints = screen.frame.width
        heightPoints = screen.frame.height
        backingScale = screen.backingScaleFactor
        maximumFramesPerSecond = screen.maximumFramesPerSecond
        colorSpace = screen.colorSpace?.localizedName
    }

    @MainActor
    static func id(of screen: NSScreen) throws -> UInt32 {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            throw BenchmarkError.failed("The screen has no display identifier")
        }
        return number.uint32Value
    }
}

struct WindowRound: Encodable {
    let cycle: Int
    let enterFullScreenMilliseconds: Double?
    let exitFullScreenMilliseconds: Double?
    let pauseCommandID: UInt64
    let resumeCommandID: UInt64
    let checkpoint: WindowCheckpoint
}

struct WindowCheckpoint: Encodable {
    let elapsedSeconds: Double
    let positionSeconds: Double
    let displayID: UInt32
    let backingScale: Double
    let surfaceContentsScale: Double
    let contentWidth: Double
    let contentHeight: Double
    let process: ProcessSample
    let playback: PlaybackDiagnostics

    @MainActor
    static func read(window: NSWindow, engine: MPVPlaybackEngine,
                     player: PlayerModel, started: Double) async throws -> WindowCheckpoint {
        guard let screen = window.screen, let content = window.contentView,
              let layer = engine.videoView.layer, let snapshot = player.state.snapshot else {
            throw BenchmarkError.failed("Window, surface or playback snapshot disappeared")
        }
        guard engine.videoView.window === window else {
            throw BenchmarkError.failed("The production video surface detached from its window")
        }
        let diagnostics = await engine.diagnostics()
        guard diagnostics.coreAlive && diagnostics.renderContextAlive,
              diagnostics.coreCreationCount == 1, diagnostics.renderContextCreationCount == 1,
              diagnostics.openCount == 1 else {
            throw BenchmarkError.failed("Window operations replaced or released the playback session")
        }
        guard layer.contentsScale == window.backingScaleFactor else {
            throw BenchmarkError.failed("Video layer did not adopt the window's backing scale")
        }
        return WindowCheckpoint(elapsedSeconds: CACurrentMediaTime() - started,
            positionSeconds: snapshot.position, displayID: try DisplayMeasurement.id(of: screen),
            backingScale: window.backingScaleFactor, surfaceContentsScale: layer.contentsScale,
            contentWidth: content.bounds.width, contentHeight: content.bounds.height,
            process: try ProcessSample.read(window: window), playback: diagnostics)
    }
}
