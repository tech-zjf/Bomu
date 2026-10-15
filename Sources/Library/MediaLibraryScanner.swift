import Foundation

/// Streams filenames as they are found and indexes each one without destructive reconciliation.
struct MediaLibraryScanner: MediaLibraryScanning {
    private let historyStore: PlaybackHistoryStore

    init(historyStore: PlaybackHistoryStore) {
        self.historyStore = historyStore
    }

    func scan(folder root: URL, includingSubfolders: Bool = true) -> AsyncThrowingStream<MediaLibraryScanEvent, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation in
            let task = Task.detached(priority: .utility) { [historyStore] in
                var scanSession: MediaLibraryScanSession?
                var discoveredCount = 0
                var indexedCount = 0
                var skippedCount = 0
                let hasScopedAccess = root.startAccessingSecurityScopedResource()
                defer {
                    if hasScopedAccess { root.stopAccessingSecurityScopedResource() }
                }

                do {
                    let keys: Set<URLResourceKey> = [
                        .isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey
                    ]
                    let rootValues: URLResourceValues
                    do {
                        rootValues = try root.resourceValues(forKeys: keys)
                    } catch {
                        throw MediaLibraryScanError.unavailableRoot(root)
                    }
                    guard rootValues.isDirectory == true else {
                        throw MediaLibraryScanError.unavailableRoot(root)
                    }
                    let session = try await historyStore.beginScan(
                        folder: root,
                        includingSubfolders: includingSubfolders
                    )
                    scanSession = session
                    var inaccessiblePaths: [(String, String)] = []
                    guard let enumerator = FileManager.default.enumerator(
                        at: root,
                        includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles, .skipsPackageDescendants],
                        errorHandler: { url, error in
                            inaccessiblePaths.append((Self.relativePath(url, under: root), error.localizedDescription))
                            return true
                        }
                    ) else {
                        throw MediaLibraryScanError.cannotEnumerate(root)
                    }

                    let resolvedRootPath = Self.resolvedPath(root)
                    var seen = Set<String>()
                    while let url = enumerator.nextObject() as? URL {
                        try Task.checkCancellation()
                        let values: URLResourceValues
                        do {
                            values = try url.resourceValues(forKeys: keys)
                        } catch {
                            skippedCount += 1
                            try await Self.publish(
                                .skipped(relativePath: Self.relativePath(url, under: root),
                                          reason: error.localizedDescription),
                                through: continuation
                            )
                            continue
                        }
                        if values.isSymbolicLink == true,
                           !Self.isContained(Self.resolvedPath(url), in: resolvedRootPath) {
                            if values.isDirectory == true { enumerator.skipDescendants() }
                            continue
                        }
                        if values.isDirectory == true {
                            try await historyStore.indexDirectory(at: url, in: session)
                            if !includingSubfolders { enumerator.skipDescendants() }
                            continue
                        }
                        guard values.isRegularFile == true, Self.isPlayableMedia(url) else { continue }

                        let canonicalPath = url.standardizedFileURL.resolvingSymlinksInPath().path
                        guard seen.insert(canonicalPath).inserted else { continue }
                        let candidate = MediaLibraryCandidate(
                            url: url,
                            displayName: url.lastPathComponent,
                            relativePath: Self.relativePath(url, under: root)
                        )
                        discoveredCount += 1
                        try await Self.publish(.discovered(candidate), through: continuation)
                        try Task.checkCancellation()

                        do {
                            let mediaFileID = try await historyStore.indexMediaFile(at: url, in: session)
                            indexedCount += 1
                            try await Self.publish(.indexed(candidate, mediaFileID: mediaFileID), through: continuation)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            skippedCount += 1
                            try await Self.publish(
                                .skipped(relativePath: candidate.relativePath, reason: error.localizedDescription),
                                through: continuation
                            )
                        }
                    }
                    try Task.checkCancellation()
                    for (relativePath, reason) in inaccessiblePaths {
                        skippedCount += 1
                        try await Self.publish(.skipped(relativePath: relativePath, reason: reason),
                                               through: continuation)
                    }
                    let reconciledDeletions = skippedCount == 0
                    try await historyStore.finishScan(session, reconcileDeletions: reconciledDeletions,
                                                      discoveredCount: discoveredCount,
                                                      indexedCount: indexedCount,
                                                      skippedCount: skippedCount)
                    scanSession = nil
                    try await Self.publish(.completed(MediaLibraryScanSummary(
                        discoveredCount: discoveredCount,
                        indexedCount: indexedCount,
                        skippedCount: skippedCount,
                        reconciledDeletions: reconciledDeletions
                    )), through: continuation)
                    continuation.finish()
                } catch {
                    if let scanSession {
                        try? await historyStore.finishScan(scanSession, reconcileDeletions: false,
                                                          discoveredCount: discoveredCount,
                                                          indexedCount: indexedCount,
                                                          skippedCount: skippedCount,
                                                          cancelled: error is CancellationError)
                    }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func isPlayableMedia(_ url: URL) -> Bool {
        MediaFileType.supports(url)
    }

    private static func publish(
        _ event: MediaLibraryScanEvent,
        through continuation: AsyncThrowingStream<MediaLibraryScanEvent, Error>.Continuation
    ) async throws {
        while true {
            switch continuation.yield(event) {
            case .enqueued:
                return
            case .dropped:
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(10))
            case .terminated:
                throw CancellationError()
            @unknown default:
                throw CancellationError()
            }
        }
    }

    private static func relativePath(_ url: URL, under root: URL) -> String {
        let rootPath = resolvedPath(root)
        let filePath = resolvedPath(url)
        guard filePath != rootPath, isContained(filePath, in: rootPath) else {
            return url.lastPathComponent
        }
        let prefixLength = rootPath == "/" ? 1 : rootPath.count + 1
        return String(filePath.dropFirst(prefixLength))
    }

    private static func resolvedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isContained(_ path: String, in rootPath: String) -> Bool {
        if path == rootPath { return true }
        let prefix = rootPath == "/" ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix)
    }
}
