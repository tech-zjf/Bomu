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

    private var cache: [CacheKey: CacheEntry] = [:]
    private var accessCounter: UInt64 = 0
    private let maximumCachedEntries: Int
    private let permits = AsyncPermitPool(limit: 2)

    init(maximumCachedEntries: Int = 2_048) {
        self.maximumCachedEntries = min(2_048, max(1, maximumCachedEntries))
    }

    func metadata(mediaFileID: Int64, contentRevision: String, sourceURL: URL) async -> MediaTechnicalMetadata {
        let key = CacheKey(mediaFileID: mediaFileID, contentRevision: contentRevision)
        if var cached = cache[key] {
            accessCounter &+= 1
            cached.lastAccess = accessCounter
            cache[key] = cached
            return cached.metadata
        }
        guard (try? sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
              FileManager.default.fileExists(atPath: sourceURL.path),
              (try? await permits.acquire()) != nil else {
            return Self.unknown
        }
        do {
            try Task.checkCancellation()
            let result = await Self.probe(sourceURL)
            try Task.checkCancellation()
            if result != Self.unknown { store(result, for: key) }
            await permits.release()
            return result
        } catch {
            await permits.release()
            return Self.unknown
        }
    }

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

    private static func probe(_ url: URL) async -> MediaTechnicalMetadata {
        let asset = AVURLAsset(url: url)
        let duration: TimeInterval?
        if let time = try? await asset.load(.duration) {
            let value = CMTimeGetSeconds(time)
            duration = value.isFinite && value >= 0 ? value : nil
        } else {
            duration = nil
        }
        guard let tracks = try? await asset.load(.tracks) else {
            return MediaTechnicalMetadata(duration: duration, width: nil, height: nil,
                videoCodec: nil, audioTracks: nil)
        }

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
        case "ac-3": "AC-3"
        case "ec-3": "E-AC-3"
        case "Opus": "Opus"
        case "alac": "ALAC"
        default: normalized
        }
    }
}
