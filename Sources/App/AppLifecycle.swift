import AppKit

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    let navigation = MainWindowNavigation()
    let engine = MPVPlaybackEngine()
    let preferences = PlaybackPreferences()
    private let mediaWorkPermits = AsyncPermitPool(limit: 2)
    private var mediaWorkloadTask: Task<Void, Never>?
    private var historyStoreStartupError: String?
    private lazy var librarySync: MediaLibrarySyncCoordinator? = {
        guard let historyStore else { return nil }
        let library = mediaLibrary
        return MediaLibrarySyncCoordinator(historyStore: historyStore) { [weak library] in
            await library?.refresh()
        }
    }()
    private lazy var historyStore: PlaybackHistoryStore? = {
        do {
            return try PlaybackHistoryStore.applicationStore()
        } catch {
            historyStoreStartupError = error.localizedDescription
            return nil
        }
    }()
    lazy var player: PlayerModel = {
        PlayerModel(engine: engine, historyStore: historyStore, preferences: preferences,
                    onPlaybackActivityChanged: { [weak self] active in
                        self?.setPlaybackActivity(active)
                    })
    }()
    lazy var nowPlaying = NowPlayingController(player: player)
    lazy var mediaLibrary = MediaLibraryModel(
        store: historyStore,
        thumbnailCache: try? MediaThumbnailCache.applicationCache(sharedPermits: mediaWorkPermits),
        metadataProbe: MediaMetadataProbe(sharedPermits: mediaWorkPermits),
        startupError: historyStoreStartupError
    )
    lazy var libraryRecords = MediaLibraryRecordOperations(
        library: mediaLibrary, sync: librarySync, player: player
    )
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        librarySync?.start()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        player.open(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await mediaWorkloadTask?.value
            nowPlaying.shutdown()
            await libraryRecords.shutdown()
            await librarySync?.stop()
            await mediaLibrary.shutdown()
            await player.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
    private func setPlaybackActivity(_ active: Bool) {
        guard !isTerminating else { return }
        let previous = mediaWorkloadTask
        mediaWorkloadTask = Task { [mediaWorkPermits] in
            await previous?.value
            await mediaWorkPermits.setLimit(active ? 1 : 2)
        }
    }
}
