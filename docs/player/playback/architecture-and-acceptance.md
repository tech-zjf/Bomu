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

`OpenMediaPanel` presents the native video or subtitle picker as a sheet on Bomu's ordinary window. It prefers AppKit's main window and, for an accessibility action delivered while the app is inactive, falls back only to a visible window that can become main and is not a panel. An attached sheet prevents a second picker. Cancel leaves the playback request unchanged; a selected video URL goes to `PlayerModel.open`, while an external subtitle is submitted with the current request ID. This window lookup does not add a second playback session or import/copy the selected media.

Playback phase is modeled as `idle`, `opening`, `ready`, `ended`, or `failed`; seeking and buffering are derived activity states. Request IDs gate late native callbacks after a fast file switch. Shutdown is asynchronous and waits for the session's native resources to release. The OpenGL renderer runs on its own serial queue with an explicit context lock and clears its borrowed mpv core pointer before core teardown.

## UI geometry

The player page applies the shared 30 pt horizontal and 28 pt vertical content insets. Its stage adds the 12 pt inset from the design's `.m-play-layout`, giving 42 pt horizontal edges and a 40 pt top edge relative to the main content origin. The stage remains 16:9; source video preserves its own aspect ratio and is fitted inside that stage. Remaining space below the fixed stage depends on the window's available height. Media details are opened from the in-stage Video information control and do not add a row below the stage. Failure-state engine details are collapsed behind a “Technical details” disclosure so the primary message and recovery actions fit at the 900×600 pt minimum window size.

## Verification evidence

- Locked toolchain: Xcode 27.1, Swift 6.4, macOS SDK 27.0.
- 2026-10-23 native picker parent-window fallback: `./scripts/build-dev.sh --analyze` succeeded after allowing Xcode access to its SwiftPM manifest cache. A same-window desktop attempt to raise the newly launched Debug app timed out before any picker state was returned, so the fallback has compile/static-analysis evidence only. The video and subtitle picker actions require a fresh visible foreground check; no panel success is claimed from that attempt.
- 2026-10-21 code/documentation audit while the desktop was unavailable: `./scripts/build-dev.sh` and `./scripts/build-dev.sh --analyze` passed. `./scripts/test-dev.sh --direct-hostless` passed 148 Python checks and 178 XCTest cases with 0 failures; 2 disposable-volume cases were skipped by that mode. `./scripts/test-dev.sh --direct-storage` then passed both APFS sparse-image cases (full-volume recovery and remount identity/history). No new lifecycle, actor-boundary, or ownership defect was identified in the inspected playback, archive, scan, and thumbnail paths.
- `./scripts/build-dev.sh` and `./scripts/build-dev.sh --analyze` passed for the stage layout correction and collapsed failure-detail disclosure. `plutil -lint` passed for both English and Simplified Chinese string catalogs; the Chinese catalog remains excluded from the app's enabled localization list.
- Later full local logic/storage evidence is recorded in [`progress.md`](../../engineering/roadmap/progress.md): 148 Python checks, 182 hostless XCTest cases, and 2 direct APFS storage cases passed on 2026-10-22.
- The current canonical Debug build was visibly checked in one ordinary window at 900×600, 960×640, 1280×800, and 1440×900 pt. At 900×600, the failure state showed its main actions with technical details collapsed; the portrait clip displayed a 9:16 frame filling the fixed 16:9 stage height with centered side bars. A 1470×630 (7:3) clip filled the stage width with vertical letterboxing; opening the in-stage information card left the stage unchanged. After the latest rebuild, the 7:3 clip was rechecked at 960×640, 1280×800 and 1440×900 pt with the same fixed-stage geometry. At the three standard sizes, captures measured 1922×1282, 2562×1602, and 2882×1802 backing pixels respectively, including the 2 px frame. At each checked size the stage retained approximately 16:9 without a metadata footer or visible scrollbar. At 1440×900, opening Video information kept the card inside the stage and did not change stage dimensions; playback position continued advancing.
- At 960×640, the 33-minute H.264/AAC sample advanced from about 20:57 to 22:28. At 1280×800 and 1440×900, the same sample continued advancing during layout checks. The captured frame was black, so these observations do not prove visible image quality, color accuracy, or synchronization.
- A later visible playback of `.build/media-suite/06-portrait.mp4` showed decoded BT.709 color bars at about 0:04 in the current larger window, while retaining the 9:16 fit inside the fixed 16:9 stage. This proves visible decoded output only; color accuracy, brightness mapping and display calibration remain unverified.
- 2026-10-23 failure-to-success chain in the canonical Debug app at 1440×900 pt: searching `16-invalid.mp4` found the indexed 41-byte file; Play reached the in-stage decode-failure page with Retry, Open Another Video, Back to Library and collapsed Technical details. Retry returned to the same stable failure state. Back to Library preserved the `16-invalid` query and result. Replacing the query with `07-square` and playing the valid generated 720×720 H.264/AAC clip produced a real visible frame in the fixed 16:9 stage, with the square content fitted by height and side bars, then reached the natural Playback finished page. Returning to Search and clearing the query restored its empty state. The valid clip acquired a new playback checkpoint during this test. This proves error recovery and the next file's decode path for these two fixtures at this size; it does not prove sound, calibrated color, every codec, or the other two standard sizes.
- 2026-10-23 replay-start check: the generated 30-second `29-sync.mov` reached natural completion in the canonical Debug app at 960×640 pt. Play Again returned to active playback; the next AX read, 5.3 seconds after the action began, showed 0:04.88 and Pause. This is consistent with a start near zero and rules out resuming from the previous near-end position. The model's replay path opens with `.beginning`, and `PlayerModelTests.testReplayStartsAtBeginningEvenWhenResumePreferenceIsEnabled` checks that history does not supply a start position or follow-up seek. The visible read cannot prove the exact first frame, and queue advance remains untested in this run.
- One user-performed sleep attempt logged Software Sleep followed by HID-triggered FullWake in the same second. Later attempts, including the 15:16 report, produced no new Sleep/Wake event in `pmset -g log`; the latest Bomu view was Home with the short sample paused at 0:00. No meaningful sleep interval with long-sample recovery has been verified, so this gate remains open.

## Open acceptance items

- Compare every required page and state against the visual source and token file, record concrete deltas, and recheck after each correction. A matching stage ratio is not a pixel-identity claim.
- Finish the v0.0 playback state matrix after the corrected outer page inset. Portrait and ultrawide geometry now have standard-size visible evidence, and replay has a near-zero spot check; color, audio synchronization, seek/pause edge cases, and exact restart timing still need their respective acceptance evidence. Queue ordering and automatic advance are B06 in the approved v0.1 plan; only the current queue control's visual and accessibility presentation belongs to the v0.0 A02 review.
- Record a longer scroll/flicker observation in Home, Library, and Folders; finish the VoiceOver traversal and confirm behavior with audible announcements.
- Repeat sleep/wake with a meaningful sleep interval and confirm the resumed frame and playhead.
- `PlaybackHistoryStore.swift` is 1,524 lines and currently groups migrations/identity, scan transactions, playback history, archive import/export, and privacy exclusions in one actor. It preserves one database owner and transaction boundary, but remains the main maintainability hotspot; split only when a concrete change/test boundary requires it.

Two attached reports from 2026-10-19 describe `0.0.1 (2)` aborting during `NSApplication.init` in `HIServices` application registration, before Bomu code runs. The current Debug build starts and plays. Do not change application lifecycle speculatively; reopen this issue if a current-build reproduction produces a fresh crash report and unified log.
