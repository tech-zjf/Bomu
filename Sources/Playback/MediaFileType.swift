import UniformTypeIdentifiers

enum MediaFileType {
    private static let videoExtensions: Set<String> = [
        "3g2", "3gp", "asf", "avi", "divx", "flv", "m1v", "m2t", "m2ts", "m2v", "m4v",
        "mkv", "mov", "mp2v", "mp4", "mpe", "mpeg", "mpg", "mps", "m2p", "mts", "mxf",
        "ogv", "qt", "rm", "rmvb", "tod", "ts", "vob", "webm", "wmv"
    ]
    private static let audioExtensions: Set<String> = [
        "aac", "ac3", "aif", "aiff", "alac", "amr", "ape", "caf", "dts", "eac3", "flac",
        "m4a", "m4b", "mka", "mp2", "mp3", "oga", "ogg", "opus", "ra", "wav", "weba", "wma"
    ]

    static let openPanelContentTypes: [UTType] = {
        // Match the type macOS assigns to each file. Forcing an unregistered
        // extension to conform to movie/audio creates a different dynamic type,
        // which leaves the actual file disabled in NSOpenPanel.
        let videoTypes = videoExtensions.compactMap { UTType(filenameExtension: $0) }
        let audioTypes = audioExtensions.compactMap { UTType(filenameExtension: $0) }
        return [.movie, .audio, .audiovisualContent] + videoTypes + audioTypes
    }()

    static func supports(_ url: URL) -> Bool {
        let fileExtension = url.pathExtension.lowercased()
        return videoExtensions.contains(fileExtension) || audioExtensions.contains(fileExtension)
    }

    static func isAudio(_ url: URL) -> Bool {
        audioExtensions.contains(url.pathExtension.lowercased())
    }
}
