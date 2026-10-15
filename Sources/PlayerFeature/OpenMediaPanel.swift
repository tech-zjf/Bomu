import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenMediaPanel {
    static func present(for player: PlayerModel) {
        guard let window = NSApp.mainWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaFileType.openPanelContentTypes
        panel.message = String(localized: "open.message")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            player.open(panel.urls)
        }
    }

    static func presentSubtitle(for player: PlayerModel) {
        guard let window = NSApp.mainWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "open.subtitleMessage")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            player.addExternalSubtitle(url)
        }
    }
}
