import AppKit
import SwiftUI

struct PlayerScreen: View {
    let player: PlayerModel
    let videoView: NSView
    let nowPlaying: NowPlayingController
    let isFavorite: Bool
    let canToggleFavorite: Bool
    let onToggleFavorite: () -> Void
    let onReturnToLibrary: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        GeometryReader { geometry in
            PlayerPageLayout(availableHeight: geometry.size.height,
                             stageInset: AppTheme.Layout.playerStageInset) {
                playerStage
                playerFooter
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
            EmptyPlayerView { OpenMediaPanel.present(for: player) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(AppTheme.mutedSurface, in: RoundedRectangle(cornerRadius: AppTheme.Corners.surface))
        case .opening:
            videoFrame {
                VStack(spacing: 14) {
                    ProgressView("player.loading")
                        .controlSize(.large)
                    Button("common.cancel") { player.stop() }
                        .buttonStyle(.bordered)
                        .font(AppTheme.Typography.controlBody)
                }
                .padding(.horizontal, AppTheme.Layout.playerHorizontalInset)
                .padding(.vertical, 16)
                .background(AppTheme.playerControlBackground(reduceTransparency: reduceTransparency),
                            in: RoundedRectangle(cornerRadius: AppTheme.Corners.surface))
                .foregroundStyle(.white)
                .environment(\.colorScheme, .dark)
            }
        case .ready:
            videoFrame {
                PlaybackControls(
                    player: player,
                    isFavorite: isFavorite,
                    canToggleFavorite: canToggleFavorite,
                    onToggleFavorite: onToggleFavorite,
                    onReturnToLibrary: onReturnToLibrary
                ) {
                    videoView.window?.toggleFullScreen(nil)
                }
                // A file owns its scrub/focus/idle state; the video host keeps its identity.
                .id(player.state.request?.id)
            }
        case .ended:
            videoFrame {
                VStack(spacing: 14) {
                    Text("player.ended")
                        .font(AppTheme.Typography.headline)
                    HStack(spacing: 10) {
                        Button(action: onReturnToLibrary) {
                            Label("library.backToLibrary", systemImage: "chevron.left")
                        }
                        .buttonStyle(PlayerCompletionButtonStyle())
                        if player.queue.items.count > 1 {
                            PlaybackQueueMenu(player: player)
                                .foregroundStyle(.white)
                        }
                        Button { player.replay() } label: {
                            Label("player.replay", systemImage: "play.fill")
                        }
                        .buttonStyle(PlayerCompletionButtonStyle(isPrimary: true))
                    }
                }
                .padding(20)
                .foregroundStyle(.white)
                .background(AppTheme.playerControlBackground(reduceTransparency: reduceTransparency),
                            in: RoundedRectangle(cornerRadius: AppTheme.Corners.surface))
            }
        case .failed(let failure):
            errorFrame(failure)
        }
    }

    @ViewBuilder
    private var playerFooter: some View {
        VStack(spacing: 0) {
            if let request = player.state.request {
                PlayerMediaDetails(url: request.url)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.Layout.playerDetailsHorizontalInset)
                    .padding(.top, AppTheme.Layout.playerDetailsTopInset)
                    .padding(.bottom, AppTheme.Layout.playerDetailsBottomInset)
            }
            if let failure = player.state.commandFailure {
                PlaybackCommandFailureNotice(failure: failure) {
                    player.dismissCommandFailure()
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, AppTheme.Layout.playerDetailsHorizontalInset)
            }
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
                .font(AppTheme.Typography.Symbol.playbackFailure)
                .accessibilityHidden(true)
            Text(failure.title).font(AppTheme.Typography.headline)
            Text(failure.explanation)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .foregroundStyle(.white.opacity(0.75))
            if let detail = failure.detail {
                Text(detail)
                    .font(AppTheme.Typography.diagnostic)
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
            if player.queue.items.count > 1 {
                PlaybackQueueMenu(player: player)
            }
        }
        .font(AppTheme.Typography.controlBody)
        .padding(30)
        .frame(maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .foregroundStyle(.white)
        .background(AppTheme.playerFallback, in: RoundedRectangle(cornerRadius: AppTheme.Corners.player))
    }
}

private struct PlayerPageLayout: Layout {
    let availableHeight: CGFloat
    let stageInset: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        let footerHeight = measuredFooterHeight(in: width, subviews: subviews)
        let stageWidth = stageWidth(for: width, footerHeight: footerHeight)
        let contentHeight = stageWidth * 9 / 16 + footerHeight + 2 * stageInset
        return CGSize(width: width, height: min(availableHeight, max(0, contentHeight)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let footerHeight = measuredFooterHeight(in: bounds.width, subviews: subviews)
        let stageWidth = stageWidth(for: bounds.width, footerHeight: footerHeight)
        let stageHeight = stageWidth * 9 / 16
        let stageFrame = CGRect(
            x: bounds.minX + (bounds.width - stageWidth) / 2,
            y: bounds.minY + stageInset,
            width: stageWidth,
            height: stageHeight
        )

        if let stage = subviews.first {
            stage.place(at: stageFrame.origin, anchor: .topLeading,
                        proposal: ProposedViewSize(stageFrame.size))
        }
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.minX, y: stageFrame.maxY + stageInset), anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: footerHeight))
        }
    }

    private func measuredFooterHeight(in width: CGFloat, subviews: Subviews) -> CGFloat {
        guard subviews.count > 1 else { return 0 }
        return subviews[1].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
    }

    private func stageWidth(for width: CGFloat, footerHeight: CGFloat) -> CGFloat {
        let widthLimit = max(0, width - 2 * stageInset)
        let heightLimit = max(0, availableHeight - footerHeight - 2 * stageInset) * 16 / 9
        return min(widthLimit, heightLimit)
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
                    .font(AppTheme.Typography.controlEmphasis)
                    .foregroundStyle(AppTheme.textPrimary)
                Text(failure.explanation)
                    .font(AppTheme.Typography.metadata)
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = failure.detail {
                    Text(detail)
                        .font(AppTheme.Typography.commandDiagnostic)
                        .foregroundStyle(AppTheme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Button(action: dismiss) {
                Text("common.dismiss")
                    .font(AppTheme.Typography.controlBody)
                    .frame(minHeight: AppTheme.Layout.compactControlSize)
                    .contentShape(Rectangle())
            }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.mutedSurface)
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
                    .font(AppTheme.Typography.playerMediaTitle)
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(url.deletingLastPathComponent().path)
                    .font(AppTheme.Typography.mediaPath)
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
            .font(AppTheme.Typography.compactBadge)
            .foregroundStyle(AppTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Corners.badge)
                    .stroke(AppTheme.separator, lineWidth: 1)
            }
    }
}

private struct PlayerCompletionButtonStyle: ButtonStyle {
    var isPrimary = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTheme.Typography.controlLabel)
            .lineLimit(1)
            .padding(.horizontal, 14)
            .frame(minHeight: AppTheme.Layout.toolbarControlSize)
            .foregroundStyle(isPrimary ? AppTheme.textPrimary : .white)
            .background(isPrimary ? .white : .white.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: AppTheme.Corners.control))
            .overlay {
                RoundedRectangle(cornerRadius: AppTheme.Corners.control)
                    .stroke(.white.opacity(0.22), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: AppTheme.Corners.control))
            .opacity(isEnabled ? 1 : 0.45)
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
