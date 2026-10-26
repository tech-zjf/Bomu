import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let player: PlayerModel
    @Bindable var preferences: PlaybackPreferences
    let records: MediaLibraryRecordOperations
    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingLibraryClear = false
    @State private var privateFolders: [HistoryExcludedFolder] = []
    @State private var importPreparation = MediaLibraryImportPreparation()
    @State private var importStatus: String?
    let navigation: MainWindowNavigation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("library.nav.settings")
                    .font(AppTheme.Typography.pageTitle)
                    .tracking(AppTheme.Typography.pageTitleTracking)
                    .foregroundStyle(AppTheme.textPrimary)
                Text("settings.pageSubtitle")
                    .font(AppTheme.Typography.pageSubtitle)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.bottom, 24)

            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(SettingsSection.allCases) { section in
                        Button {
                            navigation.settingsSection = section
                        } label: {
                            Label {
                                Text(section.title)
                                    .font(navigation.settingsSection == section
                                          ? AppTheme.Typography.sidebarSelected
                                          : AppTheme.Typography.sidebarLabel)
                                    .lineLimit(1)
                            } icon: {
                                Image(systemName: section.symbol)
                                    .font(AppTheme.Typography.Symbol.sidebar)
                                    .frame(width: AppTheme.Layout.sidebarIconWidth)
                            }
                            .foregroundStyle(navigation.settingsSection == section ? AppTheme.textPrimary : AppTheme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: AppTheme.Layout.sidebarRowHeight, alignment: .leading)
                            .padding(.horizontal, AppTheme.Layout.sidebarRowHorizontalInset)
                            .background {
                                if navigation.settingsSection == section {
                                    RoundedRectangle(cornerRadius: AppTheme.Corners.selection)
                                        .fill(AppTheme.mutedSurface)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(navigation.settingsSection == section ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: AppTheme.Layout.settingsNavigationWidth, alignment: .leading)
                .padding(.trailing, 18)

                AppTheme.separator
                    .frame(width: 1)
                    .frame(maxHeight: .infinity)
                    .padding(.trailing, 20)

                Group {
                    switch navigation.settingsSection {
                    case .appearance: appearanceSettings
                    case .playback: playbackSettings
                    case .subtitles: subtitleSettings
                    case .storage: dataSettings
                    case .about: updateSettings
                    }
                }
                .frame(maxWidth: 820, maxHeight: .infinity, alignment: .topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
        .padding(.top, AppTheme.Layout.contentVerticalInset)
        .padding(.bottom, AppTheme.Layout.contentVerticalInset)
        .background(AppTheme.surface)
        .alert("settings.clearHistory.confirmTitle", isPresented: $isConfirmingHistoryClear) {
            Button("common.cancel", role: .cancel) { }
            Button("settings.clearHistory.action", role: .destructive) {
                Task {
                    do {
                        try await records.clearHistory()
                    } catch {
                        player.reportHistoryClearError(error)
                    }
                }
            }
        } message: {
            Text("settings.clearHistory.confirmMessage")
        }
        .confirmationDialog("settings.clearLibrary.confirmTitle", isPresented: $isConfirmingLibraryClear,
                            titleVisibility: .visible) {
            Button("settings.clearLibrary.action", role: .destructive) {
                Task {
                    do {
                        try await records.clearRecords()
                        await reloadPrivateFolders()
                    } catch {
                        player.reportDataManagementError(error)
                    }
                }
            }
        } message: {
            Text("settings.clearLibrary.confirmMessage")
        }
        .confirmationDialog("settings.import.confirmTitle", isPresented: Binding(
            get: { importPreparation.prepared != nil },
            set: { if !$0 { importPreparation.cancel() } }
        ), titleVisibility: .visible) {
            if let prepared = importPreparation.prepared {
                Button("settings.import.apply", role: .destructive) {
                    // Capture the prepared archive before the dialog dismisses its state.
                    let data = prepared.data
                    importPreparation.cancel()
                    Task {
                        do {
                            let result = try await records.importArchive(data)
                            await reloadPrivateFolders()
                            var message = String.localizedStringWithFormat(
                                NSLocalizedString("settings.import.success", comment: ""),
                                result.importedFileCount, result.unmatchedFileCount
                            )
                            if result.unmatchedFileCount > 0 {
                                message += " " + String(localized: "settings.import.retryAfterScan")
                            }
                            importStatus = message
                        } catch {
                            player.reportDataManagementError(error)
                        }
                    }
                }
            }
        } message: {
            if let preview = importPreparation.prepared?.preview {
                let summary = String.localizedStringWithFormat(
                    NSLocalizedString("settings.import.confirmMessage", comment: ""),
                    preview.matchedFileCount, preview.unmatchedFileCount, preview.replacedRecordCount
                )
                if preview.unmatchedFileCount > 0 {
                    Text(summary + " " + String(localized: "settings.import.retryAfterScan"))
                } else {
                    Text(summary)
                }
            }
        }
        .task { await reloadPrivateFolders() }
        .onDisappear { importPreparation.cancel() }
        .onChange(of: records.isWorking) { _, isWorking in
            if isWorking { importPreparation.cancel() }
        }
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
            .bomuOverlayScrollerStyle()
        }
        .formStyle(.grouped)
        .padding()
    }

    private var appearanceSettings: some View {
        Form {
            Section("settings.appearance.section") {
                Label("settings.appearance.lightOnly", systemImage: "sun.max")
                    .foregroundStyle(.secondary)
            }
            .bomuOverlayScrollerStyle()
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
                        .labelsHidden()
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
            .bomuOverlayScrollerStyle()
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
            .bomuOverlayScrollerStyle()
            Section("settings.privacy.section") {
                Text("settings.privacy.explanation").foregroundStyle(.secondary)
                ForEach(privateFolders) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(folder.displayName)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(folder.displayName)
                            Text("\(folder.volumeName) · \(folder.relativePath)")
                                .font(AppTheme.Typography.caption).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(.middle)
                                .help("\(folder.volumeName) · \(folder.relativePath)")
                        }
                        Spacer()
                        Button("settings.privacy.remove") {
                            Task {
                                do {
                                    try await records.removeHistoryExclusion(folder)
                                    await reloadPrivateFolders()
                                } catch { player.reportDataManagementError(error) }
                            }
                        }
                        .buttonStyle(.borderless)
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
                Button("settings.privacy.addFolder", systemImage: "folder.badge.minus") {
                    choosePrivateFolder()
                }
                .disabled(!player.hasMediaLibraryStore)
            }
            Section("settings.clearLibrary.section") {
                if records.isWorking { ProgressView("settings.data.working") }
                Text("settings.data.archiveDescription").foregroundStyle(.secondary)
                Button("settings.data.export", systemImage: "square.and.arrow.up") {
                    exportLibraryData()
                }
                .disabled(!player.hasMediaLibraryStore)
                Button("settings.data.import", systemImage: "square.and.arrow.down") {
                    importStatus = nil
                    importPreparation.cancel()
                    chooseArchive()
                }
                .disabled(!player.hasMediaLibraryStore)
                Button("settings.clearLibrary.action", role: .destructive) {
                    isConfirmingLibraryClear = true
                }
                .disabled(!player.hasMediaLibraryStore)
                switch importPreparation.phase {
                case .reading:
                    HStack {
                        ProgressView("settings.import.reading")
                        Spacer()
                        Button("common.cancel") { importPreparation.cancel() }
                    }
                case .failed(let message):
                    Text(message).foregroundStyle(.red).textSelection(.enabled)
                case .idle, .ready:
                    EmptyView()
                }
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
    }

    private func choosePrivateFolder() {
        presentFilePanel(contentType: .folder, choosesDirectories: true) { folder in
            Task {
                do {
                    try await records.excludeHistory(in: folder)
                    await reloadPrivateFolders()
                } catch {
                    player.reportDataManagementError(error)
                }
            }
        }
    }

    private func chooseArchive() {
        presentFilePanel(contentType: .json, choosesDirectories: false) { url in
            importPreparation.prepare(from: url) { data in
                try await player.previewLibraryArchive(data)
            }
        }
    }

    private func presentFilePanel(contentType: UTType, choosesDirectories: Bool,
                                  onChoose: @escaping (URL) -> Void) {
        let window = NSApp.mainWindow ?? NSApp.windows.first {
            $0.isVisible && $0.canBecomeMain && !($0 is NSPanel)
        }
        guard let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = choosesDirectories
        panel.canChooseFiles = !choosesDirectories
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [contentType]
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            onChoose(url)
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
            .bomuOverlayScrollerStyle()
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
                try await records.exportArchive(to: destination)
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

extension SettingsSection {
    var title: LocalizedStringKey {
        switch self {
        case .appearance: "settings.appearance.section"
        case .playback: "settings.playback.navigation"
        case .subtitles: "settings.subtitles.navigation"
        case .storage: "settings.storage.navigation"
        case .about: "settings.about.navigation"
        }
    }

    var symbol: String {
        switch self {
        case .appearance: "sun.max"
        case .playback: "play"
        case .subtitles: "captions.bubble"
        case .storage: "externaldrive"
        case .about: "info.circle"
        }
    }
}
