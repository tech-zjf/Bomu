import AppKit
import Observation

enum MediaWatchedFilter: String, CaseIterable, Identifiable {
    case all
    case unwatched
    case watched

    var id: String { rawValue }
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
    private(set) var isScanning = false
    private(set) var discoveredCount = 0
    private(set) var indexedCount = 0
    private(set) var recentlyDiscoveredFiles: [String] = []
    private(set) var errorMessage: String?
    private(set) var selectedItemID: Int64?
    var searchText = ""

    @ObservationIgnored private let store: PlaybackHistoryStore?
    @ObservationIgnored private let thumbnailCache: MediaThumbnailCache?
    @ObservationIgnored private let metadataProbe: MediaMetadataProbe?
    @ObservationIgnored private let scanner: (any MediaLibraryScanning)?
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var activeScanID: UUID?
    @ObservationIgnored private var mountedVolumes: [String: URL] = [:]
    @ObservationIgnored private var refreshGeneration = 0

    init(store: PlaybackHistoryStore?, thumbnailCache: MediaThumbnailCache?,
         metadataProbe: MediaMetadataProbe? = nil, scanner: (any MediaLibraryScanning)? = nil,
         startupError: String? = nil) {
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
    var onlineRoots: [MediaSourceRoot] { roots.filter(\.isOnline) }
    var offlineRoots: [MediaSourceRoot] { roots.filter { !$0.isOnline } }
    var availableItems: [MediaLibraryItem] { visible(items) }
    var favorites: [MediaLibraryItem] { availableItems.filter(\.isFavorite) }
    var watchedItems: [MediaLibraryItem] { availableItems.filter(\.isWatched) }
    var continueWatching: [MediaLibraryItem] {
        availableItems.filter { $0.playbackPosition > 0 && !$0.isWatched }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
    }
    var recentlyAdded: [MediaLibraryItem] { availableItems.sorted { $0.addedAt > $1.addedAt } }
    var searchResults: [MediaLibraryItem] {
        Self.matchingItems(in: availableItems, query: searchText)
    }

    nonisolated static func matchingItems(in items: [MediaLibraryItem], query: String) -> [MediaLibraryItem] {
        guard !query.isEmpty else { return items }
        return items.filter { $0.displayName.localizedStandardContains(query) }
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
        let volumes = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey], options: []
        ) ?? []
        var mounted: [String: URL] = [:]
        for volume in volumes {
            guard let values = try? volume.resourceValues(forKeys: [.volumeUUIDStringKey]),
                  let id = values.volumeUUIDString, !id.isEmpty else { continue }
            mounted[id] = volume
        }
        mountedVolumes = mounted
        do {
            let snapshot = try await store.librarySnapshot(mountedVolumeIDs: Set(mounted.keys))
            guard refreshGeneration == generation else { return false }
            let loadedItems = snapshot.roots.flatMap { snapshot.itemsByRoot[$0.id] ?? [] }
            let uniqueItems = Self.deduplicatingItems(loadedItems)
            let uniqueItemIDs = Set(uniqueItems.map(\.id))
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
        guard store != nil, let scanner = self.scanner else {
            errorMessage = String(localized: "library.unavailable")
            return
        }
        let previousScan = scanTask
        previousScan?.cancel()
        let scanID = UUID()
        activeScanID = scanID
        scanTask = Task { [weak self] in
            await previousScan?.value
            guard let self, !Task.isCancelled, self.activeScanID == scanID else { return }
            self.isScanning = true
            self.discoveredCount = 0
            self.indexedCount = 0
            self.recentlyDiscoveredFiles = []
            self.errorMessage = nil
            defer {
                if self.activeScanID == scanID {
                    self.isScanning = false
                    self.scanTask = nil
                    self.activeScanID = nil
                    self.recentlyDiscoveredFiles = []
                }
            }
            do {
                for try await event in scanner.scan(folder: folder, includingSubfolders: true) {
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
                        self.errorMessage = reason
                    case .completed:
                        break
                    }
                }
                guard !Task.isCancelled, self.activeScanID == scanID else { return }
                await self.refresh()
            } catch is CancellationError {
                if self.activeScanID == scanID { await self.refresh() }
            } catch {
                guard self.activeScanID == scanID else { return }
                if case PlaybackHistoryError.scanAlreadyRunning = error {
                    self.errorMessage = String(localized: "library.scanAlreadyRunning")
                } else {
                    self.errorMessage = error.localizedDescription
                }
                await self.refresh()
            }
        }
    }

    func cancelScan() { scanTask?.cancel() }

    func report(_ error: Error) { errorMessage = error.localizedDescription }

    func select(_ item: MediaLibraryItem) {
        selectedItemID = item.id
    }

    func toggleFavorite(_ item: MediaLibraryItem) {
        guard let store else { return }
        Task {
            do {
                try await store.toggleFavorite(for: item.id)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func toggleWatched(_ item: MediaLibraryItem) {
        guard let store else { return }
        Task {
            do {
                try await store.toggleWatched(for: item.id)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setCategory(_ category: MediaManualCategory?, for item: MediaLibraryItem) {
        guard let store else { return }
        Task {
            do {
                try await store.setManualCategory(category, for: item.id)
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func fileURL(for item: MediaLibraryItem) -> URL? {
        guard item.isPresent, let volume = mountedVolumes[item.volumeID] else { return nil }
        return volume.appending(path: item.relativePath)
    }

    func items(in rootID: Int64) -> [MediaLibraryItem] { itemsByRoot[rootID] ?? [] }

    func childDirectories(in directory: MediaLibraryDirectory) -> [MediaLibraryDirectory] {
        guard let root = roots.first(where: { $0.id == directory.sourceRootID }), root.isOnline else { return [] }
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
        guard let thumbnailCache, let sourceURL = fileURL(for: item), !MediaFileType.isAudio(sourceURL) else {
            return nil
        }
        return try? await thumbnailCache.thumbnail(mediaFileID: item.id,
                                                   contentRevision: item.contentRevision,
                                                   sourceURL: sourceURL)
    }

    func metadata(for item: MediaLibraryItem) async -> MediaTechnicalMetadata? {
        guard let metadataProbe, let sourceURL = fileURL(for: item) else { return nil }
        return await metadataProbe.metadata(mediaFileID: item.id,
            contentRevision: item.contentRevision, sourceURL: sourceURL)
    }

    private func visible(_ items: [MediaLibraryItem]) -> [MediaLibraryItem] {
        items.filter { $0.isPresent && mountedVolumes[$0.volumeID] != nil }
    }

    private static func path(_ path: String, below parent: String) -> String? {
        guard !parent.isEmpty else { return path.isEmpty ? nil : path }
        let prefix = parent + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }
}
