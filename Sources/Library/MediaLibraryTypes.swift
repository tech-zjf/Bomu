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

    func ancestors(relativeTo root: MediaSourceRoot?) -> [MediaLibraryDirectory] {
        guard root == nil || root?.id == sourceRootID else { return [] }
        let rootPath = root?.relativePath ?? ""
        let remainder: String
        if rootPath.isEmpty {
            remainder = relativePath
        } else if relativePath == rootPath {
            remainder = ""
        } else {
            let prefix = rootPath + "/"
            guard relativePath.hasPrefix(prefix) else { return [] }
            remainder = String(relativePath.dropFirst(prefix.count))
        }

        let components = remainder.split(separator: "/").map(String.init)
        return components.enumerated().map { index, component in
            let pathBelowRoot = components.prefix(index + 1).joined(separator: "/")
            let path = rootPath.isEmpty ? pathBelowRoot : "\(rootPath)/\(pathBelowRoot)"
            return MediaLibraryDirectory(sourceRootID: sourceRootID,
                relativePath: path, displayName: component)
        }
    }

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
    func scan(folder root: URL, includingSubfolders: Bool) -> AsyncThrowingStream<MediaLibraryScanEvent, Error>
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
