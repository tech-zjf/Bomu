import AppKit

/// The system sheet owns this one add-source intent and its recursive-scan choice.
@MainActor
enum AddMediaFolderPanel {
    static func present(for model: MediaLibraryModel) {
        guard model.isStorageAvailable, !model.isReplacingRecords else { return }
        let window = NSApp.mainWindow ?? NSApp.windows.first {
            $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
        }
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "library.addFolder")
        panel.message = String(localized: "library.addFolderMessage")
        let includeSubfolders = NSButton(checkboxWithTitle: String(localized: "library.includeSubfolders"),
                                        target: nil, action: nil)
        includeSubfolders.state = .on
        includeSubfolders.sizeToFit()
        panel.accessoryView = includeSubfolders
        panel.isAccessoryViewDisclosed = true
        panel.beginSheetModal(for: window) { [weak model] response in
            guard response == .OK, let folder = panel.url else { return }
            model?.addFolder(folder, includingSubfolders: includeSubfolders.state == .on)
        }
    }
}
