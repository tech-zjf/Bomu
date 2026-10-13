import SwiftUI

struct PlayerScreen: View {
    let player: PlayerModel
    let videoView: NSView

    var body: some View {
        ZStack {
            Color.black
            VideoHostView(surface: videoView)
            switch player.state.phase {
            case .idle:
                StartView(error: player.startupError) { OpenMediaPanel.present(for: player) }
            case .opening:
                if let error = player.startupError {
                    message(error, symbol: "exclamationmark.triangle")
                } else {
                    ProgressView("player.loading").padding(24).background(.regularMaterial, in: Capsule())
                }
            case .ready:
                PlaybackControls(player: player) { videoView.window?.toggleFullScreen(nil) }
            case .ended:
                VStack(spacing: 16) {
                    Text("player.ended")
                    Button("player.replay") { player.togglePause() }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            case .failed(let error):
                message(error, symbol: "exclamationmark.triangle")
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear { player.prepare() }
    }

    private func message(_ text: String, symbol: String) -> some View {
        VStack(spacing: 18) {
            Image(systemName: symbol).font(.largeTitle)
            Text(text).multilineTextAlignment(.center).textSelection(.enabled)
            Button("open.another") { OpenMediaPanel.present(for: player) }
            Button("player.stop") { player.stop() }
        }
        .padding(32)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(AppTheme.textPrimary)
    }
}
