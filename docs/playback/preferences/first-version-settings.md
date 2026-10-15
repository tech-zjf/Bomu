# First-version settings

`PlaybackPreferences` owns installation-wide player defaults in `UserDefaults`; it does not mix preferences with per-file history in SQLite. Values are read when a file reaches the ready state or when the queue reaches its natural end:

- Default speed is constrained to the speeds supported by the playback controls.
- Default subtitle offset is constrained to ±30 seconds and is applied to each newly loaded file.
- Resume position and automatic queue advance can each be turned off independently.
- Appearance stays light in this release, matching the agreed baseline.

The Data tab clears the local playback-history table after explicit confirmation. The active file is marked as excluded from subsequent periodic saves so its row does not reappear immediately after clearing. Original media is never touched.

The Updates tab displays the installed version and states that update service is not available in this development build. Its action remains disabled until the signed update channel is implemented; no dormant preference pretends that checks are running.

The settings are presented through the native macOS Settings scene and standard labeled SwiftUI form controls, so they use the platform keyboard and VoiceOver navigation. Visible accessibility and localization review remains part of the unlocked-host acceptance pass.

## Verification

- App Debug build and app-host test-target compilation pass with the pinned Xcode 27.0 toolchain.
- The hostless logic target passes 24 tests, including preference persistence and value validation, applying defaults on media load, disabling automatic queue advance, and ensuring cleared history stays cleared for the current session.
- Manual inspection of the Settings scene, VoiceOver, and keyboard navigation is pending Screen 1 availability.
