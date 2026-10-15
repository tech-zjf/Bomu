import Foundation

enum MediaTechnicalMetadataText {
    static func value(metadata: MediaTechnicalMetadata, isAudio: Bool) -> String {
        let attributes = knownAttributes(metadata: metadata, isAudio: isAudio)
        guard !attributes.isEmpty else { return String(localized: "library.metadata.unknown") }
        return attributes.joined(separator: " · ")
    }

    static func accessibilityValue(metadata: MediaTechnicalMetadata, isAudio: Bool) -> String? {
        let attributes = knownAttributes(metadata: metadata, isAudio: isAudio)
        guard !attributes.isEmpty else { return nil }
        return attributes.joined(separator: " · ")
    }

    static func cardValue(metadata: MediaTechnicalMetadata, isAudio: Bool) -> String? {
        var attributes: [String] = []
        if let duration = durationLabel(metadata.duration) {
            attributes.append(duration)
        }
        if isAudio {
            if let tracks = metadata.audioTracks, !tracks.isEmpty {
                let codecs = Array(Set(tracks.compactMap(\.codec))).sorted()
                attributes.append(contentsOf: codecs)
            }
        } else {
            if let width = metadata.width, let height = metadata.height {
                attributes.append("\(width) × \(height)")
            }
            if let codec = metadata.videoCodec {
                attributes.append(codec)
            }
        }
        guard !attributes.isEmpty else { return nil }
        return attributes.joined(separator: " · ")
    }

    static func cardValueOrFileSize(
        metadata: MediaTechnicalMetadata?,
        byteCount: Int64,
        isAudio: Bool
    ) -> String {
        guard let metadata,
              let value = cardValue(metadata: metadata, isAudio: isAudio) else {
            return ByteCountFormatStyle().format(byteCount)
        }
        return value
    }

    private static func knownAttributes(metadata: MediaTechnicalMetadata, isAudio: Bool) -> [String] {
        var attributes: [String] = []
        if let duration = durationLabel(metadata.duration) {
            attributes.append(duration)
        }
        if isAudio {
            if let audio = audioSummary(metadata.audioTracks) {
                attributes.append(audio)
            }
        } else {
            if let width = metadata.width, let height = metadata.height {
                attributes.append("\(width) × \(height)")
            }
            if let videoCodec = metadata.videoCodec {
                attributes.append(videoCodec)
            }
            if let audio = audioSummary(metadata.audioTracks) {
                attributes.append(audio)
            }
        }
        return attributes
    }

    static func durationLabel(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds.isFinite, (0..<1_000_000_000_000).contains(seconds) else {
            return nil
        }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3_600
        let minutes = (total / 60) % 60
        let remainingSeconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", total / 60, remainingSeconds)
    }

    private static func audioSummary(_ tracks: [MediaAudioTrackMetadata]?) -> String? {
        guard let tracks else { return nil }
        guard !tracks.isEmpty else { return String(localized: "library.metadata.noAudio") }
        if tracks.count == 1 {
            return String(localized: "library.metadata.oneAudioTrack")
        }
        let trackText = String.localizedStringWithFormat(
            NSLocalizedString("library.metadata.audioTracks", comment: ""), tracks.count
        )
        var seenCodecs: Set<String> = []
        let codecs = tracks.compactMap(\.codec).filter { seenCodecs.insert($0).inserted }
        guard !codecs.isEmpty else { return trackText }
        return "\(trackText) · \(codecs.joined(separator: ", "))"
    }

}
