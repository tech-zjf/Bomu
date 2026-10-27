import SwiftUI

@main
struct BomuApp: App {
    @NSApplicationDelegateAdaptor(AppLifecycle.self) private var lifecycle

    var body: some Scene {
        Window(Brand.displayName, id: "main") {
            MainWindowView(player: lifecycle.player, library: lifecycle.mediaLibrary,
                           videoView: lifecycle.engine.videoView, nowPlaying: lifecycle.nowPlaying,
                           preferences: lifecycle.preferences, records: lifecycle.libraryRecords,
                           navigation: lifecycle.navigation)
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("menu.settings") { lifecycle.navigation.showSettings() }
                    .keyboardShortcut(",")
            }
            CommandGroup(replacing: .newItem) {
                Button("open.video") { OpenMediaPanel.present(for: lifecycle.player) }
                    .keyboardShortcut("o")
                    .disabled(!lifecycle.player.canOpenMedia)
                Button("player.appendToQueue") {
                    OpenMediaPanel.present(for: lifecycle.player, disposition: .append)
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(!lifecycle.player.canOpenMedia)
            }
            CommandMenu("menu.playback") {
                Button("player.togglePause") { lifecycle.player.togglePause() }
                    .disabled(!lifecycle.player.canControlPlayback && lifecycle.player.state.phase != .ended)
                Button("player.back") { lifecycle.player.skip(by: -10) }
                    .disabled(!lifecycle.player.canSeek)
                Button("player.forward") { lifecycle.player.skip(by: 10) }
                    .disabled(!lifecycle.player.canSeek)
                Button("player.stop") { lifecycle.player.stop() }
                    .disabled(lifecycle.player.state.request == nil)
                Button(lifecycle.player.isMuted == true ? "player.unmute" : "player.mute") {
                    lifecycle.player.toggleMute()
                }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!lifecycle.player.canToggleMute)
            }
        }
    }
}
