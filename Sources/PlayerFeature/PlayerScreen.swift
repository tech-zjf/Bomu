import AppKit
import SwiftUI

struct PlayerScreen: View {
    let player: PlayerModel
    let videoView: NSView
    let nowPlaying: NowPlayingController
    let onReturnToLibrary: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let horizontalInset: CGFloat = 24
            let detailsHeight: CGFloat = player.state.request == nil ? 0 : 74
            let availableVideoHeight = max(1, geometry.size.height - horizontalInset - detailsHeight)
            let availableVideoWidth = max(1, geometry.size.width - horizontalInset)
            let videoWidth = min(availableVideoWidth, availableVideoHeight * 16 / 9)
            let videoHeight = videoWidth * 9 / 16

            ScrollView {
                VStack(spacing: 0) {
                    playerStage
                        .frame(width: videoWidth, height: videoHeight)
                    if let request = player.state.request {
                        PlayerMediaDetails(url: request.url)
                            .padding(.horizontal, 12)
                            .padding(.top, 15)
                            .padding(.bottom, 12)
                    }
                    if let failure = player.state.commandFailure {
                        PlaybackCommandFailureNotice(failure: failure) {
                            player.dismissCommandFailure()
                        }
                        .frame(width: videoWidth)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(AppTheme.surface)
        .frame(minWidth: AppTheme.Layout.minimumWindowWidth,
               minHeight: AppTheme.Layout.minimumWindowHeight)
        .onAppear { player.prepare() }
        .onChange(of: player.state) { _, _ in nowPlaying.update() }
        .onDisappear { nowPlaying.deactivate() }
    }

    @ViewBuilder
    private var playerStage: some View {
        switch player.state.phase {
        case .idle:
            StartView { OpenMediaPanel.present(for: player) }
                .frame(maxWidth: .infinity, minHeight: 420)
                    .background(AppTheme.background, in: RoundedRectangle(cornerRadius: AppTheme.Corners.surface))
        case .opening:
            videoFrame {
                ProgressView("player.loading")
                    .controlSize(.large)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 16)
                    .background(AppTheme.playerControlBackground,
                                in: RoundedRectangle(cornerRadius: AppTheme.Corners.surface))
                    .foregroundStyle(.white)
            }
        case .ready:
            videoFrame {
                PlaybackControls(player: player, onReturnToLibrary: onReturnToLibrary) {
                    videoView.window?.toggleFullScreen(nil)
                }
            }
        case .ended:
            videoFrame {
                VStack(spacing: 14) {
                    Text("player.ended")
                        .font(.headline)
                    HStack(spacing: 10) {
                        Button(action: onReturnToLibrary) {
                            Label("library.backToLibrary", systemImage: "chevron.left")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    .white.opacity(0.14),
                                    in: RoundedRectangle(cornerRadius: AppTheme.Corners.control)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: AppTheme.Corners.control)
                                        .stroke(.white.opacity(0.22), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        Button { player.replay() } label: {
                            Label("player.replay", systemImage: "play.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(
                                    .white,
                                    in: RoundedRectangle(cornerRadius: AppTheme.Corners.control)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(20)
                .foregroundStyle(.white)
                .background(AppTheme.playerControlBackground, in: RoundedRectangle(cornerRadius: AppTheme.Corners.surface))
            }
        case .failed(let failure):
            errorFrame(failure)
        }
    }

    private func videoFrame<Overlay: View>(@ViewBuilder overlay: () -> Overlay) -> some View {
        ZStack {
            AppTheme.playerFallback
            VideoHostView(surface: videoView)
            overlay()
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Corners.player))
    }

    private func errorFrame(_ failure: PlaybackFailure) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 30, weight: .light))
                .accessibilityHidden(true)
            Text(failure.title).font(.headline)
            Text(failure.explanation)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .foregroundStyle(.white.opacity(0.75))
            if let detail = failure.detail {
                Text(detail)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: AppTheme.Corners.surface))
            }
            HStack(spacing: 10) {
                if failure.kind != .engine {
                    Button("player.retry") { player.retryCurrentMedia() }
                }
                Button("open.another") { OpenMediaPanel.present(for: player) }
                Button("library.backToLibrary", action: onReturnToLibrary)
            }
            .buttonStyle(.bordered)
            .tint(.white)
        }
        .font(.system(size: 13))
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 420)
        .foregroundStyle(.white)
        .background(AppTheme.playerFallback, in: RoundedRectangle(cornerRadius: AppTheme.Corners.player))
    }
}

private struct PlaybackCommandFailureNotice: View {
    let failure: PlaybackCommandFailure
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(failure.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(failure.explanation)
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = failure.detail {
                    Text(detail)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button("common.dismiss", action: dismiss)
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.background)
        .accessibilityElement(children: .contain)
    }
}

private struct PlayerMediaDetails: View {
    let url: URL

    private var fileSize: String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatStyle().format(Int64(size))
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let fileSize {
                metadataBadge(fileSize)
            }
            if !url.pathExtension.isEmpty {
                metadataBadge(url.pathExtension.uppercased())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func metadataBadge(_ value: String) -> some View {
        Text(value)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Corners.badge)
                    .stroke(AppTheme.separator, lineWidth: 1)
            }
    }
}
