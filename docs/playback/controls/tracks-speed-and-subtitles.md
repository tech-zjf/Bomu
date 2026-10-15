# 播放速度、音轨与字幕

## 调用链

播放菜单只提交 `PlayerModel` 意图。`PlaybackSnapshot` 携带实际速度、字幕偏移和已解析的轨道列表；`MPVPlaybackEngine` 将值映射为无原生句柄的 Swift 模型；`BMMPVSession` 在唯一的内核控制队列读取 `track-list`，将语言、标题、选中状态、内嵌/外部标志复制后释放 `mpv_node`，并串行提交轨道、速度和字幕命令。

轨道 ID 始终来自当前文件的 libmpv 快照。选择音轨或字幕会以当前请求 ID 提交，旧文件命令在原生边界丢弃。字幕关闭使用轨道 ID 0；外置 SRT、ASS、SSA、VTT、SUB、SUP 和 IDX 文件通过 `sub-add ... select` 加入，源文件只读。偏移以秒表示，限制在 ±30 秒；快速连续微调从尚未被快照确认的目标继续累加。

字幕同步子菜单显示当前偏移，支持按 0.5 秒提前或延后，并可一键重置为零。偏移以秒表示，限制在 ±30 秒；快速连续微调从尚未被快照确认的目标继续累加，归零与微调使用相同的当前请求和待确认状态。

速度菜单提供 0.5×、0.75×、1×、1.25×、1.5× 和 2×。模型与原生适配层将速度限制在 0.25× 到 4×，界面只显示内核回报值。

## 验证

- `PlayerModelTests.testTrackSelectionExternalSubtitlesAndOffsetUseCurrentRequest` 覆盖当前请求 ID、快速字幕偏移累加、归零、音轨/字幕/外置字幕命令；改动后完整 Xcode 27 回归为 126 项 Python 与 79 项无宿主 XCTest，失败/跳过均为 0。
- Xcode 27.0 Debug 应用构建与 app-host 原生测试目标编译通过。
- 已增加真实 libmpv 集成断言检查音轨解析和速度往返；锁屏期间测试宿主无法连接，因此尚未执行该用例。
- 增加获许可的 AAC/ALAC 双音轨 fixture；新集成用例在同一个 app-host 窗口里暂停播放，按快照中的当前轨道 ID 切到另一轨再切回，并核对内核的活动轨道与 selected 标记。Xcode 27 app-host 测试 target 编译通过，锁屏期间未执行真实切换。
- 2026-10-15 在屏幕 1 的唯一 Bomu 窗口用本地 AAC/ALAC 双音轨 fixture 验证 Track 1→Track 2 的菜单选中标记切换；音量设为 0，因此不声称听感通过。使用 `.build/fixtures/bomu-subtitle-verification.srt` 经系统文件面板加载字幕，画面出现 “Bomu subtitle verification”，选择 Off 后文字消失；延迟菜单从 0.0 调到 +0.5 秒后再重置为 0.0。测试文件只在被忽略的 `.build/`，没有加入仓库。
- 播放速度的可见选择与实际速度听感、音轨切换听感，以及带同步提示音的字幕偏移效果仍待后续实测；本轮静音素材操作不构成这些验收证据。
