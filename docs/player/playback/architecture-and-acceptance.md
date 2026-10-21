# Playback implementation and acceptance

This note records the shipped v0.0 playback path and the evidence gathered from the current Debug build. The product and visual acceptance baselines remain [`Mori播放器开发定稿.html`](../../../player_plan/开发定稿/Mori播放器开发定稿.html), [`UI设计稿.html`](../../../player_plan/开发定稿/UI设计稿.html), and [`设计规范.json`](../../../player_plan/开发定稿/设计规范.json).

## Ownership and call path

```text
AppLifecycle
  ├─ owns one MPVPlaybackEngine and one PlayerModel
  ├─ shuts down library work, then the player during app termination
  └─ owns persisted history/preferences and injects them into features

PlayerScreen / PlaybackControls
  └─ render PlaybackState and submit intents to PlayerModel
       ├─ PlaybackState rejects events for replaced or terminal requests
       ├─ PlaybackQueue owns the ordered local file sequence
       ├─ PlaybackHistoryStore persists identity, resume and library facts
       └─ MPVPlaybackEngine translates domain commands/events at the boundary
            └─ BMMPVSession owns libmpv, command/event queue and lifecycle
                 └─ BMVideoSurface / BMGLRenderer owns OpenGL render context
                      └─ VideoHostView presents the stable AppKit surface
```

`PlayerModel` is `@MainActor` and owns logical request IDs, pause command IDs, startup/restoration/import tasks, and persisted playback coordination. UI code receives no mpv handle. Native playback events are converted once in `MPVPlaybackEngine`; the session's main-queue callback contract is checked before updating feature state. The render surface is created by the session and injected into SwiftUI, so SwiftUI view recomputation does not create a second playback session.

Playback phase is modeled as `idle`, `opening`, `ready`, `ended`, or `failed`; seeking and buffering are derived activity states. Request IDs gate late native callbacks after a fast file switch. Shutdown is asynchronous and waits for the session's native resources to release. The OpenGL renderer runs on its own serial queue with an explicit context lock and clears its borrowed mpv core pointer before core teardown.

## UI geometry

The player page applies the shared 30 pt horizontal and 28 pt vertical content insets. Its stage adds the 12 pt inset from the design's `.m-play-layout`, giving 42 pt horizontal edges and a 40 pt top edge relative to the main content origin. The stage remains 16:9; source video preserves its own aspect ratio and is fitted inside that stage. Remaining space below the fixed stage depends on the window's available height. Media details are opened from the in-stage Video information control and do not add a row below the stage.

## Verification evidence

- Locked toolchain: Xcode 27.1, Swift 6.4, macOS SDK 27.0.
- `./scripts/build-dev.sh` and `./scripts/build-dev.sh --analyze` passed for the stage layout correction.
- Latest full local logic/storage evidence is recorded in [`progress.md`](../../engineering/roadmap/progress.md): 148 Python checks, 178 hostless XCTest cases, and 2 direct APFS storage cases passed. These checks were run before the most recent documentation-only commits.
- The current canonical Debug build was visibly checked in one ordinary window at 960×640, 1280×800, and 1440×900 pt. Captures measured 1922×1282, 2562×1602, and 2882×1802 backing pixels respectively, including the 2 px frame. At each size the stage retained approximately 16:9 without a metadata footer or visible scrollbar. At 1440×900, opening Video information kept the card inside the stage and did not change stage dimensions; playback position continued advancing.
- At 960×640, the 33-minute H.264/AAC sample advanced from about 20:57 to 22:28. At 1280×800 and 1440×900, the same sample continued advancing during layout checks. The captured frame was black, so these observations do not prove visible image quality, color accuracy, or synchronization.
- One user-performed sleep attempt logged Software Sleep followed by HID-triggered FullWake in the same second. Playback remained active afterward, but the sleep interval was too short to close the sleep/wake recovery gate.

## Open acceptance items

- Compare every required page and state against the visual source and token file, record concrete deltas, and recheck after each correction. A matching stage ratio is not a pixel-identity claim.
- Recheck portrait and ultrawide fit after the corrected outer page inset; verify visible content, color, audio synchronization, seek, pause/resume, and ending/replay states with licensed samples.
- Record a longer scroll/flicker observation in Home, Library, and Folders; finish the VoiceOver traversal and confirm behavior with audible announcements.
- Repeat sleep/wake with a meaningful sleep interval and confirm the resumed frame and playhead.
- `PlaybackHistoryStore.swift` is 1,524 lines and currently groups migrations/identity, scan transactions, playback history, archive import/export, and privacy exclusions in one actor. It preserves one database owner and transaction boundary, but remains the main maintainability hotspot; split only when a concrete change/test boundary requires it.

Two attached reports from 2026-10-19 describe `0.0.1 (2)` aborting during `NSApplication.init` in `HIServices` application registration, before Bomu code runs. The current Debug build starts and plays. Do not change application lifecycle speculatively; reopen this issue if a current-build reproduction produces a fresh crash report and unified log.
