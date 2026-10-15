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
                        .font(.system(size: 24, weight: .light))
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
