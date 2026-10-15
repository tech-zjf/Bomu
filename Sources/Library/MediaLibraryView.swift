import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum LibraryDestination: String, CaseIterable, Identifiable, Hashable {
    case home
    case library
    case folders
    case favorites
    case search

    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .home: "library.nav.home"
        case .library: "library.nav.library"
        case .folders: "library.nav.folders"
        case .favorites: "library.nav.favorites"
        case .search: "library.nav.search"
        }
    }
    var symbol: String {
        switch self {
        case .home: "house"
        case .library: "square.grid.2x2"
        case .folders: "folder"
        case .favorites: "heart"
        case .search: "magnifyingglass"
        }
    }
}

private enum FolderBrowserDensity: String, CaseIterable {
    case grid
    case list
}

private extension MediaCategoryFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "library.filter.allCategories"
        case .unclassified: "library.filter.unclassified"
        case .category(let category): category.title
        }
    }
}

private extension MediaWatchedFilter {
    var title: LocalizedStringKey {
        switch self {
        case .all: "library.filter.all"
        case .unwatched: "library.filter.unwatched"
        case .watched: "library.filter.watched"
        }
    }
}


struct MediaLibraryView: View {
    let model: MediaLibraryModel
    let player: PlayerModel
    let isVisible: Bool
    let onPlay: (MediaLibraryItem) -> Void
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void
    let onShowPlayer: () -> Void
    let showSettings: () -> Void

    @State private var destination: LibraryDestination? = .home
    @State private var isChoosingFolder = false
    @State private var folderPath: [MediaLibraryDirectory] = []
    @State private var folderDensity = FolderBrowserDensity.grid
    @State private var visibleScrollTarget: String?
    @State private var folderListScrollTarget: String?
    @State private var savedScrollTargets: [String: String] = [:]
    @State private var categoryFilter: MediaCategoryFilter = .all
    @State private var watchedFilter: MediaWatchedFilter = .all

    var body: some View {
        HStack(spacing: 0) {
            MediaLibrarySidebar(
                selection: destination,
                onlineRoots: model.onlineRoots,
                offlineRoots: model.offlineRoots,
                isStorageAvailable: model.isStorageAvailable,
                onSelect: { destination = $0 },
                onOpen: open,
                onChooseFolder: chooseFolder,
                onShowSettings: showSettings
            )
            VStack(spacing: 0) {
                if model.isScanning {
                    scanProgress
                }
                if model.isStorageAvailable, let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(AppTheme.Typography.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .textSelection(.enabled)
                }
                if !model.isStorageAvailable {
                    ContentUnavailableView {
                        Label("library.storageUnavailableTitle", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text(model.errorMessage ?? String(localized: "library.unavailable"))
                    } actions: {
                        Button("open.video") { OpenMediaPanel.present(for: player) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if model.isLoading && model.roots.isEmpty {
                    ProgressView("library.loading")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    destinationContent
                }
                if let current = player.state.request, player.state.phase == .ready {
                    currentPlaybackBar(title: current.url.deletingPathExtension().lastPathComponent)
                }
            }
            .background(AppTheme.surface)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AppTheme.surface)
        .frame(minWidth: AppTheme.Layout.minimumWindowWidth,
               minHeight: AppTheme.Layout.minimumWindowHeight)
        .task { await model.refresh() }
        .fileImporter(isPresented: $isChoosingFolder, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                if let folder = urls.first { model.addFolder(folder) }
            case .failure(let error):
                model.report(error)
            }
        }
    }

    @ViewBuilder
    private var destinationContent: some View {
        switch destination ?? .home {
        case .home:
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                    pageHeader(title: "library.homeTitle", subtitle: "library.homeSubtitle")
                    mediaSection(title: "library.continueWatching", items: Array(model.continueWatching.prefix(2)),
                                 emptyKey: "library.emptyContinue", columnCount: 2, showsViewAll: true,
                                 presentation: .continueWatching)
                    mediaSection(title: "library.recentlyAdded", items: Array(model.recentlyAdded.prefix(3)),
                                 emptyKey: "library.emptyRecent", columnCount: 3,
                                 trailingNote: "library.fromThisMac", presentation: .standard)
                    if !model.offlineRoots.isEmpty { MediaLibraryOfflineSources(roots: model.offlineRoots) }
                }
                .padding(AppTheme.Layout.contentInset)
            }
        case .library:
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                    pageHeader(title: "library.nav.library", subtitle: "library.librarySubtitle")
                    filterControls
                    mediaGrid(filtered(model.availableItems))
                }
                .padding(AppTheme.Layout.contentInset)
            }
        case .folders:
            foldersContent
        case .favorites:
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                    pageHeader(title: "library.nav.favorites", subtitle: "library.favoritesSubtitle")
                    if model.favorites.isEmpty {
                        emptyState(title: "library.noFavoritesTitle", message: "library.noFavoritesMessage")
                    } else {
                        mediaGrid(model.favorites)
                    }
                }
                .padding(AppTheme.Layout.contentInset)
            }
        case .search:
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                    pageHeader(title: "library.nav.search", subtitle: "library.searchSubtitle")
                    searchField
                    if model.searchText.isEmpty {
                        ContentUnavailableView("library.searchEmptyTitle", systemImage: "magnifyingglass",
                                               description: Text("library.searchEmptyMessage"))
                    } else if model.searchResults.isEmpty {
                        ContentUnavailableView("library.noSearchResultsTitle", systemImage: "magnifyingglass",
                                               description: Text("library.noSearchResultsMessage"))
                    } else {
                        filterControls
                        mediaGrid(filtered(model.searchResults))
                    }
                }
                .padding(AppTheme.Layout.contentInset)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(AppTheme.textSecondary)
            TextField("library.searchPrompt", text: Binding(
                get: { model.searchText },
                set: { model.searchText = $0 }
            ))
            .textFieldStyle(.plain)
            .accessibilityLabel(Text("library.searchPrompt"))
        }
        .font(AppTheme.Typography.body)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(AppTheme.background, in: RoundedRectangle(cornerRadius: AppTheme.Corners.field))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Corners.field)
                .stroke(AppTheme.separator.opacity(0.8), lineWidth: 1)
        }
        .frame(maxWidth: 480)
    }

    private var filterControls: some View {
        HStack(spacing: 16) {
            Menu {
                ForEach(MediaCategoryFilter.allCases) { filter in
                    filterOption(title: filter.title, isSelected: categoryFilter == filter) {
                        categoryFilter = filter
                    }
                }
            } label: {
                filterControlLabel(title: "library.categoryFilter", selection: categoryFilter.title)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)

            Rectangle()
                .fill(AppTheme.separator)
                .frame(width: 1, height: 16)
                .accessibilityHidden(true)

            Menu {
                ForEach(MediaWatchedFilter.allCases) { filter in
                    filterOption(title: filter.title, isSelected: watchedFilter == filter) {
                        watchedFilter = filter
                    }
                }
            } label: {
                filterControlLabel(title: "library.watchedFilter", selection: watchedFilter.title)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)

            Spacer()
        }
        .accessibilityElement(children: .contain)
    }

    private func filterOption(title: LocalizedStringKey, isSelected: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func filterControlLabel(title: LocalizedStringKey,
                                    selection: LocalizedStringKey) -> some View {
        (Text(title).foregroundColor(AppTheme.textSecondary)
         + Text(verbatim: "   ")
         + Text(selection).foregroundColor(AppTheme.textPrimary))
        .font(AppTheme.Typography.filterLabel)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func filtered(_ items: [MediaLibraryItem]) -> [MediaLibraryItem] {
        MediaLibraryModel.filtering(items, category: categoryFilter, watched: watchedFilter)
    }

    private var foldersContent: some View {
        NavigationStack(path: $folderPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                    pageHeader(title: "library.nav.folders", subtitle: "library.foldersSubtitle")
                    if model.onlineRoots.isEmpty && model.offlineRoots.isEmpty {
                        emptyState(title: "library.noFoldersTitle", message: "library.noFoldersMessage")
                    }
                    ForEach(model.onlineRoots) { root in
                        let location = MediaLibraryDirectory(sourceRootID: root.id,
                            relativePath: root.relativePath, displayName: root.displayName)
                        NavigationLink(value: location) {
                            MediaLibrarySourceFolderRow(root: root)
                        }
                        .buttonStyle(.plain)
                        .id("root-\(root.id)")
                    }
                    MediaLibraryOfflineSources(roots: model.offlineRoots)
                }
                .padding(AppTheme.Layout.contentInset)
                .scrollTargetLayout()
            }
            .scrollPosition(id: $folderListScrollTarget, anchor: .top)
            .onAppear {
                folderListScrollTarget = savedScrollTargets["folder-root-list"]
            }
            .onChange(of: folderListScrollTarget) { _, target in
                guard let target else { return }
                savedScrollTargets["folder-root-list"] = target
            }
            .navigationDestination(for: MediaLibraryDirectory.self) { directory in
                folderContent(directory)
            }
        }
    }

    private func folderContent(_ directory: MediaLibraryDirectory) -> some View {
        let childDirectories = model.childDirectories(in: directory)
        let mediaItems = model.mediaItems(in: directory)
        return ScrollView {
            VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                MediaLibraryFolderBreadcrumbs(
                    root: model.roots.first { $0.id == directory.sourceRootID },
                    directory: directory,
                    path: $folderPath
                )
                HStack(alignment: .center) {
                    Text(directory.displayName).font(AppTheme.Typography.pageTitle)
                    Spacer()
                    Picker("library.folderDensity", selection: $folderDensity) {
                        Image(systemName: "square.grid.2x2")
                            .accessibilityLabel(Text("library.folderDensity.grid"))
                            .tag(FolderBrowserDensity.grid)
                        Image(systemName: "list.bullet")
                            .accessibilityLabel(Text("library.folderDensity.list"))
                            .tag(FolderBrowserDensity.list)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 92)
                }
                if childDirectories.isEmpty && mediaItems.isEmpty {
                    emptyState(title: "library.folderEmptyTitle", message: "library.folderEmptyMessage")
                } else if folderDensity == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260),
                                                  spacing: AppTheme.Layout.gridGap)],
                              spacing: AppTheme.Layout.gridGap) {
                        ForEach(childDirectories) { child in
                            NavigationLink(value: child) {
                                MediaLibraryFolderTile(directory: child)
                            }
                            .buttonStyle(.plain)
                            .id("folder-\(child.id)")
                        }
                    }
                    .scrollTargetLayout()
                    mediaGrid(mediaItems)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(childDirectories) { child in
                            NavigationLink(value: child) {
                                MediaLibraryFolderRow(directory: child)
                            }
                            .buttonStyle(.plain)
                            .id("folder-\(child.id)")
                        }
                        ForEach(mediaItems) { item in
                            MediaLibraryListRow(item: item, isPlayable: model.fileURL(for: item) != nil,
                                isVisible: isVisible, model: model, onPlay: onPlay, onContinue: onContinue,
                                onPlayFromBeginning: onPlayFromBeginning) {
                                    model.toggleFavorite(item)
                                }
                            .id("media-\(item.id)")
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .padding(AppTheme.Layout.contentInset)
        }
        .scrollPosition(id: $visibleScrollTarget, anchor: .top)
        .onAppear {
            visibleScrollTarget = savedScrollTargets[directory.id]
        }
        .onChange(of: visibleScrollTarget) { _, target in
            guard let target, let activeDirectory = folderPath.last else { return }
            savedScrollTargets[activeDirectory.id] = target
        }
        .navigationBarBackButtonHidden()
    }

    private var scanProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("library.scanProgress", comment: ""),
                    Int64(model.indexedCount),
                    Int64(model.discoveredCount)
                ))
                    .font(AppTheme.Typography.callout)
                Spacer()
                Button("library.cancelScan", action: model.cancelScan)
                    .buttonStyle(.borderless)
            }
            if !model.recentlyDiscoveredFiles.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("library.scanRecentlyFound")
                        .font(AppTheme.Typography.emphasizedCaption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(model.recentlyDiscoveredFiles.enumerated()), id: \.offset) { entry in
                        Text(entry.element)
                            .font(AppTheme.Typography.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .background(.white.opacity(0.85))
    }

    private func pageHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(AppTheme.Typography.pageTitle)
                Text(subtitle)
                    .font(AppTheme.Typography.subtitle)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button(action: chooseFolder) {
                Label("library.addFolder", systemImage: "plus")
                    .font(AppTheme.Typography.controlLabel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(AppTheme.textPrimary,
                                in: RoundedRectangle(cornerRadius: AppTheme.Corners.control))
            }
            .buttonStyle(.plain)
        }
    }

    private func mediaSection(title: LocalizedStringKey, items: [MediaLibraryItem], emptyKey: LocalizedStringKey,
                              columnCount: Int, showsViewAll: Bool = false,
                              trailingNote: LocalizedStringKey? = nil,
                              presentation: MediaLibraryCard.Presentation = .standard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(AppTheme.Typography.sectionTitle)
                Spacer()
                if showsViewAll {
                    Button("library.viewAll") { destination = .library }
                        .buttonStyle(.plain)
                        .foregroundStyle(AppTheme.textSecondary)
                } else if let trailingNote {
                    Text(trailingNote)
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            if items.isEmpty {
                Text(emptyKey).font(AppTheme.Typography.subtitle).foregroundStyle(AppTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                mediaGrid(items, columnCount: columnCount, presentation: presentation)
            }
        }
    }

    @ViewBuilder
    private func mediaGrid(_ items: [MediaLibraryItem], columnCount: Int? = nil,
                           presentation: MediaLibraryCard.Presentation = .standard) -> some View {
        if items.isEmpty {
            emptyState(title: "library.noMediaTitle", message: "library.noMediaMessage")
        } else {
            LazyVGrid(columns: gridColumns(columnCount), spacing: AppTheme.Layout.gridGap) {
                ForEach(items) { item in
                    MediaLibraryCard(item: item, model: model, isVisible: isVisible,
                                     isPlayable: model.fileURL(for: item) != nil,
                                     presentation: presentation,
                                     onPlay: onPlay, onContinue: onContinue,
                                     onPlayFromBeginning: onPlayFromBeginning)
                    .id("media-\(item.id)")
                }
            }
            .scrollTargetLayout()
        }
    }

    private func gridColumns(_ columnCount: Int?) -> [GridItem] {
        guard let columnCount else {
            return [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: AppTheme.Layout.gridGap)]
        }
        return Array(repeating: GridItem(.flexible(), spacing: AppTheme.Layout.gridGap), count: columnCount)
    }

    private func emptyState(title: LocalizedStringKey, message: LocalizedStringKey) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "film")
                .font(.system(size: 27, weight: .light))
                .foregroundStyle(AppTheme.textSecondary)
                .frame(width: 62, height: 62)
                .background(
                    AppTheme.background,
                    in: RoundedRectangle(cornerRadius: AppTheme.Corners.emptyStateIcon)
                )
                .accessibilityHidden(true)
            Text(title)
                .font(AppTheme.Typography.sectionTitle)
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .font(AppTheme.Typography.subtitle)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 310)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(15)
        .accessibilityElement(children: .combine)
    }

    private func currentPlaybackBar(title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text("library.nowPlaying").font(AppTheme.Typography.caption).foregroundStyle(.secondary)
                Text(title).font(AppTheme.Typography.emphasizedCallout).lineLimit(1)
            }
            Spacer()
            Button(action: player.togglePause) {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(Text(player.isPaused ? "player.play" : "player.pause"))
            Button("library.showPlayer", action: onShowPlayer)
                .buttonStyle(.bordered)
                .disabled(player.state.request == nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.white)
        .overlay(alignment: .top) { Rectangle().fill(.black.opacity(0.08)).frame(height: 1) }
    }

    private func chooseFolder() {
        isChoosingFolder = true
    }

    private func open(_ root: MediaSourceRoot) {
        folderPath = [MediaLibraryDirectory(
            sourceRootID: root.id,
            relativePath: root.relativePath,
            displayName: root.displayName
        )]
        destination = .folders
    }
}
