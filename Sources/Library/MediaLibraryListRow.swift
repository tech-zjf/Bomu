import CoreGraphics
import SwiftUI

struct MediaLibraryListRow: View {
    let item: MediaLibraryItem
    let isPlayable: Bool
    let isVisible: Bool
    let model: MediaLibraryModel
    let onPlay: (MediaLibraryItem) -> Void
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void
    var density: MediaBrowserDensity = .comfortable
    let onToggleFavorite: () -> Void

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
        HStack(spacing: 13) {
            Button { model.select(item) } label: {
                HStack(spacing: 13) {
                    MediaLibraryThumbnail(image: thumbnailImage, isAudio: isAudio,
                                          cornerRadius: AppTheme.Corners.listArtwork)
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
                                    onContinue: onContinue, onPlayFromBeginning: onPlayFromBeginning,
                                    popoverArrowEdge: .leading)
        }
        .padding(.vertical, density == .compact
                 ? AppTheme.Layout.compactMediaListRowVerticalInset : AppTheme.Layout.mediaListRowVerticalInset)
        .contentShape(Rectangle())
        .onTapGesture { model.select(item) }
        .background(model.selectedItemID == item.id ? AppTheme.mutedSurface : .clear)
        .overlay(alignment: .bottom) { AppTheme.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
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
