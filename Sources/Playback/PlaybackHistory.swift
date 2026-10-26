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
    let fileNumber: String
    var resourceID: String { "inode:\(fileNumber)" }
    let contentRevision: String
    let contentFingerprint: String
    let legacyContentFingerprint: String?
    let relativePath: String
    let volumeName: String
    let byteCount: Int64
    let modifiedAt: Date
}

/// Captured before opening media. A later checkpoint must never resolve a replacement
/// at the same path as the file that produced the playback snapshot.
struct PlaybackHistoryBinding: Equatable, Sendable {
    let url: URL
    let identity: MediaFileIdentity
}

struct PlaybackHistorySession: Sendable {
    let binding: PlaybackHistoryBinding
    // Identity capture is independent of checkpoint I/O: a busy database must not
    // prevent a later retry from saving against the original file version.
    let history: Result<PlaybackHistory?, any Error>
}

/// The playback feature depends on checkpoint behavior, not on SQLite or GRDB.
protocol PlaybackHistoryPersisting: Sendable {
    func openHistory(for url: URL) async throws -> PlaybackHistorySession
    func save(for binding: PlaybackHistoryBinding, position: Double, audioTrackID: Int?, subtitleTrackID: Int?,
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
    case mediaFileUnavailable(String)
    case identityUnavailable(String, underlying: String)
    case mediaFileChanged
    case ambiguousMediaIdentity
    case missingSourceRoot
    case unknownScan(String)
    case missingMediaFile(Int64)
    case invalidLibraryPreference
    case scanAlreadyRunning
    case libraryUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPosition:
            String(localized: "error.invalidPlaybackPosition")
        case .invalidVolume:
            String(localized: "error.invalidPlaybackVolume")
        case .mediaFileUnavailable(let path):
            String(format: NSLocalizedString("error.mediaFileUnavailable", comment: ""), path)
        case .identityUnavailable(let path, let underlying):
            String(format: NSLocalizedString("error.identityUnavailable", comment: ""), path, underlying)
        case .mediaFileChanged:
            String(localized: "persistence.mediaFileChanged")
        case .ambiguousMediaIdentity:
            String(localized: "error.mediaIdentityConflict")
        case .missingSourceRoot:
            String(localized: "error.missingSourceRoot")
        case .unknownScan(let scanID):
            String(format: NSLocalizedString("error.unknownScan", comment: ""), scanID)
        case .missingMediaFile(let id):
            String(format: NSLocalizedString("error.missingMediaFile", comment: ""), id)
        case .invalidLibraryPreference:
            String(localized: "error.invalidLibraryPreference")
        case .scanAlreadyRunning:
            String(localized: "error.scanAlreadyRunning")
        case .libraryUnavailable:
            String(localized: "error.libraryUnavailable")
        }
    }
}
