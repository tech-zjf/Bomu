import Foundation

extension MediaManualCategory {
    var accessibilityTitle: String {
        switch self {
        case .movie: String(localized: "library.category.movie")
        case .series: String(localized: "library.category.series")
        case .personal: String(localized: "library.category.personal")
        }
    }
}

enum MediaLibraryAccessibilitySummary {
    static func value(for item: MediaLibraryItem, isSelected: Bool,
                      metadata: MediaTechnicalMetadata?, isOffline: Bool = false) -> String {
        var details: [String] = []
        if isOffline { details.append(String(localized: "library.sourceOffline")) }
        if isSelected {
            details.append(String(localized: "library.selection.selected"))
        }
        details.append(String(localized: item.isWatched ? "library.filter.watched" : "library.filter.unwatched"))
        if let category = item.manualCategory {
            details.append(category.accessibilityTitle)
        }
        if item.hasPlaybackHistoryConflict {
            details.append(String(localized: "library.historyConflict"))
        } else if item.playbackPosition > 0 {
            details.append(String.localizedStringWithFormat(
                NSLocalizedString("library.continueAt", comment: ""),
                MediaTechnicalMetadataText.durationLabel(item.playbackPosition) ?? "—"
            ))
        }
        if let metadata,
           let value = MediaTechnicalMetadataText.accessibilityValue(
               metadata: metadata,
               isAudio: MediaFileType.isAudio(URL(filePath: item.relativePath))
           ) {
            details.append(value)
        }
        details.append(ByteCountFormatStyle().format(item.byteCount))
        return details.joined(separator: ", ")
    }
}
