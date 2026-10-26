# 2026-10-24 媒体后台工作与构建身份

接续 [首批质量收口](implementation.md)，本批只处理锁屏后可独立完成的播放期间后台降载、媒体属性探测生命周期和 Debug 构建身份。未改变 v0.0 的产品验收状态，也未启动播放器或修改系统辅助功能设置。

## 实现与调用链

- `AppLifecycle` 拥有缩略图与元数据探测共用的 `AsyncPermitPool`。`PlayerModel` 的 `opening` / `ready` 转换发布活动状态；App 串行更新许可上限，平时为 2，播放期间为 1。缩小额度不抢占进行中的工作。详见 [媒体工作预算](../../playback/library/media-work-budget.md)。
- `MediaMetadataProbe` 按媒体 ID + 内容版本合并请求，各调用方可独立取消；最后一个退出时取消工作。取得许可后十秒超时，失败或全未知不缓存。AVFoundation 适配器在取消时停止父 asset 加载，并在多段读取间检查取消。
- 规范 Debug 构建在 Xcode 前后核对输入集合，生成与 `Bomu.app` 同目录的本地收据；`verify` 命令复核当前源码与包字节。详见 [构建身份](../build-identity/implementation.md)。

## 验证

| 检查 | 结果 |
| --- | --- |
| `./scripts/test-dev.sh --direct-hostless` | 执行时 153 项 Python 检查通过；202 项 XCTest，0 失败，其中 2 项 APFS 专项按默认入口跳过。新增共享预算、探测取消/超时、播放阶段通知和构建身份回归。 |
| `python3 -m unittest discover -s Tests -p 'test_*.py'` | 随后补齐核验命令入口回归，最终 154 项 Python 检查通过；Swift 源码和 202 项 XCTest 未再变动。 |
| `./scripts/build-dev.sh --analyze -quiet` | Xcode 27.1、Swift 6.4、macOS SDK 27.0 下通过。 |
| `./scripts/build-dev.sh -quiet` | Debug 构建通过，生成规范 `Bomu.app` 与身份收据。版本 0.0.1 (2)，包内仅 `en.lproj`。 |
| `python3 scripts/build_identity.py verify --receipt .build/DerivedData/Build/Products/Debug/Bomu.build-identity.json` | 当前源码与 53 个包内文件全部匹配。输入 SHA-256 `1d94de7334b2e031fa4198599aa8cf64a329c7f60c0df19608eadc859d4a8399`，包摘要 `e2c18fc4c70c07404ca3c87880f32bfeb1ea44df025677cd2baab8be3331dc08`。 |
| 格式 | `git diff --check` 通过。 |

日志留在忽略目录 `.build/review-2026-10-24/media-work-*.log`。Debug 的 `Contents/MacOS/Bomu` 是启动可执行文件，应用逻辑还在 `Bomu.debug.dylib`；因此应核对整包摘要，不只核对启动文件。第一批完成的两项临时 APFS 专项在此批没有重跑，存储实现没有改动。

这些检查验证代码合同和构建可追溯性。播放期间真实能耗/滚动表现、实际声画、三个窗口尺寸、新入口可见状态、睡醒与长时间资源释放仍在 [v0.0 验收清单](../roadmap/v0.0-acceptance-todo.md) 中，不能据此宣称已完成 A05 或 v0.0 验收。
