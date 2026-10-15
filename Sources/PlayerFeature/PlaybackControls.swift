import AppKit
import SwiftUI

struct PlaybackControls: View {
    let player: PlayerModel
    let onReturnToLibrary: () -> Void
    let toggleFullScreen: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var focusedControl: Control?
    @State private var isVoiceOverEnabled = false
    @State private var isScrubbing = false
    @State private var isAdjustingVolume = false
    @State private var scrubPosition = 0.0
    @State private var hoveredRegions: Set<Region> = []
    @State private var interaction = 0
    @State private var idleExpired = false

    private enum Region { case header, transport, timeline }
    private enum Control: Hashable { case back, stop, open, backSeek, pause, forward, seek, volume, fullscreen }

    private struct HideTask: Equatable {
        let interaction: Int
        let isPinned: Bool
    }

    private var isPinned: Bool {
        player.isPaused || isVoiceOverEnabled || isScrubbing || isAdjustingVolume
            || focusedControl != nil || !hoveredRegions.isEmpty
    }

    private var isVisible: Bool { !idleExpired || isPinned }

    private var panelBackground: Color {
        Color.black.opacity(reduceTransparency ? 0.9 : 0.56)
    }

    var body: some View {
        ZStack {
            if isVisible {
                edgeGradients
                    .transition(.opacity)
            }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focusedControl = nil; reveal() }
            controls
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
                .animation(.easeOut(duration: 0.18), value: isVisible)
        }
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled, options: [.initial, .new])) {
            isVoiceOverEnabled = $0
        }
        .onChange(of: player.isPaused) { _, _ in reveal() }
        .task(id: HideTask(interaction: interaction, isPinned: isPinned)) {
            guard !isPinned else { return }
            do {
                try await Task.sleep(for: .seconds(AppTheme.PlayerControls.autoHideSeconds))
                idleExpired = true
            } catch { /* A fresh interaction replaces the pending hide deadline. */ }
        }
    }

    private var edgeGradients: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.62), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 104)
            Spacer(minLength: 0)
            LinearGradient(colors: [.clear, .black.opacity(0.68)], startPoint: .top, endPoint: .bottom)
                .frame(height: 128)
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 15)
                .padding(.top, 14)
                .onHover { hover($0, in: .header) }
            Spacer(minLength: 12)
            HStack(spacing: AppTheme.PlayerControls.buttonGap) {
                roundButton("player.back", icon: "gobackward.10",
                            size: AppTheme.PlayerControls.skipButtonSize,
                            iconSize: AppTheme.PlayerControls.skipIconSize) { player.skip(by: -10) }
                    .focused($focusedControl, equals: .backSeek)
                    .disabled(!player.canSeek)
                roundButton(player.isPaused ? "player.play" : "player.pause",
                            icon: player.isPaused ? "play.fill" : "pause.fill",
                            size: AppTheme.PlayerControls.centralButtonSize,
                            iconSize: AppTheme.PlayerControls.primaryIconSize) {
                    player.togglePause()
                }
                .focused($focusedControl, equals: .pause)
                roundButton("player.forward", icon: "goforward.10",
                            size: AppTheme.PlayerControls.skipButtonSize,
                            iconSize: AppTheme.PlayerControls.skipIconSize) { player.skip(by: 10) }
                    .focused($focusedControl, equals: .forward)
            }
            .disabled(!player.canControlPlayback)
            .onHover { hover($0, in: .transport) }
            Spacer(minLength: 12)
            timeline
                .padding(.horizontal, AppTheme.Layout.playerHorizontalInset)
                .padding(.vertical, 12)
                .padding(.bottom, 9)
                .onHover { hover($0, in: .timeline) }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onReturnToLibrary) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 35, height: 35)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .back)
            .accessibilityLabel(Text("library.backToLibrary"))

            Text(player.state.request?.url.lastPathComponent ?? "")
                .font(AppTheme.Typography.playerFileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420, alignment: .leading)

            Spacer(minLength: 8)
            toolbarButton("player.stop", icon: "stop.fill") { player.stop() }
                .focused($focusedControl, equals: .stop)
            toolbarButton("open.video", icon: "folder") { OpenMediaPanel.present(for: player) }
                .focused($focusedControl, equals: .open)
            speedMenu
            audioMenu
            subtitlesMenu
            queueMenu
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                Button {
                    player.setSpeed(speed)
                } label: {
                    let title = "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
                    if abs((player.state.snapshot?.speed ?? 1) - speed) < 0.01 {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            toolbarIcon("speedometer")
        }
        .disabled(!player.canControlPlayback)
        .accessibilityLabel(Text("player.speed"))
        .help(Text("player.speed"))
    }

    private var audioMenu: some View {
        Menu {
            ForEach(player.state.snapshot?.tracks.filter { $0.kind == .audio } ?? []) { track in
                Button {
                    player.selectAudioTrack(track.id)
                } label: {
                    trackMenuLabel(track, selected: track.isSelected)
                }
            }
        } label: {
            toolbarIcon("waveform")
        }
        .disabled(player.state.snapshot?.tracks.contains { $0.kind == .audio } != true)
        .accessibilityLabel(Text("player.audioTracks"))
        .help(Text("player.audioTracks"))
    }

    private var subtitlesMenu: some View {
        Menu {
            let subtitles = player.state.snapshot?.tracks.filter { $0.kind == .subtitle } ?? []
            Button {
                player.selectSubtitleTrack(0)
            } label: {
                if subtitles.contains(where: \.isSelected) {
                    Label("player.subtitleOff", systemImage: "checkmark")
                } else {
                    Text("player.subtitleOff")
                }
            }
            ForEach(subtitles) { track in
                Button {
                    player.selectSubtitleTrack(track.id)
                } label: {
                    trackMenuLabel(track, selected: track.isSelected)
                }
            }
            Divider()
            Button("player.loadExternalSubtitle") { OpenMediaPanel.presentSubtitle(for: player) }
            Menu("player.subtitleDelay") {
                let delay = player.state.snapshot?.subtitleDelay ?? 0
                HStack {
                    Text("player.subtitleOffsetValue")
                    Spacer()
                    Text(delay, format: .number.precision(.fractionLength(1)))
                    Text("settings.seconds")
                }
                Button("player.subtitleReset") { player.resetSubtitleDelay() }
                    .disabled(abs(delay) < 0.01 || !player.canControlPlayback)
                Divider()
                Button("player.subtitleEarlier") { player.adjustSubtitleDelay(by: -0.5) }
                Button("player.subtitleLater") { player.adjustSubtitleDelay(by: 0.5) }
            }
            .disabled(!player.canControlPlayback)
        } label: {
            toolbarIcon("captions.bubble")
        }
        .disabled(!player.canControlPlayback)
        .accessibilityLabel(Text("player.subtitles"))
        .help(Text("player.subtitles"))
    }

    private var queueMenu: some View {
        Menu {
            Button("player.previousItem") { player.playPrevious() }
                .disabled(player.queue.previousURL == nil)
            Button("player.nextItem") { player.playNext() }
                .disabled(player.queue.nextURL == nil)
            Divider()
            ForEach(Array(player.queue.items.enumerated()), id: \.offset) { index, url in
                Button {
                    player.playQueueItem(at: index)
                } label: {
                    if index == player.queue.currentIndex {
                        Label(url.lastPathComponent, systemImage: "checkmark")
                    } else {
                        Text(url.lastPathComponent)
                    }
                }
            }
        } label: {
            toolbarIcon("list.number")
        }
        .disabled(player.queue.items.isEmpty)
        .accessibilityLabel(Text("player.queue"))
        .help(Text("player.queue"))
    }

    private var timeline: some View {
        HStack(spacing: 11) {
            if let snapshot = player.state.snapshot,
               let duration = snapshot.duration,
               duration.isFinite, duration > 0 {
                Text(Self.time(isScrubbing ? scrubPosition : snapshot.position))
                    .frame(minWidth: 38, alignment: .leading)
                Slider(value: Binding(
                    get: { isScrubbing ? scrubPosition : min(duration, max(0, snapshot.position)) },
                    set: { scrubPosition = $0 }
                ), in: 0...duration, onEditingChanged: { editing in
                    if editing { scrubPosition = snapshot.position }
                    isScrubbing = editing
                    if !editing { player.seek(to: scrubPosition) }
                })
                .disabled(!player.canSeek)
                .focused($focusedControl, equals: .seek)
                .accessibilityLabel(Text("player.seek"))
                .tint(.white)
                Text("−\(Self.time(max(0, duration - (isScrubbing ? scrubPosition : snapshot.position))))")
                    .frame(minWidth: 45, alignment: .trailing)
            } else {
                Text("player.timeUnknown")
                Spacer(minLength: 8)
            }

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 12))
                .accessibilityHidden(true)
            if let snapshot = player.state.snapshot {
                Slider(value: Binding(
                    get: { min(100, max(0, snapshot.volume)) },
                    set: { player.setVolume($0) }
                ), in: 0...100, onEditingChanged: { isAdjustingVolume = $0 })
                .frame(width: 70)
                .focused($focusedControl, equals: .volume)
                .accessibilityLabel(Text("player.volume"))
                .tint(.white)
            }
            Button(action: toggleFullScreen) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .fullscreen)
            .accessibilityLabel(Text("player.fullscreen"))
            .help(Text("player.fullscreen"))
        }
        .font(AppTheme.Typography.timeReadout)
    }

    private func toolbarButton(_ label: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolbarIcon(icon) }
            .accessibilityLabel(Text(label))
            .help(Text(label))
    }

    private func toolbarIcon(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 12, weight: .medium))
            .frame(width: 35, height: 35)
            .contentShape(Rectangle())
    }

    private func roundButton(_ label: LocalizedStringKey, icon: String, size: CGFloat, iconSize: CGFloat,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: iconSize))
                .frame(width: size, height: size)
                .background(panelBackground, in: Circle())
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private func trackMenuLabel(_ track: PlaybackTrack, selected: Bool) -> some View {
        let details = [track.language, track.title]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
        let title = details.isEmpty ? String(format: String(localized: "player.trackNumber"), track.id) : details.joined(separator: " · ")
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
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
