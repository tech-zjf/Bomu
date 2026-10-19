import AppKit
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
    let onPlay: (MediaLibraryItem) -> Void
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var thumbnailURL: URL?
    @State private var metadataState: MediaTechnicalMetadataLoadState = .loading

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
                                        onContinue: onContinue, onPlayFromBeginning: onPlayFromBeginning)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.select(item) }
        .task(id: "thumbnail-\(item.id)-\(item.relativePath)-\(item.contentRevision)-\(isVisible)-\(isPlayable)") {
            guard isVisible else {
                thumbnailURL = nil
                return
            }
            let loadedThumbnail = await model.thumbnailURL(for: item)
            guard !Task.isCancelled else { return }
            thumbnailURL = loadedThumbnail
        }
        .task(id: "metadata-\(item.id)-\(item.relativePath)-\(item.contentRevision)-\(isVisible)-\(isPlayable)") {
            guard isVisible else {
                metadataState = .loading
                return
            }
            metadataState = .loading
            let loadedMetadata = await model.metadata(for: item)
            guard !Task.isCancelled else { return }
            metadataState = .resolved(loadedMetadata)
        }
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
                    .background(.black.opacity(reduceTransparency ? 1 : 0.68),
                                in: RoundedRectangle(cornerRadius: AppTheme.Corners.badge))
                    .padding(9)
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
        MediaLibraryThumbnail(url: thumbnailURL, isAudio: isAudio)
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
