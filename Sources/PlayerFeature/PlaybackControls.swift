import SwiftUI

struct PlaybackControls: View {
    let player: PlayerModel
    let toggleFullScreen: () -> Void
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedControl: Control?
    @State private var isScrubbing = false
    @State private var isAdjustingVolume = false
    @State private var scrubPosition = 0.0
    @State private var hoveredRegions: Set<Region> = []
    @State private var interaction = 0
    @State private var idleExpired = false

    private enum Region { case header, transport, timeline }
    private enum Control: Hashable { case stop, open, back, pause, forward, seek, volume, fullscreen }
    private struct HideTask: Equatable {
        let interaction: Int
        let isPinned: Bool
    }

    private var isPinned: Bool {
        player.isPaused || isScrubbing || isAdjustingVolume || focusedControl != nil || !hoveredRegions.isEmpty
    }

    private var isVisible: Bool { !idleExpired || isPinned }
    private var backgroundStyle: AnyShapeStyle {
        if reduceTransparency { return AnyShapeStyle(Color.black.opacity(0.9)) }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
                .onTapGesture { focusedControl = nil; reveal() }
            controls
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
        }
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        .onChange(of: player.isPaused) { _, _ in reveal() }
        .task(id: HideTask(interaction: interaction, isPinned: isPinned)) {
            guard !isPinned else { return }
            do {
                try await Task.sleep(for: .seconds(2.5))
                idleExpired = true
            } catch { /* A new interaction or pinned control cancels this deadline. */ }
        }
    }

    private var controls: some View {
        VStack {
            HStack {
                Button { player.stop() } label: { Label("player.stop", systemImage: "stop.fill") }
                    .focused($focusedControl, equals: .stop)
                Spacer()
                Text(player.state.request?.url.lastPathComponent ?? "")
                    .lineLimit(1)
                Spacer()
                Button { OpenMediaPanel.present(for: player) } label: {
                    Label("open.video", systemImage: "folder")
                }
                .focused($focusedControl, equals: .open)
            }
            .buttonStyle(.borderless)
            .padding(20)
            .background(backgroundStyle)
            .onHover { hover($0, in: .header) }
            Spacer()
            HStack(spacing: 26) {
                roundButton("player.back", icon: "gobackward.10", size: 62) { player.skip(by: -10) }
                    .focused($focusedControl, equals: .back)
                    .disabled(!player.canSeek)
                roundButton(player.isPaused ? "player.play" : "player.pause",
                            icon: player.isPaused ? "play.fill" : "pause.fill", size: 88) {
                    player.togglePause()
                }
                .focused($focusedControl, equals: .pause)
                roundButton("player.forward", icon: "goforward.10", size: 62) { player.skip(by: 10) }
                    .focused($focusedControl, equals: .forward)
                    .disabled(!player.canSeek)
            }
            .disabled(!player.canControlPlayback)
            .onHover { hover($0, in: .transport) }
            Spacer()
            timeline
                .padding(22)
                .background(backgroundStyle)
                .onHover { hover($0, in: .timeline) }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var timeline: some View {
        VStack(spacing: 12) {
            if let snapshot = player.state.snapshot, let duration = snapshot.duration {
                Slider(value: Binding(
                    get: { isScrubbing ? scrubPosition : min(duration, snapshot.position) },
                    set: { scrubPosition = $0 }
                ), in: 0...duration, onEditingChanged: { editing in
                    if editing { scrubPosition = snapshot.position }
                    isScrubbing = editing
                    if !editing { player.seek(to: scrubPosition) }
                })
                .disabled(!player.canSeek)
                .focused($focusedControl, equals: .seek)
                .accessibilityLabel(Text("player.seek"))
                HStack {
                    Text(Self.time(isScrubbing ? scrubPosition : snapshot.position))
                    Spacer()
                    Text(Self.time(duration))
                }
                .monospacedDigit()
            } else {
                Text("player.timeUnknown")
            }
            HStack {
                Image(systemName: "speaker.wave.2.fill")
                if let snapshot = player.state.snapshot {
                    Slider(value: Binding(
                        get: { snapshot.volume },
                        set: { player.setVolume($0) }
                    ), in: 0...100, onEditingChanged: { isAdjustingVolume = $0 })
                    .frame(width: 130)
                    .focused($focusedControl, equals: .volume)
                    .accessibilityLabel(Text("player.volume"))
                }
                Spacer()
                Button(action: toggleFullScreen) {
                    Label("player.fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.borderless)
                .focused($focusedControl, equals: .fullscreen)
            }
        }
        .font(.system(size: 13))
    }

    private func roundButton(_ label: LocalizedStringKey, icon: String, size: CGFloat,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size == 88 ? 39 : 27))
                .frame(width: size, height: size)
                .background(backgroundStyle, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    private func reveal() {
        idleExpired = false
        interaction += 1
    }

    private func hover(_ active: Bool, in region: Region) {
        if active { hoveredRegions.insert(region) } else { hoveredRegions.remove(region) }
        reveal()
    }

    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let total = Int(max(0, seconds))
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
