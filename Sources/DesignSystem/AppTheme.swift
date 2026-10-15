import SwiftUI

// Native view tokens mirror player_plan/开发定稿/设计规范.json.
enum AppTheme {
    static let textPrimary = Color(red: 20 / 255, green: 29 / 255, blue: 45 / 255)
    static let textSecondary = Color(red: 100 / 255, green: 112 / 255, blue: 132 / 255)
    static let surface = Color.white
    static let background = Color(red: 240 / 255, green: 244 / 255, blue: 248 / 255)
    static let separator = Color(red: 229 / 255, green: 234 / 255, blue: 240 / 255)
    static let thumbnailPlaceholder = Color(red: 218 / 255, green: 229 / 255, blue: 231 / 255)
    static let selectionAccent = Color(red: 239 / 255, green: 185 / 255, blue: 143 / 255)
    static let playerFallback = Color(red: 17 / 255, green: 23 / 255, blue: 34 / 255)
    static let playerControlBackground = Color.black.opacity(0.55)

    enum Typography {
        // The serif face is reserved for the brand; all working interface text stays sans-serif.
        static let pageTitle = Font.system(size: 27, weight: .semibold)
        static let sectionTitle = Font.system(size: 17, weight: .semibold)
        static let brandName = Font.system(size: 32, weight: .semibold, design: .serif)
        static let mediaTitle = Font.system(size: 14, weight: .medium)
        static let metadata = Font.system(size: 12, weight: .regular)
        static let subtitle = Font.system(size: 13, weight: .regular)
        static let body = Font.system(size: 14)
        static let controlBody = Font.system(size: 13)
        static let controlLabel = Font.system(size: 13, weight: .medium)
        static let controlEmphasis = Font.system(size: 13, weight: .semibold)
        static let filterLabel = Font.system(size: 12, weight: .medium)
        static let sidebarLabel = Font.system(size: 13)
        static let sidebarSelected = Font.system(size: 13, weight: .medium)
        static let sidebarSection = Font.system(size: 11, weight: .semibold)
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
    }

    enum Layout {
        static let sidebarWidth: CGFloat = 176
        static let contentInset: CGFloat = 30
        static let gridGap: CGFloat = 17
        static let sectionGap: CGFloat = 28
        static let playerHorizontalInset: CGFloat = 22
        static let minimumWindowWidth: CGFloat = 900
        static let minimumWindowHeight: CGFloat = 600
    }

    enum Corners {
        // Small radii keep desktop surfaces crisp; semantic circles stay circular in their controls.
        static let dropTargetOverlay: CGFloat = 6
        static let surface: CGFloat = 3
        static let artwork: CGFloat = 4
        static let player: CGFloat = 4
        static let selection: CGFloat = 2
        static let control: CGFloat = 4
        static let folderIcon: CGFloat = 2
        static let field: CGFloat = 4
        static let badge: CGFloat = 2
        static let emptyStateIcon: CGFloat = 10
    }

    enum PlayerControls {
        static let centralButtonSize: CGFloat = 88
        static let skipButtonSize: CGFloat = 62
        static let primaryIconSize: CGFloat = 39
        static let skipIconSize: CGFloat = 27
        static let buttonGap: CGFloat = 26
        static let autoHideSeconds: Double = 2.5
    }
}
