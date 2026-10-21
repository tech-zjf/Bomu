# First-version settings

`PlaybackPreferences` owns installation-wide playback defaults in `UserDefaults`. Per-file playback history stays in the media-library persistence layer; settings views do not access database types. The settings page lives in the main application window and opens on Appearance. Its five in-page vertical sections are Appearance, Playback, Subtitles, Storage, and About. Section selection is view state; preference values are persisted separately.

## Sections

- **Appearance** explains that this release uses a light interface and does not follow system Dark Mode.
- **Playback** controls resume from the last position, automatic queue advance, and default playback speed. Supported speeds are constrained to the values exposed by the player controls.
- **Subtitles** controls the default subtitle delay from −30 to +30 seconds in 0.5-second steps. The delay and speed are applied when a file reaches the ready state. Non-finite delay values are normalized to zero.
- **Storage** identifies local-only data, clears viewing history after confirmation, manages folders excluded from history, and imports, exports, or clears media-library records. Archive import is previewed before the user confirms applying it. These operations go through `MediaLibraryRecordOperations`; original media files are never moved or deleted.
- **About** displays the installed version and explains that update service is unavailable in the development build. The update action is disabled.

`PlaybackPreferences` applies safe bounds when values are loaded or changed. Default speed is normalized to the nearest supported speed; subtitle delay is clamped to its supported range. Resume and automatic-next preferences can be changed independently. Archive settings are applied through the same preference owner.

## Ownership and failure handling

`SettingsView` renders state and submits user actions. `PlaybackPreferences` owns player defaults; `PlayerModel` exposes playback-history actions; `MediaLibraryRecordOperations` coordinates library record and archive operations. Storage errors remain visible in Settings and do not affect the original media files. Import preparation is cancelled when Settings disappears or another record operation starts.

History clearing, data reset, and archive restore are coordinated by `MediaLibraryRecordOperations`; see [data management](../library/data-management.md) for scan/write draining, failure recovery, and exit ownership. Destructive history and library actions require an in-app confirmation.

## Verification and remaining acceptance

- Hostless logic coverage exercises preference persistence and validation, applying defaults on media load, and playback behavior that depends on resume and automatic-next settings. The full verification record is in [`v0.0-acceptance-todo.md`](../../engineering/roadmap/v0.0-acceptance-todo.md).
- The canonical Debug build uses the pinned Xcode 27.1 toolchain. Recent visible checks covered all five sections at 960×640, 1280×800, and 1440×900 pt and confirmed Storage content can be reached by scrolling. This establishes reachability only; exact visual comparison against the approved UI reference remains open.
- Keyboard navigation has been spot-checked for Settings controls. Full cross-page focus order and VoiceOver browsing remain open.
- The vertical navigation is a user-directed change from the horizontal tabs in [`UI设计稿.html`](../../../player_plan/开发定稿/UI设计稿.html); its 164 pt width is recorded in [`设计规范.json`](../../../player_plan/开发定稿/设计规范.json). The app implementation and reference are not pixel-identical for this change.
