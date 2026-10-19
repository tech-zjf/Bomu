import Observation

/// Owns the asynchronous return route; a newer playback intent always wins.
@MainActor
@Observable
final class MainWindowNavigation {
    private(set) var isPlayerVisible = false
    @ObservationIgnored private var returnTask: Task<Void, Never>?

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
