import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let player: PlayerModel
    @Bindable var preferences: PlaybackPreferences
    let library: MediaLibraryModel
    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingLibraryClear = false
    @State private var isChoosingPrivateFolder = false
    @State private var isChoosingArchive = false
    @State private var privateFolders: [HistoryExcludedFolder] = []
    @State private var pendingArchiveData: Data?
    @State private var importPreview: MediaLibraryImportPreview?
    @State private var isConfirmingArchiveImport = false
    @State private var importStatus: String?

    var body: some View {
        TabView {
            playbackSettings
                .tabItem { Label("settings.playback.tab", systemImage: "play.circle") }
            subtitleSettings
                .tabItem { Label("settings.subtitles.tab", systemImage: "captions.bubble") }
            dataSettings
                .tabItem { Label("settings.data.tab", systemImage: "externaldrive") }
            updateSettings
                .tabItem { Label("settings.updates.tab", systemImage: "arrow.triangle.2.circlepath") }
        }
        .frame(minWidth: 520, minHeight: 340)
        .alert("settings.clearHistory.confirmTitle", isPresented: $isConfirmingHistoryClear) {
            Button("common.cancel", role: .cancel) { }
            Button("settings.clearHistory.action", role: .destructive) {
                Task { await player.clearPlaybackHistory() }
            }
        } message: {
            Text("settings.clearHistory.confirmMessage")
        }
        .confirmationDialog("settings.clearLibrary.confirmTitle", isPresented: $isConfirmingLibraryClear,
                            titleVisibility: .visible) {
            Button("settings.clearLibrary.action", role: .destructive) {
                Task {
                    do {
                        try await player.clearLibraryRecords()
                        await library.refresh()
                        await reloadPrivateFolders()
                    } catch {
                        player.reportDataManagementError(error)
                    }
                }
            }
        } message: {
            Text("settings.clearLibrary.confirmMessage")
        }
        .confirmationDialog("settings.import.confirmTitle", isPresented: $isConfirmingArchiveImport,
                            titleVisibility: .visible) {
            Button("settings.import.apply", role: .destructive) {
                guard let pendingArchiveData else { return }
                Task {
                    do {
                        let result = try await player.importLibraryArchive(pendingArchiveData)
                        await library.refresh()
                        importStatus = String.localizedStringWithFormat(
                            NSLocalizedString("settings.import.success", comment: ""),
                            result.importedFileCount, result.unmatchedFileCount
                        )
                        self.pendingArchiveData = nil
                        importPreview = nil
                    } catch {
                        player.reportDataManagementError(error)
                    }
                }
            }
        } message: {
            if let importPreview {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("settings.import.confirmMessage", comment: ""),
                    importPreview.matchedFileCount,
                    importPreview.unmatchedFileCount,
                    importPreview.replacedRecordCount
                ))
            }
        }
        .fileImporter(isPresented: $isChoosingPrivateFolder, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            Task {
                do {
                    let urls = try result.get()
                    if let folder = urls.first {
                        try await player.setHistoryExcludedFolder(folder, excluded: true)
                        await reloadPrivateFolders()
                    }
                } catch {
                    if (error as? CocoaError)?.code == .userCancelled { return }
                    player.reportDataManagementError(error)
                }
            }
        }
        .task { await reloadPrivateFolders() }
    }

    private var playbackSettings: some View {
        Form {
            Section("settings.playback.section") {
                Toggle("settings.playback.resume", isOn: $preferences.resumeFromLastPosition)
                Toggle("settings.playback.autoNext", isOn: $preferences.automaticallyPlayNext)
                Picker("settings.playback.defaultSpeed", selection: $preferences.defaultSpeed) {
                    ForEach(PlaybackPreferences.supportedSpeeds, id: \.self) { speed in
                        Text("\(speed.formatted(.number.precision(.fractionLength(0...2))))×")
                            .tag(speed)
                    }
                }
            }
            Section {
                Label("settings.appearance.lightOnly", systemImage: "sun.max")
                    .foregroundStyle(.secondary)
            } header: {
                Text("settings.appearance.section")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var subtitleSettings: some View {
        Form {
            Section("settings.subtitles.section") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("settings.subtitles.defaultDelay")
                        Spacer()
                        Text(preferences.defaultSubtitleDelay, format: .number.precision(.fractionLength(1)))
                            .monospacedDigit()
                        Text("settings.seconds")
                    }
                    Slider(value: $preferences.defaultSubtitleDelay, in: -30...30, step: 0.5)
                        .accessibilityLabel(Text("settings.subtitles.defaultDelay"))
                        HStack {
                            Text("settings.subtitles.earlier")
                            Spacer()
                            Text("settings.subtitles.later")
                        }
                        .font(AppTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var dataSettings: some View {
        Form {
            Section("settings.data.section") {
                LabeledContent("settings.data.location") {
                    Text("settings.data.localOnly")
                }
                Button("settings.clearHistory.action", role: .destructive) {
                    isConfirmingHistoryClear = true
                }
                .disabled(!player.hasPlaybackHistoryStore)
                if let historyClearError = player.historyClearError {
                    Text(historyClearError)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            Section("settings.privacy.section") {
                Text("settings.privacy.explanation").foregroundStyle(.secondary)
                ForEach(privateFolders) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.displayName)
                            Text("\(folder.volumeName) · \(folder.relativePath)")
                                .font(AppTheme.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("settings.privacy.remove") {
                            Task {
                                do {
                                    try await player.removeHistoryExcludedFolder(folder)
                                    await reloadPrivateFolders()
                                } catch { player.reportDataManagementError(error) }
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                Button("settings.privacy.addFolder", systemImage: "folder.badge.minus") {
                    isChoosingPrivateFolder = true
                }
                .disabled(!player.hasMediaLibraryStore)
            }
            Section("settings.clearLibrary.section") {
                Text("settings.clearLibrary.description").foregroundStyle(.secondary)
                Button("settings.data.export", systemImage: "square.and.arrow.up") {
                    exportLibraryData()
                }
                .disabled(!player.hasMediaLibraryStore)
                Button("settings.data.import", systemImage: "square.and.arrow.down") {
                    importStatus = nil
                    isChoosingArchive = true
                }
                .disabled(!player.hasMediaLibraryStore)
                Button("settings.clearLibrary.action", role: .destructive) {
                    isConfirmingLibraryClear = true
                }
                .disabled(!player.hasMediaLibraryStore)
                if let importStatus {
                    Text(importStatus).foregroundStyle(.secondary)
                }
            }
            if let dataManagementError = player.dataManagementError {
                Text(dataManagementError).foregroundStyle(.red).textSelection(.enabled)
            }
            Section {
                Text("settings.data.mediaUnchanged")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .fileImporter(isPresented: $isChoosingArchive, allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            Task {
                do {
                    guard let url = try result.get().first else { return }
                    let hasScopedAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if hasScopedAccess { url.stopAccessingSecurityScopedResource() }
                    }
                    let data = try await Task.detached(priority: .userInitiated) {
                        try MediaLibraryArchive.read(from: url)
                    }.value
                    let preview = try await player.previewLibraryArchive(data)
                    pendingArchiveData = data
                    importPreview = preview
                    isConfirmingArchiveImport = true
                } catch {
                    if (error as? CocoaError)?.code == .userCancelled { return }
                    player.reportDataManagementError(error)
                }
            }
        }
    }

    private var updateSettings: some View {
        Form {
            Section("settings.updates.section") {
                LabeledContent("settings.updates.currentVersion", value: Bundle.main.releaseVersion)
                Text("settings.updates.unavailable")
                    .foregroundStyle(.secondary)
                Button("settings.updates.check") { }
                    .disabled(true)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func reloadPrivateFolders() async {
        do {
            privateFolders = try await player.historyExcludedFolders()
        } catch {
            player.reportDataManagementError(error)
        }
    }

    private func exportLibraryData() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Bomu-Media-Library.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                let data = try await player.exportLibraryArchive()
                try data.write(to: destination, options: .atomic)
            } catch {
                player.reportDataManagementError(error)
            }
        }
    }

}

private extension Bundle {
    var releaseVersion: String {
        let short = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (short, build) {
        case let (short?, build?): return "\(short) (\(build))"
        case let (short?, nil): return short
        case let (nil, build?): return build
        case (nil, nil): return "—"
        }
    }
}
