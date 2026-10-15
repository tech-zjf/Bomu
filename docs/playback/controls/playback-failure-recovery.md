# Playback failure recovery

`BMMPVSession` classifies failures at the native boundary before they enter feature state. File reachability errors distinguish missing/unavailable files from permission denial. After reachability succeeds, a nonblocking read-only `open` checks the effective process access before libmpv receives the path; POSIX `EACCES`/`EPERM` remains a path-free permission failure rather than being mislabeled as a codec error. The descriptor is immediately closed and libmpv still opens by URL, so a concurrent permission change after this probe can still surface as a loading error. Libmpv loading, unknown-format, and no-stream errors become an unsupported-or-damaged media failure; command and runtime faults remain engine failures. The UI does not infer categories from localized error text.

The failure view explains the likely cause and offers retry for media-related failures, file selection for every failure, and stop to return to the idle state. Retry creates a new request through the same player owner and preserves the failed request's resume intent. A one-time “continue” or “start from beginning” choice therefore remains authoritative even when the global resume preference differs. Stale native events from the prior attempt cannot replace the current failure or playback state.

`unsupportedOrDamaged` intentionally combines damage and unsupported encoding: libmpv reports these cases through the same loading errors in the current adapter contract. The interface describes both possibilities and offers the same recovery actions instead of claiming a distinction the native API did not provide. For these libmpv failures, the UI also preserves a bounded technical detail that can be selected and copied. Missing-file and permission failures keep localized, path-free messages and do not expose native details.

## Verification

- App target and app-host test targets compile with the pinned Xcode 27.0 toolchain.
- Logic tests exercise stale failure rejection and playback failure state transitions.
- `testRealPlaybackPauseSeekReplaceAndRelease` exercises a real corrupt local fixture and recovery. A new assertion requires the native error to map to `unsupportedOrDamaged`; the app-host target compiles with it, but the assertion has not been executed since it was added because the current macOS session is locked.
- A real-kernel app-host regression now checks that a mode-000 media file is classified as permission denied, exposes no path detail, stops the previous playback cleanly, and allows a valid file to recover in the same session. It compiles with the app-host target; it still needs an unlocked-host run.
- `PlayerModelTests.testRetryPreservesExplicitContinueChoiceWhenGlobalResumeIsDisabled` verifies a failed explicit continue request retries at the saved checkpoint even while the global preference is off; the complete 60-test hostless suite passed with this regression included.
- Visible selection, permission denial, damaged media and retry behavior still require one-window playback verification on the unlocked Screen 1 host.

2026-10-15：尝试在 Bomu 单一 app-host 窗口运行 `testRealPlaybackPauseSeekReplaceAndRelease`，覆盖真实损坏媒体分类与资源释放。Mac 锁屏时 Xcode 未能 materialize XCTest worker；约 145.5 秒后测试仍未开始，主动中断等待。进程复查确认 Bomu 与 xcodebuild 均已退出；本次没有产生测试结果，不能视为通过。待屏幕 1 解锁后重跑该用例。
