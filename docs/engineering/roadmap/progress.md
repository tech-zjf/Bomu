# Current development status

Last reviewed: 2026-10-15. The requirements and dependencies remain in [`开发任务.json`](../../../player_plan/开发定稿/开发任务.json). A task is complete only when its acceptance evidence exists; source code or a passing unit test alone is not sufficient.

## Verified baseline

- `./scripts/test-dev.sh --direct-hostless`: 139 Python tests and 100 XCTest cases passed, including playback-command failure isolation and unavailable-metadata presentation regressions.
- `./scripts/build-dev.sh`: full Debug app and Objective-C bridge build passed with Xcode 27.0.
- `./scripts/build-dev.sh --analyze`: passed with Xcode 27.0.
- `./scripts/package-internal-dev.sh`: the arm64 internal DMG passed the 44-dylib / 47-Mach-O runtime-closure checks, ad-hoc signature verification, and `hdiutil verify`. SHA-256: `34b03ec76e5bbf5a34c2f15e2d2fb5f4dd33c675c5db3f4d206240b99659308e`.
- A04 media-matrix and A06 playback-path checks have completed for the currently supported local playback scope. The user confirmed normal audio and matching flash/audio events on the supplied test clips. This does not establish compatibility with every format or audio device.
- A05's pinned Xcode 27 / Swift 6.4 / arm64 development build and dependency checks are complete.
- A09's full local baseline completed on 2026-10-15 with `./scripts/benchmark-dev.sh --playback` on Apple M5 / macOS 26.7.1. Playback CPU was 12.37% and stopped CPU 0.16%; benchmark-only OpenGL elapsed queries recorded 573.545 ms across 243 completed intervals during playback and no interval or query growth after stop. All 100 real file switches completed; ten footprint checkpoints ranged from 205.1–222.5 MiB, with first/last checkpoint-window medians differing by +7.2 MiB and no continuous upward trend. The raw task GPU-utilisation counter remained 0 and is not interpreted as idle. Details and measurement limits are in [`benchmark.md`](../../playback/native-poc/benchmark.md); raw run files remain local under `.build/benchmarks/20261015-201150/`.

## Acceptance still open

| Area | Remaining evidence |
| --- | --- |
| A01, A02, C05 | A01's five repeatable user flows are documented in `docs/product/acceptance-tasks.md`; the required visual-style acceptance is still open, so A01 remains in progress. The native library uses shared minimum-window, grid, section-spacing, player inset, and text-style tokens; its media cards and list rows implement select-on-single-click and play-on-double-click. When AVFoundation has no compact technical attributes, cards and rows now show actual file size, and accessibility summaries omit repeated unknown values. Behavior tests, the updated Debug build, and static analysis pass. Single-window Debug checks at the current large size confirmed the grid card and folder-list row show the actual-size fallback and matching accessibility-tree value. Intentional radius differences from the HTML prototype are now recorded in `player_plan/开发定稿/设计规范.json`; visual sign-off remains open. Keyboard navigation has partial evidence: forward Tab reaches the sidebar and main-pane controls in order with a visible focus ring, but Shift+Tab from the first main-pane control gets stuck instead of returning to the sidebar. A02/C05 remain open for this issue, the remaining window sizes, visual comparison, and VoiceOver acceptance. |
| A03 | IINA 1.5.0 paths were explored, but the recorded Owl 1.9.2 binary does not match the official release listing; its provenance must be resolved and the official build retested before completing the five-path comparison. Remaining competitor coverage is also incomplete. |
| A07 | One 2026-10-15 restore check briefly showed embedded video timecode 5.533 s while the player reported 9.233 s. Restore now passes the validated history position into libmpv's `loadfile` start option. Fresh Xcode 27 native runs pass: the first snapshot begins at a requested 5 s position (±0.4 s), and a new engine/session restores the saved audio track and 1.2 s position. A production SwiftUI host cycles window sizes 100 times and verifies one core/render context and resource release. The 2026-10-15 single-window run also passed one acknowledged pause/resume, one minimize/restore, and 8 seconds of visible playback. The original visible mismatch still needs a fresh manual check; full-screen-cycle and cross-display acceptance remain unrun. |
| A08 | Built-in display SDR and HDR-to-SDR smoke tests exist. External-display and calibrated color acceptance remain open; native HDR output is not implemented. |
| A10 | Depends on closing A02, A07, and A08. A09 is complete for the measured playback render path; the evidence does not claim whole-GPU power or utilization. |
| B07, B09, B10, B11 | Complete cross-process resume and storage-failure checks; exercise real file/decoder errors and settings accessibility; and run sleep/wake recovery. Existing unit or short playback tests do not close these gates. |
| B12 | Install and launch the internal package on a clean Mac without Homebrew. Current package evidence is from the development Mac only. |
| C11 | The dependency provenance audit is complete for 44/44 runtime libraries, and original Bomu source/documentation now use MIT. Developer ID signing, notarization, Gatekeeper, license validation for a final release bundle, and release-package acceptance have not run. |
| C14 and later features | Recruit and record the planned external product trial before deciding dependent roadmap work. The rest of the task list remains active and must be completed in dependency order. |

Detailed playback, color, performance, packaging, and manual-acceptance evidence is kept with each feature in `docs/`. The internal DMG is a development artifact; it is not a public release.
