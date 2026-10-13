import Foundation

/// A non-atomic view across the control and render owners, intended for quiescent checkpoints.
/// First-frame time belongs to the first media frame in this render context's lifetime.
struct PlaybackDiagnostics: Codable, Sendable {
    let coreAlive: Bool
    let renderContextAlive: Bool
    let coreCreationCount: UInt64
    let renderContextCreationCount: UInt64
    let idle: Bool?
    let videoOutputConfigured: Bool?
    let hardwareDecoder: String?
    let videoWidth: Int?
    let videoHeight: Int?
    let openCount: UInt64
    let snapshotCount: UInt64
    let drawCount: UInt64
    let videoFrameCount: UInt64
    let skippedFrameCount: UInt64
    let firstVideoFrameUptime: Double?
    let videoSyncMode: String?
    let videoTimingOffset: Double?
    let frameTiming: FrameSubmissionTiming?

    init(_ native: BMPlaybackDiagnostics) {
        coreAlive = native.coreAlive
        renderContextAlive = native.renderContextAlive
        coreCreationCount = native.coreCreationCount
        renderContextCreationCount = native.renderContextCreationCount
        idle = native.idle?.boolValue
        videoOutputConfigured = native.videoOutputConfigured?.boolValue
        hardwareDecoder = native.hardwareDecoder
        videoWidth = native.videoWidth?.intValue
        videoHeight = native.videoHeight?.intValue
        openCount = native.openCount
        snapshotCount = native.snapshotCount
        drawCount = native.drawCount
        videoFrameCount = native.videoFrameCount
        skippedFrameCount = native.skippedFrameCount
        firstVideoFrameUptime = native.firstVideoFrameUptime?.doubleValue
        videoSyncMode = native.videoSyncMode
        videoTimingOffset = native.videoTimingOffset?.doubleValue
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
