import AppKit

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    let engine = MPVPlaybackEngine()
    let preferences = PlaybackPreferences()
    private var historyStoreStartupError: String?
    private var librarySync: MediaLibrarySyncCoordinator?
    private lazy var historyStore: PlaybackHistoryStore? = {
        do {
            return try PlaybackHistoryStore.applicationStore()
        } catch {
            historyStoreStartupError = error.localizedDescription
            return nil
        }
    }()
    lazy var player: PlayerModel = {
        PlayerModel(engine: engine, historyStore: historyStore, preferences: preferences)
    }()
    lazy var nowPlaying = NowPlayingController(player: player)
    lazy var mediaLibrary = MediaLibraryModel(
        store: historyStore,
        thumbnailCache: try? MediaThumbnailCache.applicationCache(),
        metadataProbe: MediaMetadataProbe(),
        startupError: historyStoreStartupError
    )
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let historyStore else { return }
        let library = mediaLibrary
        let coordinator = MediaLibrarySyncCoordinator(historyStore: historyStore) { [weak library] in
            await library?.refresh()
        }
        librarySync = coordinator
        coordinator.start()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        player.open(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            nowPlaying.deactivate()
            await librarySync?.stop()
            await player.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
