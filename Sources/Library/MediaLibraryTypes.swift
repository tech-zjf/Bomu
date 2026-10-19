import Foundation

struct MediaLibraryCandidate: Equatable, Sendable {
    let url: URL
    let displayName: String
    let relativePath: String
}

struct MediaLibraryScanSummary: Equatable, Sendable {
    let discoveredCount: Int
    let indexedCount: Int
    let skippedCount: Int
    let reconciledDeletions: Bool
}

struct MediaSourceRoot: Equatable, Identifiable, Sendable {
    let id: Int64
    let volumeID: String
    let volumeName: String
    let relativePath: String
    let displayName: String
    let includingSubfolders: Bool
    let lastSuccessfulScanAt: Date?
    let isOnline: Bool
}

struct MediaLibraryDirectory: Equatable, Hashable, Identifiable, Sendable {
    let sourceRootID: Int64
    let relativePath: String
    let displayName: String

    var id: String { "\(sourceRootID):\(relativePath)" }

    func navigationPathPrefix(in path: [MediaLibraryDirectory]) -> [MediaLibraryDirectory]? {
        guard let index = path.firstIndex(of: self) else { return nil }
        return Array(path.prefix(index + 1))
    }
}

struct MediaLibrarySnapshot: Sendable {
    let roots: [MediaSourceRoot]
    let itemsByRoot: [Int64: [MediaLibraryItem]]
    let directoriesByRoot: [Int64: [MediaLibraryDirectory]]
}

struct MediaLibraryItem: Equatable, Identifiable, Sendable {
    let id: Int64
    let sourceRootID: Int64
    let volumeID: String
    let relativePath: String
    let displayName: String
    let byteCount: Int64
    let contentRevision: String
    let isPresent: Bool
    let isFavorite: Bool
    let isWatched: Bool
    let hasPlaybackHistoryConflict: Bool
    let manualCategory: MediaManualCategory?
    let playbackPosition: Double
    let lastPlayedAt: Date?
    let addedAt: Date
}

enum MediaManualCategory: String, CaseIterable, Codable, Identifiable, Sendable {
    case movie
    case series
    case personal

    var id: String { rawValue }
}

struct MediaLibraryScanSession: Equatable, Sendable {
    let id: String
    let sourceRootID: Int64
}

enum MediaLibraryScanEvent: Equatable, Sendable {
    case discovered(MediaLibraryCandidate)
    case indexed(MediaLibraryCandidate, mediaFileID: Int64)
    case skipped(relativePath: String, reason: String)
    case completed(MediaLibraryScanSummary)
}

protocol MediaLibraryScanning: Sendable {
    func scan(folder root: URL, includingSubfolders: Bool) -> MediaLibraryScan
}

/** 消费者拥有扫描操作；提前结束事件消费时，必须等待后台任务取消并完成数据库收尾。 */
struct MediaLibraryScan: Sendable {
    let events: AsyncThrowingStream<MediaLibraryScanEvent, Error>
    private let task: Task<Void, Never>

    init(events: AsyncThrowingStream<MediaLibraryScanEvent, Error>, task: Task<Void, Never>) {
        self.events = events
        self.task = task
    }

    func cancelAndWait() async {
        task.cancel()
        await task.value
    }
}

enum MediaLibraryScanError: LocalizedError {
    case unavailableRoot(URL)
    case cannotEnumerate(URL)

    var errorDescription: String? {
        switch self {
        case .unavailableRoot(let url):
            "The selected folder is unavailable: \(url.path)"
        case .cannotEnumerate(let url):
            "The selected folder could not be scanned: \(url.path)"
        }
    }
}

/// Captures volume identity separately from file presence in the saved catalog.
enum MountedMediaVolumes {
    static func current() -> [String: URL] {
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []
        ) ?? []
        var mounted: [String: URL] = [:]
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]),
                  let id = values.volumeUUIDString, !id.isEmpty else { continue }
            mounted[id] = volume
        }
        return mounted
    }
}
