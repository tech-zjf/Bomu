import AppKit
import Observation

enum MediaWatchedFilter: String, CaseIterable, Identifiable {
    case all
    case unwatched
    case watched

    var id: String { rawValue }
}

enum MediaLibraryUndoKind: Equatable {
    case favoriteAdded
    case favoriteRemoved
    case markedWatched
    case markedUnwatched
}

struct MediaLibraryUndoNotice: Equatable, Identifiable {
    let id: UUID
    let kind: MediaLibraryUndoKind
}

private enum MediaLibraryPreference {
    case favorite
    case watched

    func toggle(in store: PlaybackHistoryStore, mediaFileID: Int64) async throws -> Bool {
        switch self {
        case .favorite:
            return try await store.toggleFavorite(for: mediaFileID)
        case .watched:
            return try await store.toggleWatched(for: mediaFileID)
        }
    }

    func undoAction(mediaFileID: Int64, previousValue: Bool) -> MediaLibraryUndoAction {
        switch self {
        case .favorite:
            return .favorite(mediaFileID: mediaFileID, value: previousValue)
        case .watched:
            return .watched(mediaFileID: mediaFileID, value: previousValue)
        }
    }

    func undoKind(newValue: Bool) -> MediaLibraryUndoKind {
        switch self {
        case .favorite:
            return newValue ? .favoriteAdded : .favoriteRemoved
        case .watched:
            return newValue ? .markedWatched : .markedUnwatched
        }
    }
}

private enum MediaLibraryUndoAction {
    case favorite(mediaFileID: Int64, value: Bool)
    case watched(mediaFileID: Int64, value: Bool)

    func restore(in store: PlaybackHistoryStore) async throws {
        switch self {
        case .favorite(let mediaFileID, let value):
            try await store.setFavorite(value, for: mediaFileID)
        case .watched(let mediaFileID, let value):
            try await store.setWatched(value, for: mediaFileID)
        }
    }
}

enum MediaCategoryFilter: Hashable, Identifiable, CaseIterable {
    case all
    case unclassified
    case category(MediaManualCategory)

    static var allCases: [MediaCategoryFilter] {
        [.all, .unclassified] + MediaManualCategory.allCases.map(MediaCategoryFilter.category)
    }

    var id: String {
        switch self {
        case .all: "all"
        case .unclassified: "unclassified"
        case .category(let category): category.rawValue
        }
    }
}

@MainActor @Observable
final class MediaLibraryModel {
    private(set) var roots: [MediaSourceRoot] = []
    private(set) var items: [MediaLibraryItem] = []
    private(set) var itemsByRoot: [Int64: [MediaLibraryItem]] = [:]
    private(set) var directoriesByRoot: [Int64: [MediaLibraryDirectory]] = [:]
    private(set) var isLoading = false
    private(set) var isReplacingRecords = false
    private(set) var discoveredCount = 0
    private(set) var indexedCount = 0
    private(set) var recentlyDiscoveredFiles: [String] = []
    private(set) var errorMessage: String?
    private(set) var selectedItemID: Int64?
    private(set) var undoNotice: MediaLibraryUndoNotice?
    var searchText = ""

    @ObservationIgnored private let store: PlaybackHistoryStore?
    @ObservationIgnored private let thumbnailCache: MediaThumbnailCache?
    @ObservationIgnored private let metadataProbe: MediaMetadataProbe?
    @ObservationIgnored private let scanner: (any MediaLibraryScanning)?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    private var activeScanID: UUID?
    private var mountedVolumes: [String: URL] = [:]
    @ObservationIgnored private let mountedVolumeSnapshot: () -> [String: URL]
    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var preferenceMutationGeneration: UInt64 = 0
    @ObservationIgnored private var preferenceMutationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingUndo: MediaLibraryUndoAction?
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?

    init(store: PlaybackHistoryStore?, thumbnailCache: MediaThumbnailCache?,
         metadataProbe: MediaMetadataProbe? = nil, scanner: (any MediaLibraryScanning)? = nil,
         startupError: String? = nil,
         mountedVolumeSnapshot: @escaping () -> [String: URL] = MountedMediaVolumes.current) {
        self.mountedVolumeSnapshot = mountedVolumeSnapshot
        self.store = store
        self.thumbnailCache = thumbnailCache
        self.metadataProbe = metadataProbe
        if let scanner {
            self.scanner = scanner
        } else if let store {
            self.scanner = MediaLibraryScanner(historyStore: store)
        } else {
            self.scanner = nil
        }
        errorMessage = startupError
    }

    var isStorageAvailable: Bool { store != nil }
    var isScanning: Bool { activeScanID != nil }
    var hasSearchQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var onlineRoots: [MediaSourceRoot] { roots.filter(\.isOnline) }
    var offlineRoots: [MediaSourceRoot] { roots.filter { !$0.isOnline } }
    var browsableItems: [MediaLibraryItem] { items.filter(\.isPresent) }
    var favorites: [MediaLibraryItem] { browsableItems.filter(\.isFavorite) }
    var watchedItems: [MediaLibraryItem] { browsableItems.filter(\.isWatched) }
    var continueWatching: [MediaLibraryItem] {
        browsableItems.filter {
            $0.playbackPosition > 0 && !$0.isWatched && !$0.hasPlaybackHistoryConflict
        }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }
    var recentlyAdded: [MediaLibraryItem] { browsableItems.sorted { $0.addedAt > $1.addedAt } }
    var searchResults: [MediaLibraryItem] {
        let sourceRootNames = Dictionary(uniqueKeysWithValues: roots.map { ($0.id, $0.displayName) })
        return Self.matchingItems(in: browsableItems, query: searchText,
                                  sourceRootNames: sourceRootNames)
    }

    nonisolated static func matchingItems(
        in items: [MediaLibraryItem],
        query: String,
        sourceRootNames: [Int64: String] = [:]
    ) -> [MediaLibraryItem] {
        let searchTerm = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchTerm.isEmpty else { return items }

        return items.filter { item in
            if item.displayName.localizedStandardContains(searchTerm) { return true }
            if sourceRootNames[item.sourceRootID]?.localizedStandardContains(searchTerm) == true {
                return true
            }
            return item.relativePath.split(separator: "/").dropLast().contains {
                String($0).localizedStandardContains(searchTerm)
            }
        }
    }

    nonisolated static func deduplicatingItems(_ items: [MediaLibraryItem]) -> [MediaLibraryItem] {
        var positionsByID: [Int64: Int] = [:]
        var result: [MediaLibraryItem] = []
        result.reserveCapacity(items.count)

        for item in items {
            guard let position = positionsByID[item.id] else {
                positionsByID[item.id] = result.count
                result.append(item)
                continue
            }
            let existing = result[position]
            if item.isPresent && !existing.isPresent {
                result[position] = item
            } else if item.isPresent == existing.isPresent && item.addedAt < existing.addedAt {
                result[position] = item
            }
        }
        return result
    }

    nonisolated static func filtering(
        _ items: [MediaLibraryItem],
        category: MediaCategoryFilter,
        watched: MediaWatchedFilter
    ) -> [MediaLibraryItem] {
        items.filter { item in
            let matchesCategory: Bool
            switch category {
            case .all: matchesCategory = true
            case .unclassified: matchesCategory = item.manualCategory == nil
            case .category(let value): matchesCategory = item.manualCategory == value
            }
            let matchesWatched: Bool
            switch watched {
            case .all: matchesWatched = true
            case .unwatched: matchesWatched = !item.isWatched
            case .watched: matchesWatched = item.isWatched
            }
            return matchesCategory && matchesWatched
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !isShuttingDown, !isReplacingRecords else { return false }
        guard let store else {
            if errorMessage == nil { errorMessage = String(localized: "library.unavailable") }
            return false
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer {
            if refreshGeneration == generation { isLoading = false }
        }
        let mounted = mountedVolumeSnapshot()
        do {
            let snapshot = try await store.librarySnapshot(mountedVolumeIDs: Set(mounted.keys))
            guard refreshGeneration == generation else { return false }
            let loadedItems = snapshot.roots.flatMap { snapshot.itemsByRoot[$0.id] ?? [] }
            let uniqueItems = Self.deduplicatingItems(loadedItems)
            let uniqueItemIDs = Set(uniqueItems.map(\.id))
            mountedVolumes = mounted
            roots = snapshot.roots
            itemsByRoot = snapshot.itemsByRoot
            directoriesByRoot = snapshot.directoriesByRoot
            items = uniqueItems
            if let selectedItemID, !uniqueItemIDs.contains(selectedItemID) {
                self.selectedItemID = nil
            }
            errorMessage = nil
            return true
        } catch {
            guard refreshGeneration == generation else { return false }
            errorMessage = error.localizedDescription
            return false
        }
    }

    func addFolder(_ folder: URL) {
        guard !isShuttingDown, !isReplacingRecords else { return }
        guard store != nil, let scanner = self.scanner else {
            errorMessage = String(localized: "library.unavailable")
            return
        }
        let previousScan = scanTask
        previousScan?.cancel()
        let scanID = UUID()
        activeScanID = scanID
        discoveredCount = 0
        indexedCount = 0
        recentlyDiscoveredFiles = []
        errorMessage = nil
        scanTask = Task { [weak self] in
            guard let self else {
                await previousScan?.value
                return
            }
            // Accepted intent owns cleanup even when cancelled before its scanner starts.
            defer {
                if self.activeScanID == scanID {
                    self.scanTask = nil
                    self.activeScanID = nil
                    self.recentlyDiscoveredFiles = []
                }
            }
            await previousScan?.value
            guard self.activeScanID == scanID else { return }
            var scanError: Error?
            var skippedReason: String?
            if !Task.isCancelled {
                let scan = scanner.scan(folder: folder, includingSubfolders: true)
                do {
                    for try await event in scan.events {
                        try Task.checkCancellation()
                        guard self.activeScanID == scanID else { throw CancellationError() }
                        switch event {
                        case .discovered(let candidate):
                            self.discoveredCount += 1
                            self.recentlyDiscoveredFiles.append(candidate.displayName)
                            if self.recentlyDiscoveredFiles.count > 5 {
                                self.recentlyDiscoveredFiles.removeFirst(
                                    self.recentlyDiscoveredFiles.count - 5
                                )
                            }
                        case .indexed:
                            self.indexedCount += 1
                        case .skipped(_, let reason):
                            skippedReason = reason
                            self.errorMessage = reason
                        case .completed:
                            break
                        }
                    }
                } catch {
                    scanError = error
                }
                await scan.cancelAndWait()
            }
            guard self.activeScanID == scanID else { return }
            /** 用户取消扫描后仍需展示已提交的条目；刷新任务不继承已取消状态，并被持有到结束。 */
            let refresh = Task { await self.refresh() }
            _ = await refresh.value
            guard self.activeScanID == scanID else { return }
            if let scanError, !(scanError is CancellationError) {
                if case PlaybackHistoryError.scanAlreadyRunning = scanError {
                    self.errorMessage = String(localized: "library.scanAlreadyRunning")
                } else {
                    self.errorMessage = scanError.localizedDescription
                }
            } else if let skippedReason {
                self.errorMessage = skippedReason
            }
        }
    }

    func cancelScan() { scanTask?.cancel() }

    /** 记录替换期间拒绝新写入，并等待已接受的操作结束；调用方必须在成功或失败后恢复。 */
    func suspendRecordWrites() async {
        isReplacingRecords = true
        refreshGeneration += 1
        isLoading = false
        clearUndoNotice()
        let scan = scanTask
        let mutations = preferenceMutationTask
        scan?.cancel()
        await scan?.value
        await mutations?.value
        clearUndoNotice()
    }

    func resumeRecordWrites() async {
        isReplacingRecords = false
        await refresh()
    }

    func shutdown() async {
        if let shutdownTask {
            await shutdownTask.value
            return
        }
        isShuttingDown = true
        refreshGeneration += 1
        isLoading = false
        clearUndoNotice()
        let scan = scanTask
        let mutations = preferenceMutationTask
        scan?.cancel()
        let shutdown = Task<Void, Never> {
            await scan?.value
            await mutations?.value
        }
        shutdownTask = shutdown
        await shutdown.value
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }

    /// Waits for already accepted preference changes without cancelling an active scan.
    func waitForPendingPreferences() async {
        await preferenceMutationTask?.value
    }

    func select(_ item: MediaLibraryItem) {
        selectedItemID = item.id
    }

    func toggleFavorite(_ item: MediaLibraryItem) async {
        await toggle(.favorite, for: item.id)
    }

    func toggleWatched(_ item: MediaLibraryItem) async {
        await toggle(.watched, for: item.id)
    }

    func undoLastPreferenceChange() async {
        guard !isShuttingDown, !isReplacingRecords, let store, let pendingUndo else { return }
        preferenceMutationGeneration &+= 1
        let generation = preferenceMutationGeneration
        clearUndoNotice()
        let previousMutation = preferenceMutationTask
        let task = Task { [weak self] in
            await previousMutation?.value
            guard let self else { return }
            do {
                try await pendingUndo.restore(in: store)
                guard self.preferenceMutationGeneration == generation else { return }
                await self.refresh()
            } catch {
                guard self.preferenceMutationGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        preferenceMutationTask = task
        await task.value
    }

    func dismissUndoNotice() {
        clearUndoNotice()
    }

    func setCategory(_ category: MediaManualCategory?, for item: MediaLibraryItem) {
        guard !isShuttingDown, !isReplacingRecords, let store else { return }
        let previousMutation = preferenceMutationTask
        preferenceMutationTask = Task { [weak self] in
            await previousMutation?.value
            guard let self else { return }
            do {
                try await store.setManualCategory(category, for: item.id)
                await self.refresh()
            } catch {
                self.errorMessage = error.localizedDescription
            }
        }
    }

    private func toggle(_ preference: MediaLibraryPreference, for mediaFileID: Int64) async {
        guard !isShuttingDown, !isReplacingRecords, let store else { return }
        preferenceMutationGeneration &+= 1
        let generation = preferenceMutationGeneration
        clearUndoNotice()
        let previousMutation = preferenceMutationTask
        let task = Task { [weak self] in
            await previousMutation?.value
            guard let self else { return }
            do {
                let newValue = try await preference.toggle(in: store, mediaFileID: mediaFileID)
                guard self.preferenceMutationGeneration == generation else { return }
                await self.refresh()
                guard !self.isShuttingDown, !self.isReplacingRecords, self.preferenceMutationGeneration == generation else { return }
                let notice = MediaLibraryUndoNotice(
                    id: UUID(),
                    kind: preference.undoKind(newValue: newValue)
                )
                self.pendingUndo = preference.undoAction(mediaFileID: mediaFileID, previousValue: !newValue)
                self.presentUndoNotice(notice)
            } catch {
                guard self.preferenceMutationGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        preferenceMutationTask = task
        await task.value
    }

    private func presentUndoNotice(_ notice: MediaLibraryUndoNotice) {
        undoExpiryTask?.cancel()
        undoNotice = notice
        undoExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self, self.undoNotice?.id == notice.id else { return }
            self.pendingUndo = nil
            self.undoNotice = nil
            self.undoExpiryTask = nil
        }
    }

    private func clearUndoNotice() {
        undoExpiryTask?.cancel()
        undoExpiryTask = nil
        pendingUndo = nil
        undoNotice = nil
    }

    func fileURL(for item: MediaLibraryItem) -> URL? {
        guard item.isPresent, let volume = mountedVolumes[item.volumeID] else { return nil }
        return volume.appending(path: item.relativePath)
    }

    func item(matchingMediaURL url: URL) -> MediaLibraryItem? {
        let standardizedURL = url.standardizedFileURL
        let matches = browsableItems.filter { fileURL(for: $0)?.standardizedFileURL == standardizedURL }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    func items(in rootID: Int64) -> [MediaLibraryItem] { itemsByRoot[rootID] ?? [] }

    func childDirectories(in directory: MediaLibraryDirectory) -> [MediaLibraryDirectory] {
        guard let root = roots.first(where: { $0.id == directory.sourceRootID }) else { return [] }
        var children: [String: MediaLibraryDirectory] = [:]
        for child in directoriesByRoot[directory.sourceRootID] ?? [] where child.relativePath != directory.relativePath {
            guard let remainder = Self.path(child.relativePath, below: directory.relativePath) else { continue }
            let name: String
            if let separator = remainder.firstIndex(of: "/") {
                name = String(remainder[..<separator])
            } else {
                name = remainder
            }
            let childPath = directory.relativePath.isEmpty ? name : "\(directory.relativePath)/\(name)"
            children[childPath] = MediaLibraryDirectory(
                sourceRootID: root.id,
                relativePath: childPath,
                displayName: name
            )
        }
        return children.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    func mediaItems(in directory: MediaLibraryDirectory) -> [MediaLibraryItem] {
        items(in: directory.sourceRootID).filter { item in
            guard item.isPresent,
                  let remainder = Self.path(item.relativePath, below: directory.relativePath) else { return false }
            return !remainder.contains("/")
        }
    }

    func thumbnailURL(for item: MediaLibraryItem) async -> URL? {
        guard let thumbnailCache, !MediaFileType.isAudio(URL(filePath: item.relativePath)) else { return nil }
        if let cached = await thumbnailCache.cachedThumbnail(mediaFileID: item.id,
                                                             contentRevision: item.contentRevision) {
            return cached
        }
        guard let sourceURL = fileURL(for: item) else { return nil }
        return try? await thumbnailCache.thumbnail(mediaFileID: item.id,
                                                   contentRevision: item.contentRevision,
                                                   sourceURL: sourceURL)
    }

    func metadata(for item: MediaLibraryItem) async -> MediaTechnicalMetadata? {
        guard let metadataProbe else { return nil }
        guard let sourceURL = fileURL(for: item) else {
            return await metadataProbe.cachedMetadata(mediaFileID: item.id,
                contentRevision: item.contentRevision)
        }
        return await metadataProbe.metadata(mediaFileID: item.id,
            contentRevision: item.contentRevision, sourceURL: sourceURL)
    }

    private static func path(_ path: String, below parent: String) -> String? {
        guard !parent.isEmpty else { return path.isEmpty ? nil : path }
        let prefix = parent + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
