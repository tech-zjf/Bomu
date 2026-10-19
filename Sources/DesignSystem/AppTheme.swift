import SwiftUI

// Native view tokens mirror player_plan/开发定稿/设计规范.json.
enum AppTheme {
    static let textPrimary = Color(red: 20 / 255, green: 29 / 255, blue: 45 / 255)
    static let textSecondary = Color(red: 100 / 255, green: 112 / 255, blue: 132 / 255)
    static let surface = Color.white
    static let mutedSurface = Color(red: 240 / 255, green: 244 / 255, blue: 248 / 255)
    static let separator = Color(red: 229 / 255, green: 234 / 255, blue: 240 / 255)
    static let thumbnailPlaceholder = Color(red: 218 / 255, green: 229 / 255, blue: 231 / 255)
    static let selectionAccent = Color(red: 239 / 255, green: 185 / 255, blue: 143 / 255)
    static let playerFallback = Color(red: 17 / 255, green: 23 / 255, blue: 34 / 255)
    static func playerToolbarBackground(reduceTransparency: Bool) -> Color {
        reduceTransparency
            ? playerFallback
            : Color(red: 34 / 255, green: 40 / 255, blue: 50 / 255).opacity(0.5)
    }
    static func playerControlBackground(reduceTransparency: Bool) -> Color {
        reduceTransparency ? playerFallback : Color.black.opacity(0.55)
    }

    enum Typography {
        // The serif face is reserved for the brand; all working interface text stays sans-serif.
        static let pageTitle = Font.system(size: 27, weight: .bold)
        static let sectionTitle = Font.system(size: 18, weight: .semibold)
        static let brandName = Font.system(size: 32, weight: .semibold, design: .serif)
        static let mediaTitle = Font.system(size: 13, weight: .semibold)
        static let mediaMetadata = Font.system(size: 11, weight: .regular)
        static let pageSubtitle = Font.system(size: 12, weight: .regular)
        static let metadata = Font.system(size: 12, weight: .regular)
        static let subtitle = Font.system(size: 13, weight: .regular)
        static let body = Font.system(size: 14)
        static let controlBody = Font.system(size: 13)
        static let controlLabel = Font.system(size: 13, weight: .medium)
        static let controlEmphasis = Font.system(size: 13, weight: .semibold)
        static let filterLabel = Font.system(size: 12, weight: .medium)
        static let sidebarLabel = Font.system(size: 13)
        static let sidebarSelected = Font.system(size: 13, weight: .semibold)
        static let sidebarSection = Font.system(size: 10, weight: .semibold)
        static let sidebarLocalTag = Font.system(size: 10)
        static let compactCaption = Font.system(size: 11)
        static let compactBadge = Font.system(size: 10, weight: .medium)
        static let durationBadge = Font.system(size: 10, weight: .medium).monospacedDigit()
        static let timeReadout = Font.system(size: 11, weight: .medium).monospacedDigit()
        static let playerFileName = Font.system(size: 13, weight: .medium)
        static let playerMediaTitle = Font.system(size: 16, weight: .semibold)
        static let mediaPath = Font.system(size: 11)
        static let commandDiagnostic = Font.system(size: 11, design: .monospaced)
        static let diagnostic = Font.system(.caption, design: .monospaced)
        static let headline = Font.headline
        static let callout = Font.callout
        static let emphasizedCallout = Font.callout.weight(.medium)
        static let caption = Font.caption
        static let emphasizedCaption = Font.caption.weight(.semibold)

        enum Symbol {
            static let sidebar = Font.system(size: 14, weight: .regular)
            static let nowPlaying = Font.system(size: 20, weight: .regular)
            static let compactAction = Font.system(size: 13, weight: .regular)
            static let folderRow = Font.system(size: 21, weight: .regular)
            static let folderTile = Font.system(size: 25, weight: .regular)
            static let folderDisclosure = Font.system(size: 10, weight: .semibold)
            static let folderBreadcrumb = Font.caption2
            static let mediaPlay = Font.system(size: 12, weight: .semibold)
            static let mediaActions = Font.system(size: 14, weight: .semibold)
            static let thumbnailPlaceholder = Font.system(size: 24, weight: .light)
            static let emptyState = Font.system(size: 27, weight: .light)
            static let startupFailure = Font.system(size: 28, weight: .light)
            static let playbackFailure = Font.system(size: 30, weight: .light)
            static let emptyPlayer = Font.system(size: 58)
            static let playerVolume = Font.system(size: 12)
            static let playerToolbar = Font.system(size: 12, weight: .medium)
            static let playerPrimaryTransport = Font.system(size: 39)
            static let playerSkipTransport = Font.system(size: 27)
            static let playerMediaInfo = Font.system(size: 15, weight: .medium)
        }
    }

    enum Layout {
        static let compactControlSize: CGFloat = 28
        static let toolbarControlSize: CGFloat = 35
        static let sidebarIconWidth: CGFloat = 16
        static let sidebarIconGap: CGFloat = 10
        static let folderListIconSize: CGFloat = 44
        static let folderRowVerticalInset: CGFloat = 12
        static let mediaSummaryLineHeight: CGFloat = 14
        static let sidebarWidth: CGFloat = 176
        static let settingsNavigationWidth: CGFloat = 164
        static let sidebarHorizontalInset: CGFloat = 13
        static let sidebarTopInset: CGFloat = 25
        static let sidebarBottomInset: CGFloat = 17
        static let sidebarSectionSpacing: CGFloat = 5
        static let sidebarHeadingTopInset: CGFloat = 21
        static let sidebarHeadingBottomInset: CGFloat = 7
        static let sidebarRowHorizontalInset: CGFloat = 12
        static let sidebarRowHeight: CGFloat = 40
        static let sidebarLocalTagTopInset: CGFloat = 35
        static let contentHorizontalInset: CGFloat = 30
        static let contentVerticalInset: CGFloat = 28
        static let mediaGridColumnCount = 3
        static let folderGridGap: CGFloat = 17
        static let continueWatchingGap: CGFloat = 16
        static let mediaGridColumnGap: CGFloat = 17
        static let mediaGridRowGap: CGFloat = 23
        static let mediaSummaryHeight: CGFloat = 28
        static let sectionGap: CGFloat = 28
        static let playerStageInset: CGFloat = 12
        static let playerHorizontalInset: CGFloat = 22
        static let minimumWindowWidth: CGFloat = 900
        static let minimumWindowHeight: CGFloat = 600
    }

    enum Corners {
        static let dropTargetOverlay: CGFloat = 8
        static let surface: CGFloat = 12
        static let artwork: CGFloat = 14
        static let player: CGFloat = 14
        static let selection: CGFloat = 11
        static let control: CGFloat = 12
        static let folderIcon: CGFloat = 12
        static let field: CGFloat = 12
        static let badge: CGFloat = 6
        static let emptyStateIcon: CGFloat = 20
    }

    enum PlayerControls {
        static let centralButtonSize: CGFloat = 88
        static let skipButtonSize: CGFloat = 62
        static let buttonGap: CGFloat = 26
        static let autoHideSeconds: Double = 2.5
    }
}
