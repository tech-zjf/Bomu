import AppKit

@MainActor
final class AppLifecycle: NSObject, NSApplicationDelegate {
    let engine = MPVPlaybackEngine()
    lazy var player = PlayerModel(engine: engine)
    private var isTerminating = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        Task {
            await player.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
