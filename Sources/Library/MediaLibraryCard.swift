import AppKit
import CoreGraphics
import SwiftUI

struct MediaLibraryCard: View {
    enum Presentation {
        case continueWatching
        case standard
    }

    let item: MediaLibraryItem
    let model: MediaLibraryModel
    let isVisible: Bool
    let isPlayable: Bool
    let presentation: Presentation
    let menuArrowEdge: Edge
    let onPlay: (MediaLibraryItem) -> Void
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var thumbnailResult: (key: MediaLibraryAssetKey, image: CGImage?)?
    @State private var metadataResult: (key: MediaLibraryAssetKey, state: MediaTechnicalMetadataLoadState)?

    private var assetKey: MediaLibraryAssetKey { MediaLibraryAssetKey(item: item) }
    private var loadKey: MediaLibraryAssetLoadKey {
        MediaLibraryAssetLoadKey(asset: assetKey, isVisible: isVisible, isPlayable: isPlayable)
    }
    private var thumbnailImage: CGImage? {
        guard let thumbnailResult, thumbnailResult.key == assetKey else { return nil }
        return thumbnailResult.image
    }
    private var metadataState: MediaTechnicalMetadataLoadState {
        guard let metadataResult, metadataResult.key == assetKey else { return .loading }
        return metadataResult.state
    }
    private var technicalMetadata: MediaTechnicalMetadata? { metadataState.metadata }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            artwork
            HStack(alignment: .top, spacing: 4) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.displayName)
                        .font(AppTheme.Typography.mediaTitle)
                        .lineLimit(1)
                        .foregroundStyle(AppTheme.textPrimary)
                    metadataLine
                        .font(AppTheme.Typography.mediaMetadata)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)

                MediaLibraryActionsMenu(item: item, isPlayable: isPlayable, model: model,
                                        onContinue: onContinue, onPlayFromBeginning: onPlayFromBeginning,
                                        popoverArrowEdge: menuArrowEdge)
            }
        }
        .contentShape(Rectangle())
        .focusSection()
        .onTapGesture { model.select(item) }
        .task(id: loadKey) {
            let key = assetKey
            guard isVisible else {
                thumbnailResult = nil
                return
            }
            if thumbnailResult?.key != key {
                thumbnailResult = (key, nil)
            }
            let image = await model.thumbnailImage(for: item)
            guard !Task.isCancelled, thumbnailResult?.key == key else { return }
            thumbnailResult = (key, image)
        }
        .task(id: loadKey) {
            let key = assetKey
            guard isVisible else {
                metadataResult = nil
                return
            }
            metadataResult = (key, .loading)
            let loadedMetadata = await model.metadata(for: item)
            guard !Task.isCancelled, metadataResult?.key == key else { return }
            metadataResult = (key, .resolved(loadedMetadata))
        }
        .onDisappear { thumbnailResult = nil }
        .contextMenu { mediaActions }
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            Button { model.select(item) } label: {
                artworkImage
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded { play() })
            .accessibilityLabel(Text(item.displayName))
            .accessibilityValue(Text(MediaLibraryAccessibilitySummary.value(
                for: item,
                isSelected: model.selectedItemID == item.id,
                metadata: technicalMetadata,
                isOffline: !isPlayable
            )))

            if isPlayable {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(AppTheme.Typography.Symbol.mediaPlay)
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: AppTheme.Layout.compactControlSize, height: AppTheme.Layout.compactControlSize)
                        .background(.white.opacity(reduceTransparency ? 1 : 0.92), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .focusable(true)
                .accessibilityLabel(Text("library.playMedia"))
                .padding(12)
            }

            if !isPlayable {
                Label("library.sourceOffline", systemImage: "externaldrive.badge.xmark")
                    .font(AppTheme.Typography.compactBadge)
                    .foregroundStyle(AppTheme.textPrimary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.white, in: RoundedRectangle(cornerRadius: AppTheme.Corners.badge))
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if let badge = durationBadge {
                Text(badge)
                    .font(AppTheme.Typography.durationBadge)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(AppTheme.durationBadgeBackground(reduceTransparency: reduceTransparency),
                                in: RoundedRectangle(cornerRadius: AppTheme.Corners.badge))
                    .padding(.trailing, AppTheme.Layout.durationBadgeTrailingInset)
                    .padding(.bottom, AppTheme.Layout.durationBadgeBottomInset)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .bottom) {
            if let progress {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.52))
                        Rectangle()
                            .fill(AppTheme.selectionAccent)
                            .frame(width: geometry.size.width * progress)
                    }
                }
                .frame(height: 3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Corners.artwork))
        .overlay {
            if model.selectedItemID == item.id {
                RoundedRectangle(cornerRadius: AppTheme.Corners.artwork)
                    .strokeBorder(AppTheme.textPrimary.opacity(0.55), lineWidth: 2)
                    .allowsHitTesting(false)
            }
        }
    }

    private var artworkImage: some View {
        MediaLibraryThumbnail(image: thumbnailImage, isAudio: isAudio)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var metadataLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            metadataSummary
                .lineLimit(presentation == .continueWatching ? 1 : 2)
                .frame(height: presentation == .continueWatching
                       ? AppTheme.Layout.mediaSummaryLineHeight : AppTheme.Layout.mediaSummaryHeight,
                       alignment: .topLeading)

            Text(ByteCountFormatStyle().format(item.byteCount))
                .font(AppTheme.Typography.mediaMetadata)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var metadataSummary: some View {
        switch presentation {
        case .continueWatching:
            Text(String.localizedStringWithFormat(
                NSLocalizedString("library.continueAt", comment: ""),
                MediaTechnicalMetadataText.durationLabel(item.playbackPosition) ?? "—"
            ))
        case .standard:
            if let category = item.manualCategory {
                Text(category.title)
                    + Text(verbatim: " · ")
                    + Text(verbatim: metadataState.cardValue(isAudio: isAudio))
            } else {
                Text(verbatim: metadataState.cardValue(isAudio: isAudio))
            }
        }
    }

    private var durationBadge: String? {
        guard let duration = technicalMetadata?.duration,
              let durationText = MediaTechnicalMetadataText.durationLabel(duration) else {
            return nil
        }
        guard presentation == .continueWatching else { return durationText }
        let remaining = max(0, duration - item.playbackPosition)
        guard remaining >= 1 else { return nil }
        return String.localizedStringWithFormat(
            NSLocalizedString("library.remaining", comment: ""),
            MediaTechnicalMetadataText.durationLabel(remaining) ?? "—"
        )
    }

    private var progress: CGFloat? {
        guard presentation == .continueWatching,
              let duration = technicalMetadata?.duration,
              duration.isFinite, duration > 0 else {
            return nil
        }
        return CGFloat(min(1, max(0, item.playbackPosition / duration)))
    }

    private var isAudio: Bool {
        MediaFileType.isAudio(URL(filePath: item.relativePath))
    }

    private var mediaActions: some View {
        MediaLibraryItemActions(item: item, isPlayable: isPlayable, model: model,
                                onContinue: onContinue, onPlayFromBeginning: onPlayFromBeginning)
    }

    private func play() {
        guard isPlayable else { return }
        model.select(item)
        if presentation == .continueWatching, item.playbackPosition > 0 {
            onContinue(item)
        } else {
            onPlay(item)
        }
    }

}
