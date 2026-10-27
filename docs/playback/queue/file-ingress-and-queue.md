# 文件入口与播放队列

2026-10-26 新增[追加队列](append.md)：独立菜单与 Cmd-Shift-O 入口，保留当前请求及已有顺序。下文旧“短片不自动续播”的队列测试只验证自动下一项；真正的短片位置恢复策略见[完成与检查点](../persistence/completion-and-checkpoints.md)，两者不是同一验收项。

## 责任边界

`OpenMediaPanel` 负责把系统面板的单选、多选和目录选择转成 URL；`AppLifecycle.application(_:openFiles:)` 接收 Finder 的“打开方式”与启动时文件事件；`MainWindowView` 在媒体库与播放器共享的窗口表面接收拖放 file URL。三个入口最终交给 `PlayerModel.open(_ urls:)`，页面不直接创建播放请求，也不接触 mpv。拖放因此在应用默认显示媒体库时也可用。

主窗口根据当前播放请求切换播放器呈现路由，并在首次建立观察时同步已有请求，覆盖 Finder 在应用启动阶段先交付文件、后创建 SwiftUI 页面这一顺序。

文件导入与进度持久化错误提示由 `MainWindowView` 托管，因此无论当前显示媒体库还是播放器，恢复提示都附着于唯一主窗口，不依赖隐藏路由的呈现状态。

当前 Debug 和 Release 应用 target 都关闭 App Sandbox。打开面板、Finder 事件与拖放返回的文件 URL 按当前用户的文件权限使用，不持久化安全作用域书签；媒体库扫描器会在 URL 带有安全作用域时成对开始和结束访问。若未来发行 target 改为沙盒化，必须先为拖入的文件或目录保留访问作用域，并为跨重启的媒体库来源存储可恢复书签，再启用该发行配置。

`MediaFileDiscovery` 在后台展开目录，跳过隐藏文件、应用包和符号链接，只把已知媒体类型加入候选。单独打开的文件会保留原样交给内核，以便内核针对不支持或损坏内容返回真实错误。导入结果由 `PlaybackQueue` 去重并按文件名自然排序，`localizedStandardCompare` 让 `S01E2` 排在 `S01E10` 前；队列保存当前索引，播放器会话仍是实际播放状态的事实源。

文件夹导入以整批扫描成功为提交边界。目录枚举无法开始或任意子目录读取失败时，`MediaFileDiscovery` 抛出读取错误，`PlayerModel` 显示导入失败并保留原请求、队列与当前项，不把可读部分静默当成完整结果提交。这与媒体库扫描的逐项入库不同：媒体库允许报告部分结果并禁止删除对账，播放队列导入则不能在未说明遗漏的情况下替换正在使用的队列。

## 播放行为

- 自然结束且自动续播已启用时，只有时长已知且不少于 30 秒才自动选择下一项；短于 30 秒或时长未知时保留结束状态，仍可手动切换。队列结束后显示原有结束状态。
- 手动停止清除当前播放请求，不推进队列。
- 播放中可从队列菜单直接选择任一队列项。短片或时长未知的媒体结束后，结束页复用同一菜单，用户可以播放下一项或选择队列中的其他文件。
- 播放失败时不自动推进队列；错误页提供重试、打开其他文件和返回资料库的动作。多文件队列还显示共用的队列菜单，可直接选择前后或任意一项，保留原队列而不必重新导入。
- 用户在导入期间再次打开内容时，较旧的扫描结果通过递增的导入 ID 丢弃。
- 拖放会在请求系统文件 URL 前同步取得输入意图；provider 回调较晚返回时，只有意图仍是最新选择才可提交队列。URL 读取持有 `NSItemProvider` 返回的 `Progress`，主窗口关闭或新拖放到来时取消旧读取；结果回调和取消由主 actor 上的请求状态协调，避免重复恢复异步 continuation。
- 目录扫描任务由 `PlayerModel` 持有；新输入、队列切换、停止和退出都会取消扫描。遍历逐项检查取消，退出会等待导入与扫描结束后再释放播放资源。
- 文件历史仍按实际播放请求写入；选择队列项时先保存旧请求状态，再提交新请求。

## 验证

- `PlaybackQueueTests` 验证自然排序、中文与空格路径、去重、边界选择，以及目录扫描跳过隐藏内容、应用包和不支持类型；目录导入和资料库扫描共用 `MediaFileType` 清单，回归覆盖 `.divx`、`.mxf`、`.dts`、`.m4b` 等非通用 UTI 格式；确定性取消测试验证扫描在遍历中收到取消后立即结束。
- `PlayerModelTests.testStopCancelsPendingBatchImportBeforeItCanOpenMedia` 验证批量导入刚提交便停止时，不会迟到地启动播放或显示取消错误。
- `PlayerModelTests.testUnreadableSubdirectoryPreservesCurrentPlaybackAndQueue` 在临时目录真实撤销子目录读取权限，验证导入报告失败、原请求和完整队列保留且没有新播放请求。测试结束恢复权限并移除临时文件。
- `PlayerModelTests.testDelayedInputCannotOverrideANewerDirectOpen` 验证系统 provider 返回前已有更新的直接打开操作时，迟到的拖放不能替换请求或队列。
- `PlayerModelTests.testUnreadableDropReportsAnImportError` 验证所有 provider 都无法返回 URL 时会显示“未找到可播放媒体”；旧请求迟到返回空列表时仍不会覆盖较新的打开操作。
- `PlayerModelTests.testQueueAdvancesOnlyAfterNaturalEndAndCanRecoverFromFailure` 验证自然结束推进、错误后手动恢复，以及当前项已加载并播放时手动停止不推进。
- `PlayerModelTests.testShortOrUnknownDurationDoesNotAutomaticallyAdvanceButManualNextStillWorks` 验证短于 30 秒与未知时长不自动续播，且仍能手动选择下一项；队列边界测试验证 30 秒整可自动续播。
- `PlaybackQueueMenu` 是播放器控件、结束页和错误页共用的队列入口；结束页与错误页仅在队列有多个条目时显示，菜单通过 `PlayerModel.playNext()`、`playPrevious()` 与 `playQueueItem(at:)` 提交选择。现有失败恢复回归覆盖错误后选择队列项；错误页新增入口仍需单窗口可见验收。
- 2026-10-16 Screen 1 单窗口实测：打开两段 15 秒合成 H.264 样片，将第一段定位到结束后，结束页无重载地显示队列菜单；菜单列出两段文件且“下一项”可用。选择下一项后，第二段在同一窗口开始播放。临时样片在停止播放后已从 `.build/queue-ux-check` 删除。
- 2026-10-16 17:35 的 Xcode 27.0 无宿主回归通过 139 项 Python 检查与 113 项 XCTest；自然结束与正在播放时手动停止的队列行为均通过。Debug 构建与静态分析随后在 17:36 通过。
- 2026-10-16 屏幕 1 单窗口验收：Finder“打开方式”把一个静音 16:9 合成视频交给现有 Bomu 窗口，播放器显示变化中的测试画面与前进时间；打开损坏样片显示可重试、可换文件的解码错误。此轮没有证明冷启动事件、多文件打开、目录拖放、真实 Finder 拖放或打开面板交互。

2026-10-19：错误页接入共用队列菜单后，Xcode 27 Debug 构建通过；定向执行 `testQueueAdvancesOnlyAfterNaturalEndAndCanRecoverFromFailure` 通过（1 项，0 失败）。该回归证明失败后的模型选择路径，新增菜单的可见性与点击操作仍待 Screen 1 单窗口验收。

同日 10:30 的权限回归先复现了旧实现静默提交部分结果、替换当前请求的缺陷；修复后 10:31 全量无宿主回归通过（143 项 Python、116 项 XCTest），Debug 构建与静态分析通过。此结果覆盖真实文件系统权限和模型提交边界，不替代 Finder 拖放的可见验收。

2026-10-19 后续原生验收：从唯一开发包启动一个普通 Bomu 窗口，使用打开面板导入含中文和空格的测试目录（坏文件与静音 H.264 各一个）。坏文件进入解码失败页，队列仍列出两项；在菜单中用键盘选择正常文件后出现真实视频画面，结束后可返回资料库。指针直接选择菜单项的工具操作未完成选中，故不记录为鼠标验收通过。本次验证的是系统面板目录导入和错误恢复，不是 Finder 拖放或冷启动文件事件。两个临时素材共约 3.25 MB，退出测试进程后已移除。
