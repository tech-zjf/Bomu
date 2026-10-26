# 空库 Welcome 的隔离验收入口

## 用例与边界

当前用户媒体库位于 Application Support。为了检查首次启动的 Welcome、Settings 和 Restore from Backup，不能清空或挪动该数据库。Debug 构建可通过 `BOMU_ACCEPTANCE_LIBRARY_DIRECTORY` 指向系统临时目录内的独立媒体库；Release 构建忽略此变量。没有变量时，原应用数据路径保持不变。

`PlaybackHistoryStore.applicationStore` 在打开数据库前验证该绝对路径：解析符号链接后必须位于当前系统临时目录的子目录，目标必须已经存在，且其中的常规文件 `.bomu-acceptance-library` 内容必须精确为 `Bomu isolated acceptance library\n`。无效配置显式报错，不退回真实数据库。隔离目录只承载此次验收的 SQLite 用户事实；源媒体仍按常规只读规则使用。偏好设置仍使用当前应用的 UserDefaults，因此空库验收只查看设置与文件面板，不修改用户偏好或执行导入应用。

## 调用链与清理

Debug 应用进程环境 → `PlaybackHistoryStore.debugAcceptanceDirectory` → `applicationStore` → `AppLifecycle.mediaLibrary` → Welcome / Settings / Restore 路由。`scripts/isolated-welcome-session.sh` 先核对包身份，在系统临时目录创建标记库并将其传入当前用户的启动环境；该脚本不启动应用窗口。保持脚本运行，用桌面自动化按规范 Debug `.app` 的绝对路径启动本轮唯一窗口。关闭本轮进程后，向脚本发送 Return；脚本撤销环境变量并删除它创建的临时库。若环境未传入或显示真实媒体库，立即停止该轮，不以空库验收计分。不得搬动现有 Application Support 数据。

## 已完成的后台验证

2026-10-24：新增行为测试 `PlaybackHistoryStoreTests.testDebugAcceptanceLibraryUsesOnlyMarkedTemporaryDirectory` 验证无标记目录拒绝、标记目录写入独立 SQLite、空路径拒绝和指向临时目录外的符号链接拒绝。`./scripts/test-dev.sh --direct-hostless` 通过：156 项 Python、207 项 XCTest（2 项独立 APFS 专项按默认入口跳过），0 失败。`./scripts/build-dev.sh --analyze -quiet`、`./scripts/build-dev.sh -quiet`、包身份核验及 `git diff --check` 通过。会话脚本通过 `bash -n` 与 `--help` 检查；在无窗口演练中，普通受限 shell 的 `launchctl setenv` 被系统拒绝，改用经授权的非沙盒执行后，环境变量和标记目录成功创建、回读、撤销与删除。规范 Debug 包源码摘要 `345f0551f9a389cfde95506092375905c132278619523f5a70bf027fe5e9da8f`，版本 0.0.1 (2)，只打包 `en.lproj`。

代码入口包在 `#if DEBUG` 中，工程 Release 配置不定义 `DEBUG`。额外尝试的无窗口 Release 编译在本地 GRDB 锁定版本解析后，被现有发行门槛明确阻止：`Dependencies.lock.json` 未声明 `distributionReady`。没有放宽该门槛，也不把这次尝试记录为 Release 构建通过；依赖锁文件未改动，规范 Debug 包身份复核仍通过。

主窗口 Settings 路由已排除首次库加载占位，避免数据库加载中打开设置时仍只显示进度；该 UI 条件修复完成 Debug 构建与 Xcode 静态分析。

会话脚本随后补齐 `INT`、`TERM`、`HUP` 中断清理，并在设置启动变量前先启用清理路径。无窗口 Ctrl-C 演练以退出码 130 结束；回读确认启动变量为空、该轮临时目录已删除。此项只验证会话准备和清理，尚未验证 Launch Services 向 Bomu 进程传递变量或 Welcome 的可见状态。

## 解锁后的单窗口可见检查

2026-10-24 在已解锁桌面从身份已核验的规范 Debug `.app` 绝对路径启动唯一普通窗口。临时目录生成了独立的 `playback.sqlite`、WAL 和 SHM，界面确实显示空库 Welcome，证明本次 Launch Services 环境传递进入隔离库。Welcome 的 Settings 进入同一窗口 Settings；Home 可返回 Welcome。Restore from Backup 进入 Settings / Storage，Import Media Library Data 打开系统文件面板，取消后仍留在 Storage。Welcome 的 Open Video… 与 Add Folder 各自打开受用途约束的系统文件面板，取消后回到 Welcome。`⌘,` 后可见 Settings / Storage，但桌面工具在焦点变化时报告状态变化，快捷键本身仍需更稳健复核。菜单 Settings… 的可见点击因辅助功能元素失效未获得结果，不记通过。

本轮未选择媒体、文件夹或归档，未修改真实用户库和设置。关闭该轮应用后会话脚本正常退出；回读启动环境变量为空，临时库目录已删除。可见检查只覆盖当前窗口尺寸；三个精确尺寸、真实归档预览/应用、菜单点击及键盘/VoiceOver 仍未完成。首次库加载被人为延迟时的 Settings 抢先路由也未单独压测。

随后在当前 Debug 收据 `22f96470841b82d26e7cf77695c9a0fb119ec8090ed8b2d28fd3a56a1d4699c4` 上重开另一轮隔离空库，完成 Welcome 的精确 `960×640`、`1280×800`、`1440×900 pt` 可见布局抽查；设置五分区在大尺寸可导航，Storage 在小尺寸滚动到底可达。Welcome 的 `⌘,` 这次明确到达 Settings / Storage。菜单 Settings… 仍只有菜单项可见证据，点击工具返回元素失效，未记通过。该轮退出后临时库与启动变量再次清理；逐控件命中、VoiceOver、非空归档和首次加载竞态仍待验，详见[可见记录](../roadmap/visible-acceptance-2026-10-24.md#当前收据的隔离空库三尺寸复核)。
