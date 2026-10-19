import SwiftUI

struct MediaLibraryListRow: View {
    let item: MediaLibraryItem
    let isPlayable: Bool
    let isVisible: Bool
    let model: MediaLibraryModel
    let onPlay: (MediaLibraryItem) -> Void
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void
    let onToggleFavorite: () -> Void

    @State private var thumbnailURL: URL?
    @State private var metadataState: MediaTechnicalMetadataLoadState = .loading

    private var technicalMetadata: MediaTechnicalMetadata? { metadataState.metadata }

    var body: some View {
        HStack(spacing: 13) {
            Button { model.select(item) } label: {
                HStack(spacing: 13) {
                    MediaLibraryThumbnail(url: thumbnailURL, isAudio: isAudio)
                        .frame(width: 90)
                        .overlay(alignment: .topTrailing) {
                            if !isPlayable {
                                Image(systemName: "externaldrive.badge.xmark")
                                    .font(AppTheme.Typography.Symbol.compactAction)
                                    .foregroundStyle(AppTheme.textPrimary)
                                    .padding(4)
                                    .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: AppTheme.Corners.badge))
                                    .padding(4)
                                    .accessibilityHidden(true)
                            }
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayName)
                            .font(AppTheme.Typography.mediaTitle)
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textPrimary)
                        Text(metadataState.cardValue(isAudio: isAudio))
                            .font(AppTheme.Typography.mediaMetadata)
                            .lineLimit(1)
                            .frame(height: AppTheme.Layout.mediaSummaryLineHeight, alignment: .topLeading)
                            .foregroundStyle(AppTheme.textSecondary)
                        Text(ByteCountFormatStyle().format(item.byteCount))
                            .font(AppTheme.Typography.mediaMetadata)
                            .lineLimit(1)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                guard isPlayable else { return }
                model.select(item)
                onPlay(item)
            })
            .accessibilityLabel(Text(item.displayName))
            .accessibilityValue(Text(accessibilityValue))

            Button {
                model.select(item)
                onPlay(item)
            } label: {
                Image(systemName: "play.fill")
                    .font(AppTheme.Typography.Symbol.mediaPlay)
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: AppTheme.Layout.compactControlSize, height: AppTheme.Layout.compactControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isPlayable)
            .accessibilityLabel(Text("library.playMedia"))

            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                    .font(AppTheme.Typography.Symbol.compactAction)
                    .foregroundStyle(item.isFavorite ? .pink : AppTheme.textSecondary)
                    .frame(width: AppTheme.Layout.compactControlSize, height: AppTheme.Layout.compactControlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.isFavorite ? "library.removeFavorite" : "library.addFavorite"))

            MediaLibraryActionsMenu(item: item, isPlayable: isPlayable, model: model,
                                    onContinue: onContinue, onPlayFromBeginning: onPlayFromBeginning)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { model.select(item) }
        .background(model.selectedItemID == item.id ? AppTheme.mutedSurface : .clear)
        .overlay(alignment: .bottom) { AppTheme.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
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
        .contextMenu {
            MediaLibraryItemActions(item: item, isPlayable: isPlayable, model: model,
                                    onContinue: onContinue, onPlayFromBeginning: onPlayFromBeginning)
        }
    }

    private var isAudio: Bool {
        MediaFileType.isAudio(URL(filePath: item.relativePath))
    }

    private var accessibilityValue: String {
        MediaLibraryAccessibilitySummary.value(
            for: item,
            isSelected: model.selectedItemID == item.id,
            metadata: technicalMetadata,
            isOffline: !isPlayable
        )
    }
}
