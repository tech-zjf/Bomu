# 默认日志与隐私

## 结论

Bomu 当前没有应用级日志记录器、文件日志目标或遥测上传路径。生产播放器创建 libmpv 时显式禁用外部配置和终端输出（`config=no`、`terminal=no`），也不请求 libmpv 日志事件；因此默认运行不会把媒体路径、文件名或媒体错误写入 Bomu 管理的日志。当前也没有账户、网络服务或凭据存储功能。

播放失败信息只进入当前界面的状态模型，用于给用户解释并恢复播放；它没有转发到日志系统。诊断快照只包含播放状态、计数、媒体格式和时间值，不包含 URL 或本机路径。

开发工具有显式的本地基准输出和结果 JSON。媒体套件在读取 manifest 时拒绝含路径分隔符的样本名，因此其逐样本控制台信息只显示受许可测试素材的 basename；原始基准结果保存在 `.build/`，不由产品上传或自动收集。项目未把开发日志描述成生产遥测。

## 核验依据

- `Sources/Playback/MPV/BMMPVSession.m` 的 `configureCore` 设置 `config=no`、`terminal=no`、`load-scripts=no`，并禁用 ytdl；生产源代码没有应用级 Logger、`os_log`、`NSLog` 或 `print` 调用。
- `Tools/PlaybackBenchmark/MediaSuiteBenchmark.swift` 在接受 manifest 前验证样本名不含 `/`；基准程序与生产应用使用不同 target。
- `scripts/license_audit.py check` 核验全部 44 个锁定 dylib 的来源、许可与对应构建证据，并确认 Bomu 自有代码采用 MIT。这个清单不是对组合分发义务的法律审查，也不替代发布所需的源代码提供与第三方许可证告知。

若未来增加应用日志，必须在记录边界过滤 URL、绝对路径、媒体标题及凭据，并以行为测试证明默认隐私；不得默认开启未经用户知情的内容遥测。
