import Foundation

/// A non-atomic view across the control and render owners, intended for quiescent checkpoints.
/// First-frame time belongs to the first media frame in this render context's lifetime.
struct PlaybackDiagnostics: Codable, Sendable {
    let coreAlive: Bool
    let renderContextAlive: Bool
    let graphicsContextAlive: Bool?
    let coreCreationCount: UInt64
    let renderContextCreationCount: UInt64
    let idle: Bool?
    let videoOutputConfigured: Bool?
    let hardwareDecoder: String?
    let videoWidth: Int?
    let videoHeight: Int?
    let audioSampleRate: Int?
    let audioChannelCount: Int?
    let audioOutputSampleRate: Int?
    let openCount: UInt64
    let snapshotCount: UInt64
    let drawCount: UInt64
    let videoFrameCount: UInt64
    let skippedFrameCount: UInt64
    let blankDrawCount: UInt64
    let lastDrawWasClearOnly: Bool
    let firstVideoFrameUptime: Double?
    let videoSyncMode: String?
    let videoTimingOffset: Double?
    let frameTiming: FrameSubmissionTiming?
    let gpuRenderTiming: GPURenderTiming

    init(_ native: BMPlaybackDiagnostics) {
        coreAlive = native.coreAlive
        renderContextAlive = native.renderContextAlive
        graphicsContextAlive = native.graphicsContextAlive
        coreCreationCount = native.coreCreationCount
        renderContextCreationCount = native.renderContextCreationCount
        idle = native.idle?.boolValue
        videoOutputConfigured = native.videoOutputConfigured?.boolValue
        hardwareDecoder = native.hardwareDecoder
        videoWidth = native.videoWidth?.intValue
        videoHeight = native.videoHeight?.intValue
        audioSampleRate = native.audioSampleRate?.intValue
        audioChannelCount = native.audioChannelCount?.intValue
        audioOutputSampleRate = native.audioOutputSampleRate?.intValue
        openCount = native.openCount
        snapshotCount = native.snapshotCount
        drawCount = native.drawCount
        videoFrameCount = native.videoFrameCount
        skippedFrameCount = native.skippedFrameCount
        blankDrawCount = native.blankDrawCount
        lastDrawWasClearOnly = native.lastDrawWasClearOnly
        firstVideoFrameUptime = native.firstVideoFrameUptime?.doubleValue
        videoSyncMode = native.videoSyncMode
        videoTimingOffset = native.videoTimingOffset?.doubleValue
        gpuRenderTiming = GPURenderTiming(
            availability: GPURenderTimingAvailability(rawValue: native.gpuRenderTimingAvailability) ?? .unknown,
            mode: GPURenderTimingMode(rawValue: native.gpuRenderTimingMode) ?? .unknown,
            sampleCount: native.gpuRenderTimingSampleCount,
            intervalNanoseconds: native.gpuRenderIntervalNanoseconds,
            pendingQueryCount: native.gpuRenderPendingQueryCount,
            droppedSampleCount: native.gpuRenderDroppedSampleCount
        )
        if native.timedFrameCount > 0 {
            frameTiming = FrameSubmissionTiming(sampleCount: native.timedFrameCount,
                earlyFrameCount: native.earlySubmissionCount,
                averageErrorMilliseconds: Double(native.submissionErrorTotalUS) / Double(native.timedFrameCount) / 1_000,
                minimumErrorMilliseconds: Double(native.submissionErrorMinimumUS) / 1_000,
                maximumErrorMilliseconds: Double(native.submissionErrorMaximumUS) / 1_000)
        } else {
            frameTiming = nil
        }
    }
}

/// Submission minus mpv's target: negative values are early, positive values late.
struct FrameSubmissionTiming: Codable, Sendable {
    let sampleCount: UInt64
    let earlyFrameCount: UInt64
    let averageErrorMilliseconds: Double
    let minimumErrorMilliseconds: Double
    let maximumErrorMilliseconds: Double
}

/// OpenGL render intervals around mpv drawing; excludes hardware decoding and display scanout.
enum GPURenderTimingAvailability: String, Codable, Sendable {
    case disabled
    case extensionUnavailable = "extension-unavailable"
    case counterUnavailable = "counter-unavailable"
    case queryAllocationFailed = "query-allocation-failed"
    case supported
    case unknown
}

enum GPURenderTimingMode: String, Codable, Sendable {
    case disabled
    case timestamp
    case elapsed
    case unknown
}

struct GPURenderTiming: Codable, Sendable {
    let availability: GPURenderTimingAvailability
    let mode: GPURenderTimingMode
    let sampleCount: UInt64
    let intervalNanoseconds: UInt64
    let pendingQueryCount: UInt64
    let droppedSampleCount: UInt64

    var supported: Bool { availability == .supported }
}
