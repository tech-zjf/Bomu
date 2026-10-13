import SwiftUI

struct StartView: View {
    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 58, weight: .regular))
                .foregroundStyle(AppTheme.textPrimary)
                .accessibilityHidden(true)

            Text(Brand.displayName)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)

            Text("泊幕 · Mac 本地播放器")
                .font(.system(size: 15))
                .foregroundStyle(AppTheme.textSecondary)

            Text("开发预览 · 播放功能尚未接入")
                .font(.system(size: 12))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(AppTheme.surface, in: Capsule())
                .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minWidth: 900, minHeight: 600)
        .background(AppTheme.background)
    }
}
