import AVFoundation
import CoreMedia
import Foundation

struct MediaTechnicalMetadata: Equatable, Sendable {
    let duration: TimeInterval?
    let width: Int?
    let height: Int?
    let videoCodec: String?
    let audioTracks: [MediaAudioTrackMetadata]?
}

struct MediaAudioTrackMetadata: Equatable, Sendable {
    let codec: String?
}

/// Implementations must cooperate with task cancellation and release media resources.
protocol MediaMetadataLoading: Sendable {
    func loadMetadata(from url: URL) async throws -> MediaTechnicalMetadata
}

/// Reads container and track facts from local media. Failures stay unknown instead of being guessed.
actor MediaMetadataProbe {
    private struct CacheKey: Hashable {
        let mediaFileID: Int64
        let contentRevision: String
    }

    private struct CacheEntry {
        let metadata: MediaTechnicalMetadata
        var lastAccess: UInt64
    }

    private struct Probe {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<MediaTechnicalMetadata, Never>]
    }

    private var probes: [CacheKey: Probe] = [:]
    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessCounter: UInt64 = 0
    private let maximumCachedEntries: Int
    private let permits: AsyncPermitPool
    private let loader: any MediaMetadataLoading
    private let timeout: Duration

    init(maximumCachedEntries: Int = 2_048, timeout: Duration = .seconds(10),
         sharedPermits: AsyncPermitPool? = nil,
         loader: any MediaMetadataLoading = AVFoundationMetadataLoader()) {
        self.maximumCachedEntries = min(2_048, max(1, maximumCachedEntries))
        self.timeout = timeout
        self.permits = sharedPermits ?? AsyncPermitPool(limit: 2)
        self.loader = loader
    }

    /// Retains known facts while a source is offline without opening the source file.
    func cachedMetadata(mediaFileID: Int64, contentRevision: String) -> MediaTechnicalMetadata? {
        let key = CacheKey(mediaFileID: mediaFileID, contentRevision: contentRevision)
        guard var cached = cache[key] else { return nil }
        accessCounter &+= 1
        cached.lastAccess = accessCounter
        cache[key] = cached
        return cached.metadata
    }

    func metadata(mediaFileID: Int64, contentRevision: String, sourceURL: URL) async -> MediaTechnicalMetadata {
        guard !Task.isCancelled else { return Self.unknown }
        if let cached = cachedMetadata(mediaFileID: mediaFileID, contentRevision: contentRevision) {
            return cached
        }
        guard (try? sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return Self.unknown
        }
        let key = CacheKey(mediaFileID: mediaFileID, contentRevision: contentRevision)
        let waiterID = UUID()
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: Self.unknown)
                    return
                }
                if var probe = probes[key] {
                    probe.waiters[waiterID] = continuation
                    probes[key] = probe
                    return
                }
                let probeID = UUID()
                let task = Task {
                    let result = await loadWithPermit(sourceURL)
                    finishProbe(key: key, id: probeID, result: result)
                }
                probes[key] = Probe(id: probeID, task: task, waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key) }
        }
        return Task.isCancelled ? Self.unknown : result
    }

    private func cancelWaiter(_ id: UUID, for key: CacheKey) {
        guard var probe = probes[key], let waiter = probe.waiters.removeValue(forKey: id) else { return }
        if probe.waiters.isEmpty {
            probes[key] = nil
            probe.task.cancel()
        } else {
            probes[key] = probe
        }
        waiter.resume(returning: Self.unknown)
    }

    private func finishProbe(key: CacheKey, id: UUID, result: MediaTechnicalMetadata) {
        guard let probe = probes[key], probe.id == id else { return }
        probes[key] = nil
        if result != Self.unknown { store(result, for: key) }
        for waiter in probe.waiters.values { waiter.resume(returning: result) }
    }

    private func loadWithPermit(_ url: URL) async -> MediaTechnicalMetadata {
        do { try await permits.acquire() }
        catch { return Self.unknown }
        let result: MediaTechnicalMetadata
        do {
            try Task.checkCancellation()
            result = try await withThrowingTaskGroup(of: MediaTechnicalMetadata.self) { group in
                group.addTask { [loader] in try await loader.loadMetadata(from: url) }
                group.addTask { [timeout] in
                    try await Task.sleep(for: timeout)
                    throw ProbeError.timedOut
                }
                defer { group.cancelAll() }
                guard let value = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                return value
            }
        } catch {
            result = Self.unknown
        }
        await permits.release()
        return result
    }

    private enum ProbeError: Error { case timedOut }

    private func store(_ metadata: MediaTechnicalMetadata, for key: CacheKey) {
        if cache[key] == nil, cache.count >= maximumCachedEntries,
           let leastRecentlyUsed = cache.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key {
            cache.removeValue(forKey: leastRecentlyUsed)
        }
        accessCounter &+= 1
        cache[key] = CacheEntry(metadata: metadata, lastAccess: accessCounter)
    }

    private static let unknown = MediaTechnicalMetadata(
        duration: nil, width: nil, height: nil, videoCodec: nil, audioTracks: nil
    )

}

private struct AVFoundationMetadataLoader: MediaMetadataLoading {
    func loadMetadata(from url: URL) async throws -> MediaTechnicalMetadata {
        let asset = AVURLAsset(url: url)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let metadata = try await Self.probe(asset)
            try Task.checkCancellation()
            return metadata
        } onCancel: {
            asset.cancelLoading()
        }
    }

    private static func probe(_ asset: AVURLAsset) async throws -> MediaTechnicalMetadata {
        let duration: TimeInterval?
        if let time = try? await asset.load(.duration) {
            let value = CMTimeGetSeconds(time)
            duration = value.isFinite && value >= 0 ? value : nil
        } else {
            duration = nil
        }
        try Task.checkCancellation()
        guard let tracks = try? await asset.load(.tracks) else {
            return MediaTechnicalMetadata(duration: duration, width: nil, height: nil,
                videoCodec: nil, audioTracks: nil)
        }

        try Task.checkCancellation()
        let videoTrack = tracks.first { $0.mediaType == .video }
        let audioTrackDescriptions = tracks.filter { $0.mediaType == .audio }
        var width: Int?
        var height: Int?
        var videoCodec: String?
        if let videoTrack {
            if let size = try? await videoTrack.load(.naturalSize),
               size.width.isFinite, size.height.isFinite, size.width != 0, size.height != 0 {
                width = Int(abs(size.width).rounded())
                height = Int(abs(size.height).rounded())
            }
            try Task.checkCancellation()
            if let descriptions = try? await videoTrack.load(.formatDescriptions),
               let description = descriptions.first {
                videoCodec = codecName(CMFormatDescriptionGetMediaSubType(description))
                let dimensions = CMVideoFormatDescriptionGetDimensions(description)
                if dimensions.width > 0, dimensions.height > 0 {
                    width = Int(dimensions.width)
                    height = Int(dimensions.height)
                }
            }
        }
        var audioMetadata: [MediaAudioTrackMetadata] = []
        audioMetadata.reserveCapacity(audioTrackDescriptions.count)
        for track in audioTrackDescriptions {
            try Task.checkCancellation()
            let descriptions = try? await track.load(.formatDescriptions)
            let codec = descriptions?.first.map {
                codecName(CMFormatDescriptionGetMediaSubType($0))
            } ?? nil
            audioMetadata.append(MediaAudioTrackMetadata(codec: codec))
        }
        return MediaTechnicalMetadata(duration: duration, width: width, height: height,
            videoCodec: videoCodec, audioTracks: audioMetadata)
    }

    private static func codecName(_ code: FourCharCode) -> String? {
        let bytes = (0..<4).map { shift in UInt8((code >> ((3 - shift) * 8)) & 0xff) }
        guard bytes.allSatisfy({ (0x20...0x7e).contains($0) }),
              let value = String(bytes: bytes, encoding: .ascii) else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return switch normalized {
        case "avc1", "avc3": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "vp09": "VP9"
        case "av01": "AV1"
        case "mp4a", "aac": "AAC"
        case ".mp3", "mp3": "MP3"
        case "lpcm", "sowt": "PCM"
        case "flac", "fLaC": "FLAC"
        case "ac-3": "AC-3"
        case "ec-3": "E-AC-3"
        case "Opus": "Opus"
        case "alac": "ALAC"
        default: normalized
        }
    }
}
