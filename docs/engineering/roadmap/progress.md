# Current development status

Last reviewed: 2026-10-15. The requirements and dependencies remain in [`开发任务.json`](../../../player_plan/开发定稿/开发任务.json). A task is complete only when its acceptance evidence exists; source code or a passing unit test alone is not sufficient.

## Verified baseline

- `./scripts/test-dev.sh --direct-hostless`: 135 Python tests and 99 XCTest cases passed, including the playback-command failure isolation regressions.
- `./scripts/build-dev.sh`: full Debug app and Objective-C bridge build passed with Xcode 27.0.
- `./scripts/build-dev.sh --analyze`: passed with Xcode 27.0.
- `./scripts/package-internal-dev.sh`: the arm64 internal DMG passed the 44-dylib / 47-Mach-O runtime-closure checks, ad-hoc signature verification, and `hdiutil verify`. SHA-256: `34b03ec76e5bbf5a34c2f15e2d2fb5f4dd33c675c5db3f4d206240b99659308e`.
- A04 media-matrix and A06 playback-path checks have completed for the currently supported local playback scope. The user confirmed normal audio and matching flash/audio events on the supplied test clips. This does not establish compatibility with every format or audio device.
- A05's pinned Xcode 27 / Swift 6.4 / arm64 development build and dependency checks are complete.

## Acceptance still open

| Area | Remaining evidence |
| --- | --- |
| A01, A02, C05 | Finish the manual user flows and visual acceptance. The current interface has been reviewed in one ordinary window, but overall design acceptance, all required window sizes, keyboard navigation, and VoiceOver are incomplete. |
| A03 | Competitor inspection is partial; the five acceptance flows and remaining competitor coverage are not complete. |
| A07 | Finish playback controls over video and the authorized fullscreen/display scenarios. No automatic fullscreen or cross-display test has been run. |
| A08 | Built-in display SDR and HDR-to-SDR smoke tests exist. External-display and calibrated color acceptance remain open; native HDR output is not implemented. |
| A09 | GPU activity and post-stop return-to-idle are unverified. The latest single-window run stopped after 17 pause/resume rounds when the observed display ID changed; it did not complete the soak or stop-baseline checks and is not a pass. |
| A10 | Depends on closing A07, A08, and A09. |
| B07, B09, B10, B11 | Complete cross-process resume and storage-failure checks; exercise real file/decoder errors and settings accessibility; and run sleep/wake recovery. Existing unit or short playback tests do not close these gates. |
| B12 | Install and launch the internal package on a clean Mac without Homebrew. Current package evidence is from the development Mac only. |
| C11 | The dependency provenance audit is complete for 44/44 runtime libraries, and original Bomu source/documentation now use MIT. Developer ID signing, notarization, Gatekeeper, license validation for a final release bundle, and release-package acceptance have not run. |
| C14 and later features | Recruit and record the planned external product trial before deciding dependent roadmap work. The rest of the task list remains active and must be completed in dependency order. |

Detailed playback, color, performance, packaging, and manual-acceptance evidence is kept with each feature in `docs/`. The internal DMG is a development artifact; it is not a public release.
