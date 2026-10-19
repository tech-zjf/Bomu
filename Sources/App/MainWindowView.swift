import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    let player: PlayerModel
    let library: MediaLibraryModel
    let videoView: NSView
    let nowPlaying: NowPlayingController
    let preferences: PlaybackPreferences
    let records: MediaLibraryRecordOperations

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var navigation = MainWindowNavigation()
    @State private var isDropTargeted = false
    @State private var dropResolutionTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            MediaLibraryView(
                model: library,
                player: player,
                preferences: preferences,
                records: records,
                isVisible: !navigation.isPlayerVisible,
                onPlay: open,
                onContinue: continuePlayback,
                onPlayFromBeginning: playFromBeginning,
                onShowPlayer: { navigation.showPlayer() },
            )
            .scrollIndicators(navigation.isPlayerVisible ? .hidden : .automatic)
            .opacity(navigation.isPlayerVisible ? 0 : 1)
            .allowsHitTesting(!navigation.isPlayerVisible && player.startupError == nil)
            .accessibilityHidden(navigation.isPlayerVisible || player.startupError != nil)
            .disabled(navigation.isPlayerVisible || player.startupError != nil)

            PlayerScreen(
                player: player,
                videoView: videoView,
                nowPlaying: nowPlaying,
                onReturnToLibrary: returnToLibrary
            )
                .opacity(navigation.isPlayerVisible ? 1 : 0)
                .allowsHitTesting(navigation.isPlayerVisible && player.startupError == nil)
                .accessibilityHidden(!navigation.isPlayerVisible || player.startupError != nil)
                .disabled(!navigation.isPlayerVisible || player.startupError != nil)
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: $isDropTargeted) { providers in
            receiveDrop(providers)
            return !providers.isEmpty
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: AppTheme.Corners.dropTargetOverlay)
                    .stroke(navigation.isPlayerVisible ? .white : AppTheme.textPrimary,
                            style: StrokeStyle(lineWidth: 3, dash: [10, 7]))
                    .padding(12)
                    .overlay {
                        Text("open.dropHere")
                            .font(AppTheme.Typography.headline)
                            .foregroundStyle(navigation.isPlayerVisible ? .white : AppTheme.textPrimary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(
                                dropPromptBackground,
                                in: RoundedRectangle(cornerRadius: AppTheme.Corners.surface)
                            )
                    }
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if let startupError = player.startupError {
                StartupFailureView(message: startupError)
            }
        }
        .preferredColorScheme(.light)
        .onChange(of: player.state.request?.id, initial: true) { _, requestID in
            if requestID != nil {
                navigation.showPlayer()
            }
        }
        .onChange(of: player.state.phase) { _, phase in
            if phase == .idle { returnToLibrary() }
        }
        .onChange(of: navigation.isPlayerVisible) { _, visible in
            if visible { nowPlaying.update() }
        }
        .onDisappear {
            navigation.cancelPendingReturn()
            dropResolutionTask?.cancel()
            dropResolutionTask = nil
        }
        .onOpenURL { url in open(url) }
        .alert(player.inputError == nil ? "persistence.errorTitle" : "media.importFailedTitle",
               isPresented: Binding(
                get: { player.persistenceError != nil || player.inputError != nil },
                set: {
                    if !$0 {
                        player.dismissPersistenceError()
                        player.dismissInputError()
                    }
                }
               )) {
            Button("common.ok") {
                player.dismissPersistenceError()
                player.dismissInputError()
            }
        } message: {
            Text(player.inputError ?? player.persistenceError ?? "")
        }
    }

    private func open(_ item: MediaLibraryItem) {
        guard let url = library.fileURL(for: item) else { return }
        player.open(url)
        navigation.showPlayer()
    }

    private func continuePlayback(_ item: MediaLibraryItem) {
        guard let url = library.fileURL(for: item) else { return }
        player.continuePlayback(url)
        navigation.showPlayer()
    }

    private func playFromBeginning(_ item: MediaLibraryItem) {
        guard let url = library.fileURL(for: item) else { return }
        player.playFromBeginning(url)
        navigation.showPlayer()
    }

    private func returnToLibrary() {
        navigation.showLibrary {
            try? await player.checkpointPlaybackHistory()
            guard !Task.isCancelled else { return }
            _ = await library.refresh()
            guard !Task.isCancelled else { return }
            nowPlaying.update()
        }
    }

    private var dropPromptBackground: Color {
        if reduceTransparency { return navigation.isPlayerVisible ? .black : .white }
        return navigation.isPlayerVisible ? Color.black.opacity(0.72) : Color.white.opacity(0.94)
    }

    private func open(_ url: URL) {
        player.open(url)
        navigation.showPlayer()
    }

    private func receiveDrop(_ providers: [NSItemProvider]) {
        guard let intent = player.beginInputResolution() else { return }
        dropResolutionTask?.cancel()
        dropResolutionTask = Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                guard !Task.isCancelled else { return }
                if let url = await Self.fileURL(from: provider) { urls.append(url) }
            }
            guard !Task.isCancelled else { return }
            player.open(urls, for: intent)
            dropResolutionTask = nil
        }
    }

    private static func fileURL(from provider: NSItemProvider) async -> URL? {
        await FileURLProviderRequest().load(from: provider)
    }
}

/// Coordinates NSItemProvider's callback and Progress with Swift task cancellation.
@MainActor
final class FileURLProviderRequest {
    private var continuation: CheckedContinuation<URL?, Never>?
    private var progress: Progress?
    private var isFinished = false

    func load(from provider: NSItemProvider) async -> URL? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
                guard !isFinished else {
                    continuation.resume(returning: nil)
                    return
                }
                self.continuation = continuation
                progress = provider.loadObject(ofClass: NSURL.self) { [weak self] item, _ in
                    let url = (item as? NSURL).map { $0 as URL }
                    Task { @MainActor [weak self] in
                        self?.finish(url?.isFileURL == true ? url : nil)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func finish(_ url: URL?) {
        guard !isFinished else { return }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        progress = nil
        continuation?.resume(returning: url)
    }

    private func cancel() {
        guard !isFinished else { return }
        isFinished = true
        let progress = self.progress
        self.progress = nil
        let continuation = self.continuation
        self.continuation = nil
        progress?.cancel()
        continuation?.resume(returning: nil)
    }
}

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(AppTheme.Typography.Symbol.startupFailure)
                .frame(width: 62, height: 62)
                .background(AppTheme.surface,
                            in: RoundedRectangle(cornerRadius: AppTheme.Corners.emptyStateIcon))
                .accessibilityHidden(true)
            Text("app.startupFailed")
                .font(AppTheme.Typography.sectionTitle)
            Text("app.relaunchInstruction")
                .font(AppTheme.Typography.body)
                .foregroundStyle(AppTheme.textSecondary)
            Text(verbatim: message)
                .font(AppTheme.Typography.diagnostic)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 520)
            Button("app.quit") { NSApp.terminate(nil) }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.textPrimary)
                .keyboardShortcut(.defaultAction)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(AppTheme.textPrimary)
        .background(AppTheme.mutedSurface)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
    }
}
