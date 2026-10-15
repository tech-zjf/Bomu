import Foundation

/// A local playback checkpoint independent of its durable storage format.
struct PlaybackHistory: Equatable, Sendable {
    let mediaFileID: Int64
    let relativePath: String
    var position: Double
    var audioTrackID: Int?
    var subtitleTrackID: Int?
    var volume: Double
    var updatedAt: Date
}

/// Identifies a file on one mounted volume and detects likely content changes with sparse samples.
struct MediaFileIdentity: Equatable, Sendable {
    let volumeID: String
    let resourceID: String
    let contentRevision: String
    let contentFingerprint: String
    let relativePath: String
    let volumeName: String
    let byteCount: Int64
    let modifiedAt: Date
}

/// The playback feature depends on checkpoint behavior, not on SQLite or GRDB.
protocol PlaybackHistoryPersisting: Sendable {
    func history(for url: URL) async throws -> PlaybackHistory?
    func save(for url: URL, position: Double, audioTrackID: Int?, subtitleTrackID: Int?,
              volume: Double, updatedAt: Date) async throws
    func clearAll() async throws
}

struct HistoryExcludedFolder: Equatable, Identifiable, Sendable {
    let volumeID: String
    let volumeName: String
    let relativePath: String
    let displayName: String

    var id: String { "\(volumeID):\(relativePath)" }
}

protocol MediaLibraryPersisting: PlaybackHistoryPersisting {
    func setHistoryExcludedFolder(_ folder: URL, excluded: Bool) async throws
    func removeHistoryExcludedFolder(_ folder: HistoryExcludedFolder) async throws
    func historyExcludedFolders() async throws -> [HistoryExcludedFolder]
    func clearLibraryRecords() async throws
    func exportArchive(settings: MediaLibraryArchive.Settings) async throws -> Data
    func previewArchiveImport(_ data: Data) async throws -> MediaLibraryImportPreview
    func importArchive(_ data: Data) async throws -> MediaLibraryImportResult
}

enum PlaybackHistoryError: LocalizedError {
    case invalidPosition
    case invalidVolume
    case identityUnavailable(String, underlying: String)
    case missingSourceRoot
    case unknownScan(String)
    case missingMediaFile(Int64)
    case invalidLibraryPreference
    case scanAlreadyRunning
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPosition:
            "Playback position must be a finite nonnegative value."
        case .invalidVolume:
            "Playback volume must be between 0 and 100."
        case .identityUnavailable(let path, let underlying):
            "Unable to identify media file at \(path): \(underlying)"
        case .missingSourceRoot:
            "The selected media folder could not be recorded."
        case .unknownScan(let scanID):
            "The library scan is no longer active: \(scanID)"
        case .missingMediaFile(let id):
            "The media file is no longer indexed: \(id)"
        case .invalidLibraryPreference:
            "The requested media library preference is not supported."
        case .scanAlreadyRunning:
            "This media folder is already being scanned."
        case .libraryUnavailable:
            "The local media library is unavailable."
        }
    }
}
