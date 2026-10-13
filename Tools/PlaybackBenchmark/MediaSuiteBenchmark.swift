import AppKit
import QuartzCore

/// Generated metadata is decoded once at the test boundary. Media checks use the
/// same window, model and native session that the surrounding lifecycle run owns.
struct MediaSuiteManifest: Decodable {
    struct Sample: Codable {
        struct Expected: Codable {
            enum Outcome: String, Codable { case play, reject }
            struct Video: Codable { let width: Int; let height: Int }
            struct Audio: Codable { let sampleRate: Int; let channels: Int }
            let outcome: Outcome
            let durationSeconds: Double?
            let video: Video?
            let audio: Audio?
        }
        let file: String
        let sha256: String
        let coverage: String
        let license: String
        let expected: Expected
    }

    let schemaVersion: Int
    let suite: String
    let samples: [Sample]

    static func read(from directory: URL) throws -> Self {
        let value = try JSONDecoder().decode(Self.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard value.schemaVersion == 2, value.suite == "bomu-a04", value.samples.count == 30,
              Set(value.samples.map(\.file)).count == value.samples.count else {
            throw BenchmarkError.failed("Unsupported or incomplete A04 media manifest")
        }
        for sample in value.samples {
            guard !sample.file.isEmpty, sample.file != ".", sample.file != "..",
                  !sample.file.contains("/"), sample.license == "CC0-1.0",
                  sample.sha256.count == 64, sample.sha256.allSatisfy({ $0.isHexDigit }) else {
                throw BenchmarkError.failed("Invalid media identity or license: \(sample.file)")
            }
            switch sample.expected.outcome {
            case .play:
                guard let duration = sample.expected.durationSeconds, duration.isFinite, duration > 3,
                      sample.expected.video != nil || sample.expected.audio != nil else {
                    throw BenchmarkError.failed("Missing playable-media expectations: \(sample.file)")
                }
                if let video = sample.expected.video, video.width <= 0 || video.height <= 0 {
                    throw BenchmarkError.failed("Invalid video dimensions: \(sample.file)")
                }
                if let audio = sample.expected.audio, audio.sampleRate <= 0 || audio.channels <= 0 {
                    throw BenchmarkError.failed("Invalid audio parameters: \(sample.file)")
                }
            case .reject:
                guard sample.expected.durationSeconds == nil, sample.expected.video == nil,
                      sample.expected.audio == nil else {
                    throw BenchmarkError.failed("Rejected media must not advertise playable streams")
                }
            }
        }
        return value
    }
}

struct MediaSampleMeasurement: Encodable {
    let sample: MediaSuiteManifest.Sample
    let startedAtSeconds: Double
    let windowNumber: Int
    let displayID: UInt32
    var elapsedSeconds: Double = 0
    var requestID: UInt64?
    var passed = false
    var failure: String?
    var observedRejection: String?
    var before: PlaybackDiagnostics?
    var playing: PlaybackDiagnostics?
    var seekTargetSeconds: Double?
    var pausedSeekPositionSeconds: Double?
    var resumedPositionSeconds: Double?
    var finalPlayback: PlaybackDiagnostics?
}

@MainActor
enum MediaSuiteBenchmark {
    static func measure(_ sample: MediaSuiteManifest.Sample, directory: URL, window: NSWindow,
                        player: PlayerModel, engine: MPVPlaybackEngine,
                        started: Double) async throws -> MediaSampleMeasurement {
        guard let screen = window.screen else { throw BenchmarkError.failed("Media window lost its display") }
        let began = CACurrentMediaTime()
        var result = MediaSampleMeasurement(sample: sample, startedAtSeconds: began - started,
            windowNumber: window.windowNumber, displayID: try DisplayMeasurement.id(of: screen))
        do {
            let before = await engine.diagnostics()
            result.before = before
            player.open(directory.appendingPathComponent(sample.file))
            result.requestID = player.state.request?.id
            switch sample.expected.outcome {
            case .reject:
                try await waitUntil("invalid-media rejection") {
                    if case .failed = player.state.phase { return true }
                    return false
                }
                if case .failed(let message) = player.state.phase { result.observedRejection = message }
                try await waitUntil("native idle after rejected media") {
                    let value = await engine.diagnostics()
                    return value.idle == true && value.videoOutputConfigured == false
                }
                result.playing = await engine.diagnostics()
            case .play:
                try await waitUntil("media ready") {
                    if case .failed(let message) = player.state.phase { throw BenchmarkError.failed(message) }
                    return player.canControlPlayback && (player.state.snapshot?.position ?? 0) > 0.5
                }
                let playing = await engine.diagnostics()
                result.playing = playing
                try validate(playing, expected: sample.expected)
                guard let expectedDuration = sample.expected.durationSeconds,
                      let duration = player.state.snapshot?.duration,
                      abs(duration - expectedDuration) < 0.5, player.canSeek else {
                    throw BenchmarkError.failed("Duration or seekability differs from the inspected local media")
                }
                if sample.expected.video != nil && playing.videoFrameCount <= before.videoFrameCount {
                    throw BenchmarkError.failed("The video did not submit any new media frames")
                }
                player.togglePause()
                try await waitUntil("native pause") { player.state.snapshot?.isPaused == true }
                let target = duration / 2
                result.seekTargetSeconds = target
                player.seek(to: target)
                try await waitUntil("paused absolute seek") {
                    guard let snapshot = player.state.snapshot else { return false }
                    return snapshot.isPaused && !snapshot.isSeeking && abs(snapshot.position - target) < 0.2
                }
                result.pausedSeekPositionSeconds = player.state.snapshot?.position
                let paused = await engine.diagnostics()
                player.togglePause()
                try await waitUntil("playback after seek") {
                    guard let snapshot = player.state.snapshot else { return false }
                    return !snapshot.isPaused && snapshot.position > target + 0.2
                }
                result.resumedPositionSeconds = player.state.snapshot?.position
                if sample.expected.video != nil {
                    try await waitUntil("new frame after seek/resume") {
                        (await engine.diagnostics()).videoFrameCount > paused.videoFrameCount
                    }
                }
            }
            let after = await engine.diagnostics()
            guard after.coreAlive, after.renderContextAlive, after.coreCreationCount == 1,
                  after.renderContextCreationCount == 1, after.openCount == before.openCount + 1,
                  engine.videoView.window === window, window.occlusionState.contains(.visible),
                  let currentScreen = window.screen,
                  try DisplayMeasurement.id(of: currentScreen) == result.displayID else {
                throw BenchmarkError.failed("Media check lost its visible window or replaced its native session")
            }
            result.passed = true
        } catch {
            if error is CancellationError { throw error }
            result.failure = String(describing: error)
        }
        result.finalPlayback = await engine.diagnostics()
        result.elapsedSeconds = CACurrentMediaTime() - began
        return result
    }

    private static func validate(_ actual: PlaybackDiagnostics,
                                 expected: MediaSuiteManifest.Sample.Expected) throws {
        if let video = expected.video {
            guard actual.videoOutputConfigured == true, !actual.lastDrawWasClearOnly, actual.videoWidth == video.width,
                  actual.videoHeight == video.height else {
                throw BenchmarkError.failed("Decoded video size or output differs from the fixture manifest")
            }
        } else if actual.videoOutputConfigured != false || !actual.lastDrawWasClearOnly || actual.blankDrawCount == 0 {
            throw BenchmarkError.failed("Audio-only media retained a video output or a previous video image")
        }
        if let audio = expected.audio {
            guard actual.audioSampleRate == audio.sampleRate, actual.audioChannelCount == audio.channels,
                  let outputRate = actual.audioOutputSampleRate, outputRate > 0 else {
                throw BenchmarkError.failed("Decoded audio parameters or active audio output differ from the fixture manifest")
            }
        } else if actual.audioSampleRate != nil || actual.audioOutputSampleRate != nil {
            throw BenchmarkError.failed("Silent video retained a previous audio stream")
        }
    }

    private static func waitUntil(_ description: String,
                                  _ predicate: () async throws -> Bool) async throws {
        let deadline = CACurrentMediaTime() + 10
        while try await !predicate() {
            if CACurrentMediaTime() >= deadline { throw BenchmarkError.failed("Timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(25))
        }
        try Task.checkCancellation()
    }
}
