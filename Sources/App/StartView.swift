import SwiftUI

struct StartView: View {
    let error: String?
    let openMedia: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 58))
                .accessibilityHidden(true)
            Text(Brand.displayName)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
            Text("app.tagline")
                .foregroundStyle(AppTheme.textSecondary)
            if let error {
                Text(error).textSelection(.enabled)
            } else {
                Button("open.video", action: openMedia)
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.textPrimary)
                    .controlSize(.large)
                Text("app.preview")
                    .font(.system(size: 12))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
        .foregroundStyle(AppTheme.textPrimary)
    }
}
