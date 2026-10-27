import AppKit
import SwiftUI

@MainActor
private enum WelcomeArtworkResource {
    static let image = Bundle.main.image(forResource: "WelcomeLandscape")
}

extension LibraryDestination {
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

private extension MediaBrowserDensity {
    var title: LocalizedStringKey {
        switch self {
        case .comfortable: "library.browserDensity.comfortable"
        case .compact: "library.browserDensity.compact"
        }
    }
}

private enum MediaBrowserLayout: String, CaseIterable {
    case grid
    case list

    var title: LocalizedStringKey {
        switch self {
        case .grid: "library.folderDensity.grid"
        case .list: "library.folderDensity.list"
        }
    }

    var symbol: String {
        switch self {
        case .grid: "square.grid.2x2"
        case .list: "list.bullet"
        }
    }

    // Each button owns its half of the outer inset so the gray margin is clickable.
    var hitInsets: EdgeInsets {
        let inset = AppTheme.Layout.browserLayoutInset
        return EdgeInsets(top: inset, leading: self == .grid ? inset : 0,
                          bottom: inset, trailing: self == .list ? inset : 0)
    }
}

private struct MediaBrowserLayoutPicker: View {
    let title: LocalizedStringKey
    @Binding var selection: MediaBrowserLayout
    @FocusState private var focusedLayout: MediaBrowserLayout?
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MediaBrowserLayout.allCases, id: \.self) { layout in
                Button {
                    selection = layout
                } label: {
                    Image(systemName: layout.symbol)
                        .font(AppTheme.Typography.Symbol.compactAction)
                        .frame(width: AppTheme.Layout.browserLayoutButtonWidth,
                               height: AppTheme.Layout.browserLayoutButtonHeight)
                        .padding(layout.hitInsets)
                        .contentShape(Rectangle())
                }
                .buttonStyle(MediaBrowserLayoutButtonStyle(
                    isSelected: selection == layout,
                    isFocused: focusedLayout == layout,
                    insets: layout.hitInsets
                ))
                .focused($focusedLayout, equals: layout)
                .accessibilityLabel(Text(layout.title))
                .accessibilityAddTraits(selection == layout ? .isSelected : [])
                .help(Text(layout.title))
                .onMoveCommand { direction in
                    guard isEnabled else { return }
                    switch direction {
                    case .left:
                        selection = .grid
                        focusedLayout = .grid
                    case .right:
                        selection = .list
                        focusedLayout = .list
                    default:
                        break
                    }
                }
            }
        }
        .background(AppTheme.mutedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Corners.browserLayoutGroup))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .fixedSize()
    }
}

private struct MediaBrowserLayoutButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isFocused: Bool
    let insets: EdgeInsets
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AppTheme.textPrimary)
            .background {
                RoundedRectangle(cornerRadius: AppTheme.Corners.browserLayoutOption)
                    .fill(background)
                    .shadow(color: isSelected ? Color.black.opacity(1 / 15) : .clear,
                            radius: 1.5, x: 0, y: 1)
                    .padding(insets)
            }
            .overlay {
                if isFocused {
                    RoundedRectangle(cornerRadius: AppTheme.Corners.browserLayoutOption)
                        .strokeBorder(Color.accentColor, lineWidth: 2)
                        .padding(insets)
                }
            }
            .opacity(isEnabled ? 1 : 0.45)
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return AppTheme.surface }
        if isEnabled && isHovered { return AppTheme.controlHoverSurface }
        return .clear
    }
}

private struct MediaCategoryButtonStyle: ButtonStyle {
    let isSelected: Bool
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.Typography.categoryLabel)
            .foregroundStyle(isSelected ? AppTheme.surface : AppTheme.textPrimary)
            .padding(.horizontal, 12)
            .frame(minHeight: AppTheme.Layout.libraryCategoryHeight)
            .background(background, in: Capsule())
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return AppTheme.textPrimary }
        if isEnabled && isHovered { return AppTheme.controlHoverSurface }
        return .clear
    }
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

private extension MediaLibrarySortOrder {
    var title: LocalizedStringKey {
        switch self {
        case .recentlyAdded: "library.sort.recentlyAdded"
        case .name: "library.sort.name"
        case .duration: "library.sort.duration"
        }
    }
}


struct MediaLibraryView: View {
    let model: MediaLibraryModel
    let player: PlayerModel
    let preferences: PlaybackPreferences
    let records: MediaLibraryRecordOperations
    let isVisible: Bool
    let onPlay: (MediaLibraryItem) -> Void
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void
    let onShowPlayer: () -> Void

    let navigation: MainWindowNavigation
    @State private var folderPath: [MediaLibraryDirectory] = []
    @State private var folderLayout = MediaBrowserLayout.grid
    @State private var libraryLayout = MediaBrowserLayout.grid
    @State private var librarySortOrder = MediaLibrarySortOrder.recentlyAdded
    @State private var visibleScrollTarget: String?
    @State private var folderListScrollTarget: String?
    @State private var savedScrollTargets: [String: String] = [:]
    @State private var categoryFilter: MediaCategoryFilter = .all
    @State private var watchedFilter: MediaWatchedFilter = .all

    var body: some View {
        Group {
            if navigation.libraryPage != .settings && model.isStorageAvailable && !model.hasLoadedSnapshot && model.errorMessage == nil {
                ProgressView("library.loading")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showsWelcome {
                VStack(spacing: 0) {
                    GeometryReader { geometry in
                        ScrollView {
                            welcomeView
                                .frame(minHeight: geometry.size.height)
                        }
                        .bomuOverlayScrollerStyle()
                    }
                    if let current = player.state.request, player.state.phase == .ready {
                        currentPlaybackBar(title: current.url.deletingPathExtension().lastPathComponent)
                    }
                }
            } else {
                libraryShell
            }
        }
        .background(AppTheme.surface)
        .frame(minWidth: AppTheme.Layout.minimumWindowWidth,
               minHeight: AppTheme.Layout.minimumWindowHeight)
        .task { await model.refresh() }

    }

    private var showsWelcome: Bool {
        navigation.libraryPage == .destination(.home) && model.isStorageAvailable &&
            !model.isScanning && model.errorMessage == nil && model.roots.isEmpty
    }

    private var libraryShell: some View {
        HStack(spacing: 0) {
            MediaLibrarySidebar(
                selection: navigation.libraryPage.sidebarSelection,
                onlineRoots: model.onlineRoots,
                offlineRoots: model.offlineRoots,
                isStorageAvailable: model.isStorageAvailable,
                onSelect: { navigation.libraryPage = .destination($0) },
                onOpen: open,
                onChooseFolder: chooseFolder,
                onShowSettings: { navigation.showSettings() },
                isSettingsSelected: navigation.libraryPage == .settings
            )
            .focusSection()
            .disabled(model.isReplacingRecords)
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
                } else if navigation.libraryPage != .settings && model.isLoading && model.roots.isEmpty {
                    ProgressView("library.loading")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    pageContent
                        .disabled(model.isReplacingRecords)
                }
                if let notice = model.undoNotice {
                    undoNoticeBanner(notice)
                }
                if let current = player.state.request, player.state.phase == .ready {
                    currentPlaybackBar(title: current.url.deletingPathExtension().lastPathComponent)
                }
            }
            .focusSection()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var pageContent: some View {
        switch navigation.libraryPage {
        case .destination(let destination):
            destinationContent(destination)
        case .continueWatching:
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                    Button { navigation.libraryPage = .destination(.home) } label: {
                        Label("library.backToHome", systemImage: "chevron.left")
                            .font(AppTheme.Typography.controlBody)
                            .frame(minHeight: AppTheme.Layout.compactControlSize)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.textSecondary)
                    pageHeader(title: "library.continueWatching", subtitle: "library.continueSubtitle")
                    if model.continueWatching.isEmpty {
                        emptyState(title: "library.emptyContinue", message: "library.emptyContinueMessage")
                    } else {
                        mediaGrid(model.continueWatching, presentation: .continueWatching)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
                .padding(.vertical, AppTheme.Layout.contentVerticalInset)
                .bomuOverlayScrollerStyle()
            }
        case .settings:
            SettingsView(player: player, preferences: preferences, records: records, navigation: navigation)
        }
    }

    private var continueWatchingViewAllAction: (() -> Void)? {
        guard model.continueWatching.count > 2 else { return nil }
        return { navigation.libraryPage = .continueWatching }
    }

    @ViewBuilder
    private func destinationContent(_ destination: LibraryDestination) -> some View {
        switch destination {
        case .home:
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                    pageHeader(title: "library.homeTitle", subtitle: "library.homeSubtitle")
                    mediaSection(title: "library.continueWatching", items: Array(model.continueWatching.prefix(2)),
                                 emptyKey: "library.emptyContinue", columnCount: 2,
                                 onViewAll: continueWatchingViewAllAction,
                                 presentation: .continueWatching)
                    mediaSection(title: "library.recentlyAdded", items: Array(model.recentlyAdded.prefix(3)),
                                 emptyKey: "library.emptyRecent", columnCount: 3,
                                 trailingNote: "library.fromThisMac", presentation: .standard)
                    if !model.offlineRoots.isEmpty { MediaLibraryOfflineSources(roots: model.offlineRoots) }
                }
                .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
                .padding(.vertical, AppTheme.Layout.contentVerticalInset)
                .bomuOverlayScrollerStyle()
            }
        case .library:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader(title: "library.nav.library", subtitle: "library.librarySubtitle")
                    filterControls
                        .padding(.top, AppTheme.Layout.libraryToolsTopGap)
                    if librarySortOrder == .duration {
                        durationSortStatus(for: model.browsableItems)
                            .padding(.top, 8)
                    }
                    filteredMediaGrid(model.browsableItems)
                        .padding(.top, AppTheme.Layout.libraryResultsTopGap)
                }
                .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
                .padding(.vertical, AppTheme.Layout.contentVerticalInset)
                .bomuOverlayScrollerStyle()
            }
            .accessibilityIdentifier("bomu.library.results")
            .task(id: "\(librarySortOrder.id):\(categoryFilter.id):\(watchedFilter.id):\(model.catalogGeneration)") {
                guard librarySortOrder == .duration else { return }
                let matches = MediaLibraryModel.filtering(model.browsableItems,
                    category: categoryFilter, watched: watchedFilter)
                await model.loadDurationsForSort(in: matches)
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
                .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
                .padding(.vertical, AppTheme.Layout.contentVerticalInset)
                .bomuOverlayScrollerStyle()
            }
        case .search:
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    pageHeader(title: "library.nav.search", subtitle: "library.searchSubtitle")
                    searchField
                        .padding(.top, AppTheme.Layout.searchFieldTopGap)
                    Group {
                        if !model.hasSearchQuery {
                            emptyState(title: "library.searchEmptyTitle", message: "library.searchEmptyMessage",
                                       systemImage: "magnifyingglass")
                        } else {
                            searchResultsContent
                        }
                    }
                    .padding(.top, AppTheme.Layout.sectionGap)
                }
                .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
                .padding(.vertical, AppTheme.Layout.contentVerticalInset)
                .bomuOverlayScrollerStyle()
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
            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable(true)
                .onKeyPress(.space) {
                    model.searchText = ""
                    return .handled
                }
                .onKeyPress(.return) {
                    model.searchText = ""
                    return .handled
                }
                .foregroundStyle(AppTheme.textSecondary)
                .accessibilityLabel(Text("library.clearSearch"))
            }
        }
        .font(AppTheme.Typography.body)
        .padding(.horizontal, AppTheme.Layout.searchFieldHorizontalInset)
        .padding(.vertical, AppTheme.Layout.searchFieldVerticalInset)
        .background(AppTheme.searchFieldSurface, in: RoundedRectangle(cornerRadius: AppTheme.Corners.field))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Corners.field)
                .stroke(AppTheme.separator, lineWidth: 1)
        }
        .frame(maxWidth: .infinity)
    }

    private var searchResultsContent: some View {
        let results = model.searchResults
        return VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                Text("library.searchResults")
                    .font(AppTheme.Typography.sectionTitle)
                    .tracking(AppTheme.Typography.sectionTitleTracking)
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                Text(verbatim: searchResultCountText(results.count))
                    .font(AppTheme.Typography.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            if results.isEmpty {
                emptyState(title: "library.noSearchResultsTitle", message: "library.noSearchResultsMessage",
                           systemImage: "magnifyingglass")
            } else {
                mediaGrid(results)
            }
        }
    }

    private func searchResultCountText(_ count: Int) -> String {
        let key: String
        if count == 1 {
            key = "library.searchResultCount.one"
        } else {
            key = "library.searchResultCount.other"
        }
        return String.localizedStringWithFormat(
            NSLocalizedString(key, comment: "Search result count"),
            count
        )
    }

    private func undoNoticeBanner(_ notice: MediaLibraryUndoNotice) -> some View {
        HStack(spacing: 12) {
            Label(undoMessage(for: notice.kind), systemImage: "checkmark.circle.fill")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Button {
                Task { await model.undoLastPreferenceChange() }
            } label: {
                Text("common.undo")
                    .font(AppTheme.Typography.controlEmphasis)
                    .frame(minHeight: AppTheme.Layout.compactControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)

            Button(action: model.dismissUndoNotice) {
                Image(systemName: "xmark")
                    .font(AppTheme.Typography.Symbol.folderDisclosure)
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: AppTheme.Layout.compactControlSize, height: AppTheme.Layout.compactControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("common.dismiss"))
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.Corners.control))
        .overlay {
            RoundedRectangle(cornerRadius: AppTheme.Corners.control)
                .stroke(AppTheme.separator, lineWidth: 1)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    private func undoMessage(for kind: MediaLibraryUndoKind) -> LocalizedStringKey {
        switch kind {
        case .favoriteAdded: "library.undo.favoriteAdded"
        case .favoriteRemoved: "library.undo.favoriteRemoved"
        case .markedWatched: "library.undo.markedWatched"
        case .markedUnwatched: "library.undo.markedUnwatched"
        }
    }

    private var filterControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AppTheme.Layout.libraryToolsGap) {
                categoryControls
                    .fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                libraryOptions
                    .fixedSize(horizontal: true, vertical: false)
            }
            VStack(alignment: .leading, spacing: AppTheme.Layout.libraryToolsGap) {
                categoryControls
                libraryOptions
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var categoryControls: some View {
        HStack(spacing: AppTheme.Layout.libraryCategoryGap) {
            ForEach(MediaCategoryFilter.allCases) { filter in
                Button { categoryFilter = filter } label: {
                    Text(filter.title)
                }
                .buttonStyle(MediaCategoryButtonStyle(isSelected: categoryFilter == filter))
                .accessibilityAddTraits(categoryFilter == filter ? .isSelected : [])
            }
        }
    }

    private var libraryOptions: some View {
        HStack(spacing: 16) {
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

            Menu {
                ForEach(MediaLibrarySortOrder.allCases) { order in
                    filterOption(title: order.title, isSelected: librarySortOrder == order) {
                        librarySortOrder = order
                    }
                }
            } label: {
                filterControlLabel(title: "library.sort", selection: librarySortOrder.title)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)

            browserDensityMenu
            MediaBrowserLayoutPicker(title: "library.libraryDensity", selection: $libraryLayout)
        }
    }

    private var browserDensityMenu: some View {
        Menu {
            ForEach(MediaBrowserDensity.allCases) { density in
                filterOption(title: density.title, isSelected: preferences.browserDensity == density) {
                    preferences.browserDensity = density
                }
            }
        } label: {
            filterControlLabel(title: "library.browserDensity", selection: preferences.browserDensity.title)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .accessibilityLabel(Text("library.browserDensity"))
        .accessibilityValue(Text(preferences.browserDensity.title))
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
        .frame(minHeight: AppTheme.Layout.compactControlSize)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func durationSortStatus(for items: [MediaLibraryItem]) -> some View {
        if let progress = model.durationSortProgress {
            Text(String.localizedStringWithFormat(
                NSLocalizedString("library.sort.durationLoading", comment: ""),
                progress.completed, progress.total))
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.textSecondary)
        } else {
            let matches = MediaLibraryModel.filtering(items, category: categoryFilter, watched: watchedFilter)
            if model.unknownDurationCount(in: matches) > 0 {
                Text("library.sort.durationUnknownLast")
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private func filteredMediaGrid(_ items: [MediaLibraryItem]) -> some View {
        let matches = MediaLibraryModel.filtering(items, category: categoryFilter, watched: watchedFilter)
        if items.isEmpty {
            emptyState(title: "library.noMediaTitle", message: "library.noMediaMessage")
        } else if matches.isEmpty {
            emptyState(title: "library.noFilterResultsTitle", message: "library.noFilterResultsMessage",
                       action: (title: "library.clearFilters", perform: {
                categoryFilter = .all
                watchedFilter = .all
            }))
        } else {
            let sorted = MediaLibraryModel.sorting(matches, by: librarySortOrder,
                durationFacts: model.durationFacts)
            if libraryLayout == .grid {
                mediaGrid(sorted, density: preferences.browserDensity)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(sorted) { item in
                        MediaLibraryListRow(item: item, isPlayable: model.fileURL(for: item) != nil,
                            isVisible: isVisible, model: model, onPlay: onPlay, onContinue: onContinue,
                            onPlayFromBeginning: onPlayFromBeginning, density: preferences.browserDensity) {
                                Task { await model.toggleFavorite(item) }
                            }
                        .id("media-\(item.id)")
                    }
                }
                .scrollTargetLayout()
            }
        }
    }

    private var foldersContent: some View {
        NavigationStack(path: $folderPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.Layout.sectionGap) {
                    pageHeader(title: "library.nav.folders", subtitle: "library.foldersSubtitle")
                    if model.onlineRoots.isEmpty && model.offlineRoots.isEmpty {
                        emptyState(title: "library.noFoldersTitle", message: "library.noFoldersMessage")
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(model.roots) { root in
                            let location = MediaLibraryDirectory(sourceRootID: root.id,
                                relativePath: root.relativePath, displayName: root.displayName)
                            NavigationLink(value: location) {
                                MediaLibrarySourceFolderRow(root: root)
                            }
                            .buttonStyle(.plain)
                            .id("root-\(root.id)")
                        }
                    }
                    if !model.offlineRoots.isEmpty {
                        Text("library.offlineMessage")
                            .font(AppTheme.Typography.metadata)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
                .padding(.vertical, AppTheme.Layout.contentVerticalInset)
                .scrollTargetLayout()
                .bomuOverlayScrollerStyle()
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
                    directory: directory,
                    path: $folderPath
                )
                HStack(alignment: .center) {
                    Text(directory.displayName)
                        .font(AppTheme.Typography.pageTitle)
                        .tracking(AppTheme.Typography.pageTitleTracking)
                        .foregroundStyle(AppTheme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(directory.displayName)
                    Spacer()
                    browserDensityMenu
                    MediaBrowserLayoutPicker(title: "library.folderDensity", selection: $folderLayout)
                }
                if childDirectories.isEmpty && mediaItems.isEmpty {
                    emptyState(title: "library.folderEmptyTitle", message: "library.folderEmptyMessage")
                } else if folderLayout == .grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260),
                                                  spacing: AppTheme.Layout.folderGridGap)],
                              spacing: AppTheme.Layout.folderGridGap) {
                        ForEach(childDirectories) { child in
                            NavigationLink(value: child) {
                                MediaLibraryFolderTile(directory: child)
                            }
                            .buttonStyle(.plain)
                            .id("folder-\(child.id)")
                        }
                    }
                    .scrollTargetLayout()
                    mediaGrid(mediaItems, density: preferences.browserDensity)
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
                                onPlayFromBeginning: onPlayFromBeginning, density: preferences.browserDensity) {
                                    Task { await model.toggleFavorite(item) }
                                }
                            .id("media-\(item.id)")
                        }
                    }
                    .scrollTargetLayout()
                }
            }
            .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
            .padding(.vertical, AppTheme.Layout.contentVerticalInset)
            .bomuOverlayScrollerStyle()
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
                        .foregroundStyle(AppTheme.textSecondary)
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
        .background(AppTheme.surface)
    }

    private func pageHeader(title: LocalizedStringKey, subtitle: LocalizedStringKey) -> some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(AppTheme.Typography.pageTitle)
                    .tracking(AppTheme.Typography.pageTitleTracking)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(subtitle)
                    .font(AppTheme.Typography.pageSubtitle)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button(action: chooseFolder) {
                Label("library.addFolder", systemImage: "plus")
                    .font(AppTheme.Typography.controlLabel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(.white)
                    .background(AppTheme.textPrimary, in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var welcomeView: some View {
        HStack(spacing: 24) {
            welcomeCopy
            welcomeVisual
        }
        .padding(48)
        .frame(maxWidth: .infinity, minHeight: 550)
    }

    private var welcomeCopy: some View {
        VStack(alignment: .leading, spacing: 0) {
            welcomeHeading
                .padding(.bottom, 15)
            welcomePrimaryActions
            welcomeSecondaryActions
                .padding(.top, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var welcomeHeading: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("library.welcomeKicker")
                .font(AppTheme.Typography.welcomeKicker)
                .tracking(1)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.bottom, 6)
            Text("library.welcomeTitle")
                .font(AppTheme.Typography.welcomeTitle)
                .lineSpacing(AppTheme.Typography.welcomeTitleLineSpacing)
                .tracking(AppTheme.Typography.welcomeTitleTracking)
                .foregroundStyle(AppTheme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcomePrimaryActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("library.welcomeMessage")
                .font(AppTheme.Typography.subtitle)
                .lineSpacing(AppTheme.Typography.welcomeMessageLineSpacing)
                .foregroundStyle(AppTheme.textSecondary)
                .frame(maxWidth: AppTheme.Layout.welcomeMessageMaxWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 24)
            HStack(spacing: 6) {
                Button {
                    OpenMediaPanel.present(for: player)
                } label: {
                    HStack(spacing: AppTheme.Layout.welcomeActionIconGap) {
                        Image(systemName: "play.fill")
                            .accessibilityHidden(true)
                        Text("open.video")
                    }
                        .font(AppTheme.Typography.welcomeAction)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 11)
                        .foregroundStyle(.white)
                        .background(AppTheme.textPrimary, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                Button(action: chooseFolder) {
                    HStack(spacing: AppTheme.Layout.welcomeActionIconGap) {
                        Image(systemName: "folder.badge.plus")
                            .accessibilityHidden(true)
                        Text("library.addFolder")
                    }
                        .font(AppTheme.Typography.welcomeAction)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .foregroundStyle(AppTheme.textPrimary)
                        .background(AppTheme.surface, in: Capsule())
                        .overlay(Capsule().strokeBorder(AppTheme.separator))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var welcomeSecondaryActions: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 16) {
                Button {
                    navigation.showSettings()
                } label: {
                    Label("library.nav.settings", systemImage: "gearshape")
                }
                Button {
                    navigation.showSettings(section: .storage)
                } label: {
                    Label("library.restoreBackup", systemImage: "arrow.counterclockwise")
                }
            }
            .font(AppTheme.Typography.compactCaption)
            .foregroundStyle(AppTheme.textSecondary)
            .buttonStyle(.plain)
            Label("library.welcomePrivacy", systemImage: "checkmark.shield")
                .font(AppTheme.Typography.compactCaption)
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.top, 18)
        }
    }

    private var welcomeVisual: some View {
        RoundedRectangle(cornerRadius: AppTheme.Corners.welcomeVisual)
            .fill(AppTheme.welcomeVisualSurface)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    ZStack {
                        if let image = WelcomeArtworkResource.image {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: side - 2 * AppTheme.Layout.welcomeArtworkInset,
                                       height: (side - 2 * AppTheme.Layout.welcomeArtworkInset) * 0.75)
                                .clipShape(RoundedRectangle(cornerRadius: AppTheme.Corners.welcomeArtwork))
                                .overlay {
                                    RoundedRectangle(cornerRadius: AppTheme.Corners.welcomeArtwork)
                                        .strokeBorder(.white, lineWidth: 6)
                                }
                                .shadow(color: AppTheme.textPrimary.opacity(0.13), radius: 18, y: 20)
                                .rotationEffect(.degrees(-8))
                        } else {
                            Image(systemName: "photo")
                                .font(AppTheme.Typography.Symbol.welcomeFallback)
                                .foregroundStyle(AppTheme.folderRowIconForeground)
                        }

                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: AppTheme.Layout.welcomeCaptionIconGap) {
                            Image(systemName: "play.fill")
                            Text("library.welcomeVisualCaption")
                        }
                        .font(AppTheme.Typography.welcomeCaption)
                        .foregroundStyle(AppTheme.textPrimary)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .background(.white, in: RoundedRectangle(cornerRadius: AppTheme.Corners.welcomeCaption))
                        .shadow(color: AppTheme.textPrimary.opacity(0.08), radius: 15, y: 8)
                        .rotationEffect(.degrees(5))
                        .padding(.trailing, side * AppTheme.Layout.welcomeCaptionTrailingFraction)
                        .padding(.bottom, side * AppTheme.Layout.welcomeCaptionBottomFraction)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }

    private func mediaSection(title: LocalizedStringKey, items: [MediaLibraryItem], emptyKey: LocalizedStringKey,
                              columnCount: Int, onViewAll: (() -> Void)? = nil,
                              trailingNote: LocalizedStringKey? = nil,
                              presentation: MediaLibraryCard.Presentation = .standard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                Text(title)
                    .font(AppTheme.Typography.sectionTitle)
                    .tracking(AppTheme.Typography.sectionTitleTracking)
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
                if let onViewAll {
                    Button(action: onViewAll) {
                        HStack(spacing: 8) {
                            Image(systemName: "arrow.up.right")
                                .font(AppTheme.Typography.Symbol.sectionAction)
                                .frame(width: 16, height: 16)
                                .accessibilityHidden(true)
                            Text("library.viewAll")
                                .font(AppTheme.Typography.caption)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .frame(minHeight: AppTheme.Layout.compactControlSize)
                        .contentShape(Rectangle())
                    }
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
    private func mediaGrid(_ items: [MediaLibraryItem], columnCount: Int = AppTheme.Layout.mediaGridColumnCount,
                           presentation: MediaLibraryCard.Presentation = .standard,
                           density: MediaBrowserDensity = .comfortable) -> some View {
        if !items.isEmpty {
            let columnCount = density == .compact ? AppTheme.Layout.compactMediaGridColumnCount : columnCount
            let spacing = mediaGridSpacing(for: presentation, density: density)
            LazyVGrid(columns: gridColumns(columnCount, spacing: spacing.columns), spacing: spacing.rows) {
                ForEach(Array(items.enumerated()), id: \.element.id) { entry in
                    let item = entry.element
                    let menuArrowEdge: Edge = entry.offset % columnCount == columnCount - 1
                        ? .leading : .trailing
                    MediaLibraryCard(item: item, model: model, isVisible: isVisible,
                                     isPlayable: model.fileURL(for: item) != nil,
                                     presentation: presentation, menuArrowEdge: menuArrowEdge,
                                     onPlay: onPlay, onContinue: onContinue,
                                     onPlayFromBeginning: onPlayFromBeginning)
                    .id("media-\(item.id)")
                }
            }
            .scrollTargetLayout()
        }
    }

    private func gridColumns(_ columnCount: Int, spacing: CGFloat) -> [GridItem] {
        return Array(repeating: GridItem(.flexible(), spacing: spacing), count: columnCount)
    }

    private func mediaGridSpacing(for presentation: MediaLibraryCard.Presentation,
                                  density: MediaBrowserDensity) -> (columns: CGFloat, rows: CGFloat) {
        if density == .compact {
            return (AppTheme.Layout.compactMediaGridColumnGap, AppTheme.Layout.compactMediaGridRowGap)
        }
        switch presentation {
        case .continueWatching:
            return (AppTheme.Layout.continueWatchingGap, AppTheme.Layout.continueWatchingGap)
        case .standard:
            return (AppTheme.Layout.mediaGridColumnGap, AppTheme.Layout.mediaGridRowGap)
        }
    }

    private func emptyState(title: LocalizedStringKey, message: LocalizedStringKey,
                            systemImage: String = "film",
                            action: (title: LocalizedStringKey, perform: () -> Void)? = nil) -> some View {
        VStack(spacing: AppTheme.Layout.emptyStateGap) {
            Image(systemName: systemImage)
                .font(AppTheme.Typography.Symbol.emptyState)
                .foregroundStyle(AppTheme.emptyStateIconForeground)
                .frame(width: AppTheme.Layout.emptyStateIconSize,
                       height: AppTheme.Layout.emptyStateIconSize)
                .background(
                    AppTheme.mutedSurface,
                    in: RoundedRectangle(cornerRadius: AppTheme.Corners.emptyStateIcon)
                )
                .padding(.bottom, AppTheme.Layout.emptyStateIconBottomGap)
                .accessibilityHidden(true)
            Text(title)
                .font(AppTheme.Typography.sectionTitle)
                .tracking(AppTheme.Typography.sectionTitleTracking)
                .foregroundStyle(AppTheme.textPrimary)
            Text(message)
                .font(AppTheme.Typography.subtitle)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: AppTheme.Layout.emptyStateMessageMaxWidth)
            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.bordered)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppTheme.Layout.emptyStateHorizontalInset)
        .padding(.vertical, AppTheme.Layout.emptyStateVerticalInset)
        .accessibilityElement(children: .contain)
    }

    private func currentPlaybackBar(title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill").font(AppTheme.Typography.Symbol.nowPlaying)
            VStack(alignment: .leading, spacing: 2) {
                Text("library.nowPlaying").font(AppTheme.Typography.caption).foregroundStyle(AppTheme.textSecondary)
                Text(title).font(AppTheme.Typography.emphasizedCallout).lineLimit(1)
            }
            Spacer()
            Button(action: player.togglePause) {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(AppTheme.Typography.Symbol.mediaPlay)
                    .frame(width: AppTheme.Layout.toolbarControlSize, height: AppTheme.Layout.toolbarControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!player.canControlPlayback)
            .accessibilityLabel(Text(player.isPaused ? "player.play" : "player.pause"))
            .accessibilityIdentifier("bomu.playback.togglePause")
            Button("library.showPlayer", action: onShowPlayer)
                .buttonStyle(.bordered)
                .disabled(player.state.request == nil)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .background(.white)
        .overlay(alignment: .top) { AppTheme.separator.frame(height: 1) }
    }

    private func chooseFolder() {
        AddMediaFolderPanel.present(for: model)
    }

    private func open(_ root: MediaSourceRoot) {
        folderPath = [MediaLibraryDirectory(
            sourceRootID: root.id,
            relativePath: root.relativePath,
            displayName: root.displayName
        )]
        navigation.libraryPage = .destination(.folders)
    }
}
