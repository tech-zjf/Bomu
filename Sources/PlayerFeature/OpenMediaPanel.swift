import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenMediaPanel {
    static func present(for player: PlayerModel) {
        guard let window = NSApp.mainWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio, .audiovisualContent]
        panel.message = String(localized: "open.message")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            player.open(url)
        }
    }
}
