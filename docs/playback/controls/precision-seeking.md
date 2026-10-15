# 精确定位与时间轴拖动

## 责任边界

`PlaybackControls` 在拖动期间只更新本地预览位置，并用预览值覆盖较慢到达的播放快照；用户结束拖动时才调用 `PlayerModel.seek(to:)` 一次。因此快速拖动会合并为最终目标，不会把每个鼠标移动都排入内核。时间轴只在真实时长存在且媒体可定位时启用。

绝对定位由 `PlaybackSeekRequest` 保留为绝对目标，经过 `MPVPlaybackEngine` 后进入 `BMMPVSession` 的串行控制队列，以 mpv `absolute+exact` 命令执行。方向键跳转则保留相对意图并使用 `relative+exact`，不以 UI 上一次进度快照自行累计，避免快照滞后造成偏移。请求 ID 在原生边界再次核对，旧媒体的定位不会作用于新媒体。

定位不改变暂停意图。暂停中的媒体收到绝对定位后继续保持暂停；恢复播放必须来自独立的播放/暂停动作。快照仍是实际位置的权威来源，拖动预览不伪装成播放进度。

## 验证

- `PlayerModelTests.testRelativeSeeksKeepTheirIntentAcrossDelayedSnapshotsAndReplacement` 覆盖相对意图、过期快照、绝对定位、无效输入和文件替换。
- `PlayerModelTests.testSeekCapabilityGatesBothAbsoluteAndRelativeCommands` 覆盖不可定位与未知时长。
- `PlayerModelTests.testSeekingWhilePausedDoesNotIssueResumeIntent` 覆盖暂停时定位不会生成播放命令。
- `PlaybackControls.timeline` 在用户结束 Slider 编辑时只提交一次最终目标；真实快速拖动、暂停 seek 和画面落点仍须在屏幕 1 的单一播放器窗口完成可见验收。
