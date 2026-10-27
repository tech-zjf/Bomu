import AppKit
import UniformTypeIdentifiers

@MainActor
enum OpenMediaPanel {
    static func present(for player: PlayerModel, disposition: PlayerModel.QueueDisposition = .replace) {
        guard let window = presentationWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = MediaFileType.openPanelContentTypes
        panel.message = disposition == .append
            ? String(localized: "open.appendMessage") : String(localized: "open.message")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, !panel.urls.isEmpty else { return }
            switch disposition {
            case .replace: player.open(panel.urls)
            case .append: player.appendToQueue(panel.urls)
            }
        }
    }

    static func presentSubtitle(for player: PlayerModel, requestID: UInt64) {
        guard player.canControlPlayback, player.state.request?.id == requestID,
              let window = presentationWindow, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["srt", "ass", "ssa", "vtt", "sub", "sup", "idx"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.message = String(localized: "open.subtitleMessage")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            player.addExternalSubtitle(url, requestID: requestID)
        }
    }

    private static var presentationWindow: NSWindow? {
        if let window = NSApp.mainWindow { return window }
        // Accessibility actions can run while the app is inactive, leaving mainWindow nil.
        return NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) }
    }
}
