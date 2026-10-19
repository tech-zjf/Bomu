import AppKit
import SwiftUI

extension MediaManualCategory {
    var title: LocalizedStringKey {
        switch self {
        case .movie: "library.category.movie"
        case .series: "library.category.series"
        case .personal: "library.category.personal"
        }
    }
}

struct MediaTechnicalMetadataSummary: View {
    let metadata: MediaTechnicalMetadata
    let isAudio: Bool

    var body: some View {
        Text(MediaTechnicalMetadataText.value(metadata: metadata, isAudio: isAudio))
    }
}

struct MediaLibraryThumbnail: View {
    let url: URL?
    let isAudio: Bool
    var aspectRatio: CGFloat = 16 / 10

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppTheme.thumbnailPlaceholder
                if let url, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: isAudio ? "waveform" : "film")
                        .font(AppTheme.Typography.Symbol.thumbnailPlaceholder)
                        .foregroundStyle(AppTheme.textSecondary.opacity(0.8))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.Corners.artwork))
        .accessibilityHidden(true)
    }
}

/// Grid menus and list context menus expose the same operations and current category.
struct MediaLibraryItemActions: View {
    let item: MediaLibraryItem
    let isPlayable: Bool
    let model: MediaLibraryModel
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void

    var body: some View {
        Button(item.isFavorite ? "library.removeFavorite" : "library.addFavorite",
               systemImage: item.isFavorite ? "heart.slash" : "heart") {
            Task { await model.toggleFavorite(item) }
        }
        Button(item.isWatched ? "library.markUnwatched" : "library.markWatched",
               systemImage: item.isWatched ? "eye.slash" : "eye") {
            Task { await model.toggleWatched(item) }
        }
        if item.playbackPosition > 0 && !item.hasPlaybackHistoryConflict {
            Button("library.continuePlayback", systemImage: "play.fill") {
                model.select(item)
                onContinue(item)
            }
            .disabled(!isPlayable)
        }
        Button("library.playFromBeginning", systemImage: "backward.end.fill") {
            model.select(item)
            onPlayFromBeginning(item)
        }
        .disabled(!isPlayable)
        Menu("library.category") {
            ForEach(MediaManualCategory.allCases) { category in
                Button { model.setCategory(category, for: item) } label: {
                    if item.manualCategory == category {
                        Label(category.title, systemImage: "checkmark")
                    } else {
                        Text(category.title)
                    }
                }
            }
            if item.manualCategory != nil {
                Divider()
                Button("library.category.clear") { model.setCategory(nil, for: item) }
            }
        }
    }
}

/// The visible menu entry is shared by cards and rows, as are its operations.
struct MediaLibraryActionsMenu: View {
    let item: MediaLibraryItem
    let isPlayable: Bool
    let model: MediaLibraryModel
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void

    var body: some View {
        Menu {
            MediaLibraryItemActions(item: item, isPlayable: isPlayable, model: model,
                                    onContinue: onContinue, onPlayFromBeginning: onPlayFromBeginning)
        } label: {
            Image(systemName: "ellipsis")
                .font(AppTheme.Typography.Symbol.mediaActions)
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: AppTheme.Layout.compactControlSize, height: AppTheme.Layout.compactControlSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(Text("library.moreActions"))
        .help(Text("library.moreActions"))
    }
}
