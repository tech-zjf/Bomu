import AppKit
import SwiftUI

struct PlaybackControls: View {
    let player: PlayerModel
    let onReturnToLibrary: () -> Void
    let toggleFullScreen: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedControl: Control?
    @State private var isVoiceOverEnabled = false
    @State private var isScrubbing = false
    @State private var isAdjustingVolume = false
    @State private var scrubPosition = 0.0
    @State private var hoveredRegions: Set<Region> = []
    @State private var interaction = 0
    @State private var idleExpired = false

    private enum Region { case header, transport, timeline }
    private enum Control: Hashable { case back, stop, open, speed, audio, subtitles, queue, backSeek, pause, forward, seek, volume, fullscreen }

    private struct HideTask: Equatable {
        let interaction: Int
        let isPinned: Bool
    }

    private var isPinned: Bool {
        player.isPaused || isVoiceOverEnabled || isScrubbing || isAdjustingVolume
            || player.state.activity != nil || focusedControl != nil || !hoveredRegions.isEmpty
    }

    private var isVisible: Bool { !idleExpired || isPinned }

    private var panelBackground: Color {
        AppTheme.playerControlBackground(reduceTransparency: reduceTransparency)
    }

    var body: some View {
        ZStack {
            if isVisible && !reduceTransparency {
                edgeGradients
                    .transition(reduceMotion ? .identity : .opacity)
            }
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { focusedControl = nil; reveal() }
            controls
                .opacity(isVisible ? 1 : 0)
                .allowsHitTesting(isVisible)
                .accessibilityHidden(!isVisible)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isVisible)
        }
        .onContinuousHover { phase in
            if case .active = phase { reveal() }
        }
        .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled, options: [.initial, .new])) {
            isVoiceOverEnabled = $0
        }
        .onChange(of: player.isPaused) { _, _ in reveal() }
        .onChange(of: player.state.activity) { _, _ in reveal() }
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
                .background(reduceTransparency ? AppTheme.playerFallback : .clear,
                            in: RoundedRectangle(cornerRadius: AppTheme.Corners.control))
                .padding(.horizontal, 15)
                .padding(.top, 14)
                .onHover { hover($0, in: .header) }
            Spacer(minLength: 12)
            HStack(spacing: AppTheme.PlayerControls.buttonGap) {
                roundButton("player.back", icon: "gobackward.10",
                            size: AppTheme.PlayerControls.skipButtonSize,
                            iconFont: AppTheme.Typography.Symbol.playerSkipTransport) {
                    player.skip(by: -10)
                }
                    .focused($focusedControl, equals: .backSeek)
                    .disabled(!player.canSeek)
                roundButton(player.isPaused ? "player.play" : "player.pause",
                            icon: player.isPaused ? "play.fill" : "pause.fill",
                            size: AppTheme.PlayerControls.centralButtonSize,
                            iconFont: AppTheme.Typography.Symbol.playerPrimaryTransport) {
                    player.togglePause()
                }
                .focused($focusedControl, equals: .pause)
                roundButton("player.forward", icon: "goforward.10",
                            size: AppTheme.PlayerControls.skipButtonSize,
                            iconFont: AppTheme.Typography.Symbol.playerSkipTransport) {
                    player.skip(by: 10)
                }
                    .focused($focusedControl, equals: .forward)
                    .disabled(!player.canSeek)
            }
            .disabled(!player.canControlPlayback)
            .onHover { hover($0, in: .transport) }
            Spacer(minLength: 12)
            timeline
                .padding(.horizontal, AppTheme.Layout.playerHorizontalInset)
                .padding(.vertical, 12)
                .background(reduceTransparency ? AppTheme.playerFallback : .clear,
                            in: RoundedRectangle(cornerRadius: AppTheme.Corners.control))
                .padding(.bottom, 9)
                .onHover { hover($0, in: .timeline) }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button(action: onReturnToLibrary) {
                PlayerToolbarIcon(symbol: "chevron.left")
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .back)
            .accessibilityLabel(Text("library.backToLibrary"))

            Text(player.state.request?.url.lastPathComponent ?? "")
                .font(AppTheme.Typography.playerFileName)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 420, alignment: .leading)

            if let activity = player.state.activity {
                ProgressView(activity.label)
                    .controlSize(.small)
                    .font(AppTheme.Typography.caption)
                    .fixedSize()
            }

            Spacer(minLength: 8)
            toolbarButton("player.stop", icon: "stop.fill") { player.stop() }
                .focused($focusedControl, equals: .stop)
            toolbarButton("open.video", icon: "folder") { OpenMediaPanel.present(for: player) }
                .focused($focusedControl, equals: .open)
            speedMenu.focused($focusedControl, equals: .speed)
            audioMenu.focused($focusedControl, equals: .audio)
            subtitlesMenu.focused($focusedControl, equals: .subtitles)
            queueMenu.focused($focusedControl, equals: .queue)
        }
        .buttonStyle(.plain)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    private var speedMenu: some View {
        Menu {
            if let requestID = player.state.request?.id {
                ForEach(PlaybackPreferences.supportedSpeeds, id: \.self) { speed in
                    Button {
                        player.setSpeed(speed, requestID: requestID)
                    } label: {
                        let title = "\(speed.formatted(.number.precision(.fractionLength(0...2))))×"
                        if abs((player.state.snapshot?.speed ?? 1) - speed) < 0.01 {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            }
        } label: {
            PlayerToolbarIcon(symbol: "speedometer")
        }
        .disabled(!player.canControlPlayback)
        .accessibilityLabel(Text("player.speed"))
        .help(Text("player.speed"))
    }

    private var audioMenu: some View {
        Menu {
            if let requestID = player.state.request?.id {
                let tracks = player.state.snapshot?.tracks.filter { $0.kind == .audio } ?? []
                ForEach(tracks) { track in
                    Button {
                        player.selectAudioTrack(track.id, requestID: requestID)
                    } label: {
                        trackMenuLabel(track, among: tracks)
                    }
                }
            }
        } label: {
            PlayerToolbarIcon(symbol: "waveform")
        }
        .disabled(player.state.snapshot?.tracks.contains { $0.kind == .audio } != true)
        .accessibilityLabel(Text("player.audioTracks"))
        .help(Text("player.audioTracks"))
    }

    private var subtitlesMenu: some View {
        Menu {
            if let requestID = player.state.request?.id {
                let subtitles = player.state.snapshot?.tracks.filter { $0.kind == .subtitle } ?? []
                Button {
                    player.selectSubtitleTrack(0, requestID: requestID)
                } label: {
                    if !subtitles.contains(where: \.isSelected) {
                        Label("player.subtitleOff", systemImage: "checkmark")
                    } else {
                        Text("player.subtitleOff")
                    }
                }
                ForEach(subtitles) { track in
                    Button {
                        player.selectSubtitleTrack(track.id, requestID: requestID)
                    } label: {
                        trackMenuLabel(track, among: subtitles)
                    }
                }
                Divider()
                Button("player.loadExternalSubtitle") {
                    OpenMediaPanel.presentSubtitle(for: player, requestID: requestID)
                }
                Menu("player.subtitleDelay") {
                    let delay = player.state.snapshot?.subtitleDelay ?? 0
                    HStack {
                        Text("player.subtitleOffsetValue")
                        Spacer()
                        Text(delay, format: .number.precision(.fractionLength(1)))
                        Text("settings.seconds")
                    }
                    Button("player.subtitleReset") { player.resetSubtitleDelay(requestID: requestID) }
                        .disabled(abs(delay) < 0.01 || !player.canControlPlayback)
                    Divider()
                    Button("player.subtitleEarlier") { player.adjustSubtitleDelay(by: -0.5, requestID: requestID) }
                    Button("player.subtitleLater") { player.adjustSubtitleDelay(by: 0.5, requestID: requestID) }
                }
                .disabled(!player.canControlPlayback)
            }
        } label: {
            PlayerToolbarIcon(symbol: "captions.bubble")
        }
        .disabled(!player.canControlPlayback)
        .accessibilityLabel(Text("player.subtitles"))
        .help(Text("player.subtitles"))
    }

    private var queueMenu: some View {
        PlaybackQueueMenu(player: player)
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
                    if !editing { player.seek(to: scrubPosition, requestID: snapshot.requestID) }
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
                .font(AppTheme.Typography.Symbol.playerVolume)
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
                PlayerToolbarIcon(symbol: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.plain)
            .focused($focusedControl, equals: .fullscreen)
            .accessibilityLabel(Text("player.fullscreen"))
            .help(Text("player.fullscreen"))
        }
        .font(AppTheme.Typography.timeReadout)
    }

    private func toolbarButton(_ label: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { PlayerToolbarIcon(symbol: icon) }
            .accessibilityLabel(Text(label))
            .help(Text(label))
    }

    private func roundButton(_ label: LocalizedStringKey, icon: String, size: CGFloat, iconFont: Font,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(iconFont)
                .frame(width: size, height: size)
                .background(panelBackground, in: Circle())
                .contentShape(Circle())
                .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }

    @ViewBuilder
    private func trackMenuLabel(_ track: PlaybackTrack, among tracks: [PlaybackTrack]) -> some View {
        let title = trackMenuTitle(track, among: tracks)
        if track.isSelected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    private func trackMenuTitle(_ track: PlaybackTrack, among tracks: [PlaybackTrack]) -> String {
        var title = trackMenuBaseTitle(track)
        let duplicateCount = tracks.filter { trackMenuBaseTitle($0) == title }.count
        if duplicateCount > 1 {
            title += " · \(String(format: String(localized: "player.trackNumber"), track.id))"
        }
        return title
    }

    private func trackMenuBaseTitle(_ track: PlaybackTrack) -> String {
        let details = [track.language, track.title]
            .compactMap { rawValue -> String? in
                guard let rawValue else { return nil }
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return value
            }
        var title = details.isEmpty
            ? String(format: String(localized: "player.trackNumber"), track.id)
            : details.joined(separator: " · ")
        if track.isExternal {
            title += " · \(String(localized: "player.track.external"))"
        }
        return title
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

private extension PlaybackState.Activity {
    var label: LocalizedStringKey {
        switch self {
        case .opening: "player.loading"
        case .seeking: "player.seeking"
        case .buffering: "player.buffering"
        }
    }
}

struct PlaybackQueueMenu: View {
    let player: PlayerModel

    var body: some View {
        Menu {
            if let requestID = player.state.request?.id, let currentIndex = player.queue.currentIndex {
                Button("player.previousItem") {
                    player.playQueueItem(at: currentIndex - 1, requestID: requestID)
                }
                .disabled(player.queue.previousURL == nil)
                Button("player.nextItem") {
                    player.playQueueItem(at: currentIndex + 1, requestID: requestID)
                }
                .disabled(player.queue.nextURL == nil)
                Divider()
                ForEach(Array(player.queue.items.enumerated()), id: \.offset) { index, url in
                    Button {
                        player.playQueueItem(at: index, requestID: requestID)
                    } label: {
                        if index == currentIndex {
                            Label(url.lastPathComponent, systemImage: "checkmark")
                        } else {
                            Text(url.lastPathComponent)
                        }
                    }
                }
            }
        } label: {
            PlayerToolbarIcon(symbol: "list.number")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .disabled(player.queue.items.isEmpty)
        .accessibilityLabel(Text("player.queue"))
        .help(Text("player.queue"))
    }
}

/** 工具栏按钮与菜单共享图标、完整命中范围和尺寸，菜单内容仍由系统呈现。 */
private struct PlayerToolbarIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(AppTheme.Typography.Symbol.playerToolbar)
            .frame(width: AppTheme.Layout.toolbarControlSize, height: AppTheme.Layout.toolbarControlSize)
            .contentShape(Rectangle())
    }
}
