import Observation

enum LibraryDestination: String, CaseIterable, Identifiable, Hashable {
    case home, library, folders, favorites, search
    var id: String { rawValue }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case appearance, playback, subtitles, storage, about
    var id: String { rawValue }
}

enum LibraryPage: Equatable {
    case destination(LibraryDestination)
    case continueWatching
    case settings

    var sidebarSelection: LibraryDestination? {
        switch self {
        case .destination(let destination): destination
        case .continueWatching: .home
        case .settings: nil
        }
    }
}

/// Owns the asynchronous return route; a newer playback intent always wins.
@MainActor
@Observable
final class MainWindowNavigation {
    var libraryPage: LibraryPage = .destination(.home)
    var settingsSection: SettingsSection = .appearance
    private(set) var isPlayerVisible = false
    @ObservationIgnored private var returnTask: Task<Void, Never>?

    func showSettings(section: SettingsSection? = nil) {
        cancelPendingReturn()
        if let section { settingsSection = section }
        libraryPage = .settings
        isPlayerVisible = false
    }

    func showPlayer() {
        cancelPendingReturn()
        isPlayerVisible = true
    }

    func showLibrary(refresh: @escaping @MainActor () async -> Void) {
        guard returnTask == nil else { return }
        returnTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await refresh()
            guard !Task.isCancelled, let self else { return }
            self.isPlayerVisible = false
            self.returnTask = nil
        }
    }

    func cancelPendingReturn() {
        returnTask?.cancel()
        returnTask = nil
    }
}
