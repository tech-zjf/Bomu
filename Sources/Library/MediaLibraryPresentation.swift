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

/// Presentation data belongs to one indexed file revision, not merely to a reused SwiftUI view.
struct MediaLibraryAssetKey: Equatable {
    let id: Int64
    let relativePath: String
    let contentRevision: String

    init(item: MediaLibraryItem) {
        id = item.id
        relativePath = item.relativePath
        contentRevision = item.contentRevision
    }
}

/// Availability controls task restarts; the asset key alone controls which result may be shown.
struct MediaLibraryAssetLoadKey: Equatable {
    let asset: MediaLibraryAssetKey
    let isVisible: Bool
    let isPlayable: Bool
}

struct MediaTechnicalMetadataSummary: View {
    let metadata: MediaTechnicalMetadata
    let isAudio: Bool

    var body: some View {
        Text(MediaTechnicalMetadataText.value(metadata: metadata, isAudio: isAudio))
    }
}

struct MediaLibraryThumbnail: View {
    let image: CGImage?
    let isAudio: Bool
    var aspectRatio: CGFloat = 16 / 10
    var cornerRadius: CGFloat = AppTheme.Corners.artwork

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                AppTheme.thumbnailPlaceholder
                if let image {
                    Image(decorative: image, scale: 1)
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
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
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
    var onAction: (() -> Void)? = nil

    @FocusState private var isFirstActionFocused: Bool

    var body: some View {
        Button(item.isFavorite ? "library.removeFavorite" : "library.addFavorite",
               systemImage: item.isFavorite ? "heart.slash" : "heart") {
            onAction?()
            Task { await model.toggleFavorite(item) }
        }
        .focusable(true)
        .focused($isFirstActionFocused)
        .onAppear { isFirstActionFocused = onAction != nil }
        Button(item.isWatched ? "library.markUnwatched" : "library.markWatched",
               systemImage: item.isWatched ? "eye.slash" : "eye") {
            onAction?()
            Task { await model.toggleWatched(item) }
        }
        .focusable(true)
        if item.playbackPosition > 0 && !item.hasPlaybackHistoryConflict {
            Button("library.continuePlayback", systemImage: "play.fill") {
                onAction?()
                model.select(item)
                onContinue(item)
            }
            .disabled(!isPlayable)
            .focusable(true)
        }
        Button("library.playFromBeginning", systemImage: "backward.end.fill") {
            onAction?()
            model.select(item)
            onPlayFromBeginning(item)
        }
        .disabled(!isPlayable)
        .focusable(true)
        Menu("library.category") {
            ForEach(MediaManualCategory.allCases) { category in
                Button {
                    onAction?()
                    model.setCategory(category, for: item)
                } label: {
                    if item.manualCategory == category {
                        Label(category.title, systemImage: "checkmark")
                    } else {
                        Text(category.title)
                    }
                }
            }
            if item.manualCategory != nil {
                Divider()
                Button("library.category.clear") {
                    onAction?()
                    model.setCategory(nil, for: item)
                }
            }
        }
        .focusable(true)
    }
}

/// The visible menu entry is shared by cards and rows, as are its operations.
struct MediaLibraryActionsMenu: View {
    let item: MediaLibraryItem
    let isPlayable: Bool
    let model: MediaLibraryModel
    let onContinue: (MediaLibraryItem) -> Void
    let onPlayFromBeginning: (MediaLibraryItem) -> Void
    let popoverArrowEdge: Edge

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: "ellipsis")
                .font(AppTheme.Typography.Symbol.mediaActions)
                .foregroundStyle(AppTheme.textPrimary)
                .frame(width: AppTheme.Layout.compactControlSize, height: AppTheme.Layout.compactControlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("library.moreActions"))
        .help(Text("library.moreActions"))
        .focusable(true)
        .onKeyPress(.return) {
            isPresented = true
            return .handled
        }
        .onKeyPress(.space) {
            isPresented = true
            return .handled
        }
        .popover(isPresented: $isPresented, arrowEdge: popoverArrowEdge) {
            VStack(alignment: .leading, spacing: 4) {
                MediaLibraryItemActions(item: item, isPlayable: isPlayable, model: model,
                                        onContinue: onContinue, onPlayFromBeginning: onPlayFromBeginning,
                                        onAction: { isPresented = false })
            }
            .padding(8)
            .frame(minWidth: 220, alignment: .leading)
            .background(AppTheme.surface)
        }
    }
}
