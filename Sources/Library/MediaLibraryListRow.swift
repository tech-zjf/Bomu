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
    @State private var technicalMetadata: MediaTechnicalMetadata?

    var body: some View {
        HStack(spacing: 13) {
            MediaLibraryThumbnail(url: thumbnailURL, isAudio: isAudio)
                .frame(width: 90)

            Button { model.select(item) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.displayName)
                        .font(AppTheme.Typography.mediaTitle)
                        .lineLimit(1)
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(MediaTechnicalMetadataText.cardValueOrFileSize(
                        metadata: technicalMetadata,
                        byteCount: item.byteCount,
                        isAudio: isAudio
                    ))
                    .font(AppTheme.Typography.metadata)
                    .lineLimit(1)
                    .foregroundStyle(AppTheme.textSecondary)
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
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isPlayable)
            .accessibilityLabel(Text("library.playMedia"))

            Button(action: onToggleFavorite) {
                Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(item.isFavorite ? .pink : AppTheme.textSecondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(item.isFavorite ? "library.removeFavorite" : "library.addFavorite"))
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { AppTheme.separator.frame(height: 1) }
        .accessibilityElement(children: .contain)
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
        .contextMenu {
            if item.playbackPosition > 0 {
                Button("library.continuePlayback", systemImage: "play.fill") {
                    model.select(item)
                    onContinue(item)
                }
            }
            Button("library.playFromBeginning", systemImage: "backward.end.fill") {
                model.select(item)
                onPlayFromBeginning(item)
            }
            Divider()
            Button(item.isWatched ? "library.markUnwatched" : "library.markWatched",
                   systemImage: item.isWatched ? "eye.slash" : "eye") {
                model.toggleWatched(item)
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
    }

    private var isAudio: Bool {
        MediaFileType.isAudio(URL(filePath: item.relativePath))
    }

    private var accessibilityValue: String {
        MediaLibraryAccessibilitySummary.value(
            for: item,
            isSelected: model.selectedItemID == item.id,
            metadata: technicalMetadata
        )
    }
}
