# 媒体库存储故障恢复

播放引擎与媒体库数据库具有独立的生命周期。`AppLifecycle` 初始化 `PlaybackHistoryStore` 失败时，将失败交给 `MediaLibraryModel` 展示，不把它作为 `PlayerModel` 的播放器启动错误。媒体库显示明确的不可用状态和打开本地媒体入口，不用空的首页/网格暗示原有资料已删除；无法访问数据库期间，不执行扫描、迁移、清理或归档写入。已打开的本地媒体仍可由播放引擎独立播放，历史恢复和保存则不可用。

## 调用链

`AppLifecycle.historyStore` 初始化失败 → `historyStoreStartupError` → `MediaLibraryModel(startupError:)` → `MediaLibraryView` 的不可用状态与“打开视频”操作。与此同时，`AppLifecycle.player` 仍以可选 `historyStore` 创建 `PlayerModel`，播放器准备和文件打开仍由 `PlaybackEngine` 完成。数据库成功打开后，现有扫描协调器和持久化路径照常启用。

## 验证边界

`MediaLibraryScannerTests.testUnavailableLibraryStoreShowsFailureInsteadOfEmptyLibrary` 验证无 store 时模型报告不可用、刷新不伪造媒体条目，并保留数据库初始化错误。`PlayerModelTests.testOnlyLatestOpenIsSubmittedAfterStartup` 使用无 history store 的播放器实例验证内核准备后仍能提交媒体请求。Xcode 27 Debug build 和 hostless 回归可验证代码路径；数据库损坏/权限拒绝时的真实应用呈现仍需可见验收。
