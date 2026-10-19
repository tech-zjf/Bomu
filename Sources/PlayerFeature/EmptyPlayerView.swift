import SwiftUI

struct EmptyPlayerView: View {
    let openMedia: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(AppTheme.Typography.Symbol.emptyPlayer)
                .accessibilityHidden(true)
            Text(Brand.displayName)
                .font(AppTheme.Typography.brandName)
            Text("app.tagline")
                .foregroundStyle(AppTheme.textSecondary)
            Button("open.video", action: openMedia)
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.textPrimary)
                .controlSize(.large)
            Text("player.emptyPrompt")
                .font(AppTheme.Typography.metadata)
                .foregroundStyle(AppTheme.textSecondary)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.mutedSurface)
        .foregroundStyle(AppTheme.textPrimary)
    }
}
