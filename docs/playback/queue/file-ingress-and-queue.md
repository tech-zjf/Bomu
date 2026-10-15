# 文件入口与播放队列

## 责任边界

`OpenMediaPanel` 负责把系统面板的单选、多选和目录选择转成 URL；`AppLifecycle.application(_:openFiles:)` 接收 Finder 的“打开方式”与启动时文件事件；`MainWindowView` 在媒体库与播放器共享的窗口表面接收拖放 file URL。三个入口最终交给 `PlayerModel.open(_ urls:)`，页面不直接创建播放请求，也不接触 mpv。拖放因此在应用默认显示媒体库时也可用。

文件导入与进度持久化错误提示由 `MainWindowView` 托管，因此无论当前显示媒体库还是播放器，恢复提示都附着于唯一主窗口，不依赖隐藏路由的呈现状态。

`MediaFileDiscovery` 在后台展开目录，跳过隐藏文件、应用包和符号链接，只把已知媒体类型加入候选。单独打开的文件会保留原样交给内核，以便内核针对不支持或损坏内容返回真实错误。导入结果由 `PlaybackQueue` 去重并按文件名自然排序，`localizedStandardCompare` 让 `S01E2` 排在 `S01E10` 前；队列保存当前索引，播放器会话仍是实际播放状态的事实源。

## 播放行为

- 自然结束时才自动选择下一项；队列结束后显示原有结束状态。
- 手动停止清除当前播放请求，不推进队列。
- 菜单允许直接选择任一队列项，因此损坏文件或解码失败后仍可继续。
- 用户在导入期间再次打开内容时，较旧的扫描结果通过递增的导入 ID 丢弃。
- 拖放会在请求系统文件 URL 前同步取得输入意图；provider 回调较晚返回时，只有意图仍是最新选择才可提交队列。URL 读取持有 `NSItemProvider` 返回的 `Progress`，主窗口关闭或新拖放到来时取消旧读取；结果回调和取消由主 actor 上的请求状态协调，避免重复恢复异步 continuation。
- 目录扫描任务由 `PlayerModel` 持有；新输入、队列切换、停止和退出都会取消扫描。遍历逐项检查取消，退出会等待导入与扫描结束后再释放播放资源。
- 文件历史仍按实际播放请求写入；选择队列项时先保存旧请求状态，再提交新请求。

## 验证

- `PlaybackQueueTests` 验证自然排序、中文与空格路径、去重、边界选择，以及目录扫描跳过隐藏内容、应用包和不支持类型；确定性取消测试验证扫描在遍历中收到取消后立即结束。
- `PlayerModelTests.testStopCancelsPendingBatchImportBeforeItCanOpenMedia` 验证批量导入刚提交便停止时，不会迟到地启动播放或显示取消错误。
- `PlayerModelTests.testDelayedInputCannotOverrideANewerDirectOpen` 验证系统 provider 返回前已有更新的直接打开操作时，迟到的拖放不能替换请求或队列。
- `PlayerModelTests.testQueueAdvancesOnlyAfterNaturalEndAndCanRecoverFromFailure` 验证自然结束推进、错误后手动恢复，以及手动停止不推进。
- Xcode 27.0 Debug 构建通过；当前无应用宿主 XCTest 与 Python 回归全量通过。
- Finder 启动时交付多个文件、打开面板交互、实际拖放仍需在屏幕 1 的单一 Bomu 窗口中做可见验收；当前 Mac 锁屏，未将这些 GUI 路径记作已验收。
