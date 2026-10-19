import SwiftUI

@main
struct BomuApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    var body: some Scene {
        Window(Brand.displayName, id: "main") {
            MainWindowView(player: lifecycle.player, library: lifecycle.mediaLibrary,
                           videoView: lifecycle.engine.videoView, nowPlaying: lifecycle.nowPlaying,
                           preferences: lifecycle.preferences, records: lifecycle.libraryRecords)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("open.video") { OpenMediaPanel.present(for: lifecycle.player) }
                    .keyboardShortcut("o")
                    .disabled(!lifecycle.player.canOpenMedia)
            }
            CommandMenu("menu.playback") {
                Button("player.togglePause") { lifecycle.player.togglePause() }
                    .keyboardShortcut(.space, modifiers: [])
                    .disabled(!lifecycle.player.canControlPlayback && lifecycle.player.state.phase != .ended)
                Button("player.back") { lifecycle.player.skip(by: -10) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                    .disabled(!lifecycle.player.canSeek)
                Button("player.forward") { lifecycle.player.skip(by: 10) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                    .disabled(!lifecycle.player.canSeek)
                Button("player.stop") { lifecycle.player.stop() }
                    .disabled(lifecycle.player.state.request == nil)
            }
        }
    }
}
