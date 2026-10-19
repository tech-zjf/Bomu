import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let player: PlayerModel
    @Bindable var preferences: PlaybackPreferences
    let records: MediaLibraryRecordOperations
    @State private var isConfirmingHistoryClear = false
    @State private var isConfirmingLibraryClear = false
    @State private var isChoosingPrivateFolder = false
    @State private var isChoosingArchive = false
    @State private var privateFolders: [HistoryExcludedFolder] = []
    @State private var importPreparation = MediaLibraryImportPreparation()
    @State private var importStatus: String?
    @State private var selectedTab = SettingsTab.playback

    private enum SettingsTab: String, CaseIterable, Identifiable {
        case appearance
        case playback
        case subtitles
        case storage
        case about

        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .appearance: "settings.appearance.section"
            case .playback: "settings.playback.tab"
            case .subtitles: "settings.subtitles.tab"
            case .storage: "settings.storage.tab"
            case .about: "settings.about.tab"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("library.nav.settings")
                        .font(AppTheme.Typography.pageTitle)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("settings.pageSubtitle")
                        .font(AppTheme.Typography.pageSubtitle)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .padding(.bottom, 20)

                HStack(spacing: 5) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            selectedTab = tab
                        } label: {
                            Text(tab.title)
                                .font(AppTheme.Typography.filterLabel)
                                .foregroundStyle(selectedTab == tab ? AppTheme.textPrimary : AppTheme.textSecondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .overlay(alignment: .bottom) {
                                    if selectedTab == tab {
                                        AppTheme.textPrimary.frame(height: 2)
                                    }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
                    }
                    Spacer(minLength: 0)
                }
                .overlay(alignment: .bottom) { AppTheme.separator.frame(height: 1) }
            }
            .padding(.horizontal, AppTheme.Layout.contentHorizontalInset)
            .padding(.top, AppTheme.Layout.contentVerticalInset)

            Group {
                switch selectedTab {
                case .appearance: appearanceSettings
                case .playback: playbackSettings
                case .subtitles: subtitleSettings
                case .storage: dataSettings
                case .about: updateSettings
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
                            importStatus = String.localizedStringWithFormat(
                                NSLocalizedString("settings.import.success", comment: ""),
                                result.importedFileCount, result.unmatchedFileCount
                            )
                        } catch {
                            player.reportDataManagementError(error)
                        }
                    }
                }
            }
        } message: {
            if let preview = importPreparation.prepared?.preview {
                Text(String.localizedStringWithFormat(
                    NSLocalizedString("settings.import.confirmMessage", comment: ""),
                    preview.matchedFileCount, preview.unmatchedFileCount, preview.replacedRecordCount
                ))
            }
        }
        .fileImporter(isPresented: $isChoosingPrivateFolder, allowedContentTypes: [.folder],
                      allowsMultipleSelection: false) { result in
            Task {
                do {
                    let urls = try result.get()
                    if let folder = urls.first {
                        try await records.excludeHistory(in: folder)
                        await reloadPrivateFolders()
                    }
                } catch {
                    if (error as? CocoaError)?.code == .userCancelled { return }
                    player.reportDataManagementError(error)
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

    private var appearanceSettings: some View {
        Form {
            Section("settings.appearance.section") {
                Label("settings.appearance.lightOnly", systemImage: "sun.max")
                    .foregroundStyle(.secondary)
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
                    isChoosingPrivateFolder = true
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
                    isChoosingArchive = true
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
        .fileImporter(isPresented: $isChoosingArchive, allowedContentTypes: [.json],
                      allowsMultipleSelection: false) { result in
            do {
                guard let url = try result.get().first else { return }
                importPreparation.prepare(from: url) { data in
                    try await player.previewLibraryArchive(data)
                }
            } catch {
                if (error as? CocoaError)?.code == .userCancelled { return }
                player.reportDataManagementError(error)
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
