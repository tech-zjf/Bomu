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

    @State private var thumbnailURL: URL?
    @State private var technicalMetadata: MediaTechnicalMetadata?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            artwork
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName)
                        .font(AppTheme.Typography.mediaTitle)
                        .lineLimit(1)
                        .foregroundStyle(AppTheme.textPrimary)
                    metadataLine
                        .font(AppTheme.Typography.metadata)
                        .lineLimit(1)
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)

                actionsMenu
            }
        }
        .contentShape(Rectangle())
        .task(id: "\(item.relativePath)-\(item.contentRevision)-\(isVisible)") {
            guard isVisible else {
                thumbnailURL = nil
                technicalMetadata = nil
                return
            }
            async let thumbnail = model.thumbnailURL(for: item)
            async let metadata = model.metadata(for: item)
            let loadedThumbnail = await thumbnail
            let loadedMetadata = await metadata
            guard !Task.isCancelled else { return }
            thumbnailURL = loadedThumbnail
            technicalMetadata = loadedMetadata
        }
        .contextMenu { mediaActions }
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            Button { model.select(item) } label: {
                artworkImage
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.displayName))
            .accessibilityValue(Text(MediaLibraryAccessibilitySummary.value(
                for: item,
                isSelected: model.selectedItemID == item.id,
                metadata: technicalMetadata
            )))

            if isPlayable {
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .frame(width: 26, height: 26)
                        .background(.white.opacity(0.92), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("library.playMedia"))
                .padding(10)
            }

            if let badge = durationBadge {
                Text(badge)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: AppTheme.Corners.badge))
                    .padding(9)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
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
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Corners.artwork))
    }

    private var artworkImage: some View {
        MediaLibraryThumbnail(url: thumbnailURL, isAudio: isAudio)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var metadataLine: some View {
        if presentation == .continueWatching {
            Text(String.localizedStringWithFormat(
                NSLocalizedString("library.continueAt", comment: ""),
                MediaTechnicalMetadataText.durationLabel(item.playbackPosition) ?? "—"
            ))
        } else {
            HStack(spacing: 5) {
                if let category = item.manualCategory {
                    Text(category.title)
                }
                if item.manualCategory != nil, technicalMetadata != nil {
                    Text(verbatim: "·")
                }
                if let technicalMetadata {
                    Text(MediaTechnicalMetadataText.cardValue(metadata: technicalMetadata, isAudio: isAudio))
                } else if item.manualCategory == nil {
                    Text(ByteCountFormatStyle().format(item.byteCount))
                }
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

    private var actionsMenu: some View {
        Menu { mediaActions } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("library.moreActions"))
    }

    @ViewBuilder
    private var mediaActions: some View {
        Button(item.isFavorite ? "library.removeFavorite" : "library.addFavorite",
               systemImage: item.isFavorite ? "heart.slash" : "heart") {
            model.toggleFavorite(item)
        }
        Button(item.isWatched ? "library.markUnwatched" : "library.markWatched",
               systemImage: item.isWatched ? "eye.slash" : "eye") {
            model.toggleWatched(item)
        }
        if item.playbackPosition > 0 {
            Button("library.continuePlayback", systemImage: "play.fill") { continuePlayback() }
        }
        Button("library.playFromBeginning", systemImage: "backward.end.fill") {
            playFromBeginning()
        }
        Menu("library.category") {
            ForEach(MediaManualCategory.allCases) { category in
                Button(category.title) { model.setCategory(category, for: item) }
            }
            if item.manualCategory != nil {
                Divider()
                Button("library.category.clear") { model.setCategory(nil, for: item) }
            }
        }
    }

    private func play() {
        model.select(item)
        if presentation == .continueWatching, item.playbackPosition > 0 {
            onContinue(item)
        } else {
            onPlay(item)
        }
    }

    private func continuePlayback() {
        model.select(item)
        onContinue(item)
    }

    private func playFromBeginning() {
        model.select(item)
        onPlayFromBeginning(item)
    }
}
