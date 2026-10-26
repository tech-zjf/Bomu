import Foundation

struct MediaLibraryArchive: Codable, Sendable {
    static let maximumSize = 256 * 1_024 * 1_024

    static func read(from url: URL, maximumSize: Int = maximumSize) throws -> Data {
        try Task.checkCancellation()
        guard maximumSize >= 0 else { throw MediaLibraryArchiveError.tooLarge }

        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }

        var data = Data()
        while true {
            try Task.checkCancellation()
            let remainingCapacity = maximumSize - data.count
            let chunkSize = remainingCapacity < 64 * 1_024 ? remainingCapacity + 1 : 64 * 1_024
            let chunk = try file.read(upToCount: chunkSize) ?? Data()
            guard !chunk.isEmpty else { return data }
            guard chunk.count <= remainingCapacity else { throw MediaLibraryArchiveError.tooLarge }
            data.append(chunk)
        }
    }

    static func readForImport(from url: URL) async throws -> Data {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            let hasScopedAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
            }
            return try read(from: url)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    static func encodedData(for archive: Self, maximumSize: Int = maximumSize) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(archive)
        guard maximumSize >= 0, data.count <= maximumSize else {
            throw MediaLibraryArchiveError.tooLarge
        }
        return data
    }

    let schemaVersion: Int
    let exportedAt: Date
    let sources: [Source]
    let files: [File]
    let privateFolders: [PrivateFolder]
    let settings: Settings

    struct Source: Codable, Sendable {
        let volumeID: String
        let displayName: String
        let roots: [Root]
    }

    struct Root: Codable, Sendable {
        let relativePath: String
        let displayName: String
        let includingSubfolders: Bool
    }

    struct Membership: Codable, Sendable {
        let rootPath: String
        let isPresent: Bool
    }

    struct History: Codable, Sendable {
        let position: Double
        let audioTrackID: Int?
        let subtitleTrackID: Int?
        let volume: Double
        let updatedAt: Date
    }

    struct File: Codable, Sendable {
        let logicalID: String
        let volumeID: String
        let resourceID: String
        let contentRevision: String
        let contentFingerprint: String?
        let relativePath: String
        let byteCount: Int64
        let modifiedAt: Date
        let memberships: [Membership]
        let isFavorite: Bool
        let isWatched: Bool
        let manualCategory: MediaManualCategory?
        let history: History?
    }

    struct PrivateFolder: Codable, Sendable {
        let volumeID: String
        let relativePath: String
        let displayName: String
    }

    struct Settings: Codable, Equatable, Sendable {
        let automaticallyPlayNext: Bool
        let resumeFromLastPosition: Bool
        let defaultSpeed: Double
        let defaultSubtitleDelay: Double
    }
}

struct MediaLibraryImportPreview: Equatable, Sendable {
    let schemaVersion: Int
    let fileCount: Int
    let matchedFileCount: Int
    let unmatchedFileCount: Int
    let replacedRecordCount: Int
    let settings: MediaLibraryArchive.Settings
}

struct MediaLibraryImportResult: Equatable, Sendable {
    let importedFileCount: Int
    let unmatchedFileCount: Int
    let settings: MediaLibraryArchive.Settings
}

enum MediaLibraryArchiveError: LocalizedError {
    case tooLarge
    case unsupportedSchema(Int)
    case invalidContent(String)

    var errorDescription: String? {
        switch self {
        case .tooLarge: String(localized: "error.archiveTooLarge")
        case .unsupportedSchema(let version): String(format: NSLocalizedString("error.archiveUnsupportedSchema", comment: ""), version)
        case .invalidContent(let reason): String(format: NSLocalizedString("error.archiveInvalidContent", comment: ""), reason)
        }
    }
}
