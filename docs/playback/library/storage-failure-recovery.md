# 媒体库存储故障恢复

播放引擎与媒体库数据库具有独立的生命周期。`AppLifecycle` 初始化 `PlaybackHistoryStore` 失败时，将失败交给 `MediaLibraryModel` 展示，不把它作为 `PlayerModel` 的播放器启动错误。媒体库显示明确的不可用状态和打开本地媒体入口，不用空的首页/网格暗示原有资料已删除；无法访问数据库期间，不执行扫描、迁移、清理或归档写入。已打开的本地媒体仍可由播放引擎独立播放，历史恢复和保存则不可用。

## 调用链

`AppLifecycle.historyStore` 初始化失败 → `historyStoreStartupError` → `MediaLibraryModel(startupError:)` → `MediaLibraryView` 的不可用状态与“打开视频”操作。与此同时，`AppLifecycle.player` 仍以可选 `historyStore` 创建 `PlayerModel`，播放器准备和文件打开仍由 `PlaybackEngine` 完成。数据库成功打开后，现有扫描协调器和持久化路径照常启用。

## 验证边界

`MediaLibraryScannerTests.testUnavailableLibraryStoreShowsFailureInsteadOfEmptyLibrary` 验证无 store 时模型报告不可用、刷新不伪造媒体条目，并保留数据库初始化错误。`PlayerModelTests.testOnlyLatestOpenIsSubmittedAfterStartup` 使用无 history store 的播放器实例验证内核准备后仍能提交媒体请求。Xcode 27 Debug build 和 hostless 回归可验证代码路径；数据库损坏/权限拒绝时的真实应用呈现仍需可见验收。

2026-10-19 的无宿主回归通过 143 项 Python 检查和 120 项 XCTest，补充两项真实文件故障证据：

- 损坏的数据库文件被 SQLite 以 `SQLITE_NOTADB` 拒绝，失败后逐字节内容不变；应用没有将它替换为空数据库。
- 独立测试进程写入进度 32.5 秒、音轨 2、字幕轨 4、音量 55 后退出。将主数据库改为只读后，第二个进程的 `PlaybackHistoryStore` 初始化返回 `SQLITE_READONLY`。恢复主数据库及已有 WAL/SHM 文件的读写权限后，新实例读回全部原值，并成功写入进度 40 秒、音量 70；原媒体文件内容不变。

子进程有 20 秒退出期限，并必须返回实际检查结果，不能以“进程退出但没有运行所选测试”作为通过。数据库、结果文件和进程日志均在临时目录中，测试结束后清理。该验证覆盖存储层的进程退出与恢复，不等同于原生故障页面验收，也不覆盖磁盘写满或物理 I/O 损坏。

## 权限恢复注意事项

本轮实验中，仅恢复 `history.sqlite` 主文件的写权限仍然重开失败；恢复已有 `history.sqlite-wal`、`history.sqlite-shm` 的访问权限后才成功。因此应将数据库与其伴随文件作为同一组恢复资料处理，不能删掉 WAL 来消除错误。

遇到权限问题时，先退出 Bomu，保留数据库及伴随文件的备份，再检查当前用户对所在目录及这组文件的读写权限，最后重新启动应用。Bomu 不会自动放宽权限或删除、重建数据库。损坏文件应保留用于恢复；本轮损坏文件测试只证明失败时不覆盖原文件，不证明能够修复损坏内容。

## Scan finalization failure

Failed scan-terminal writes no longer leave a dead producer permanently blocking the source. The store retains the ended session until a later scan can commit non-destructive recovery, while refusing late file/directory writes immediately. Continuing database failure is still reported; successful recovery does not require restarting the application. [Scan lifecycle details and failure-injection evidence](incremental-scan.md#failed-terminal-writes) cover completion and cancellation separately.

## Real volume capacity acceptance

The 2026-10-19 explicit storage run reached SQLite `SQLITE_FULL` on a disposable APFS volume and verified that the last committed checkpoint survived. Freeing the generated filler allowed saving and reading a new checkpoint without recreating the store. This supplements the write-lock and injected-failure regressions with a real capacity error; native error presentation remains unverified. Reproduce with the [separate storage entry](storage-integration.md).
