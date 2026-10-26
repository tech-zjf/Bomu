# A07 单窗口缩放基准

## 用例与资源边界

A07 要求连续 100 次窗口缩放、控件叠层、全屏和窗口迁移后仍只有一个播放内核与渲染上下文。既有 `single-window` 场景完成 100 次暂停/恢复，但驱动不改变窗口尺寸；`display-transitions` 会执行全屏和跨屏，须另按桌面约定授权。新增 `./scripts/benchmark-dev.sh --ordinary-resize` 只补普通窗口缩放这一块，不把它记作全屏、跨屏或物理声画验收。

基准继续使用同一个 `BomuBenchmark.app` 普通窗口、生产 `PlayerScreen` / `PlayerModel`、固定 libmpv 播放会话和许可的长样片。启动内容尺寸为 960×600 pt；第 1 轮改为 920×640 pt，此后每轮交替回到 960×600 / 920×640 pt，共 100 次实际尺寸变化。两组尺寸均满足 PlayerScreen 的最小宽高要求。每轮在播放中改尺寸，等待 AppKit 内容视图到达目标尺寸，执行有内核确认的暂停/恢复，等待新视频帧，检查仍在初始显示器且 `coreCreationCount` / `renderContextCreationCount` 均为 1。该模式不调用全屏、迁屏或最小化恢复。停止后仍使用现有资源释放检查。

## 报告合同与失败路径

`WindowLifecycleBenchmark` 将每轮的真实内容宽高、显示器 ID、视频帧计数和内核诊断写入 `window-lifecycle.json`。`summarize-window-benchmark.py` 只有在 100 轮连续编号、各轮尺寸正确、缩放及持续播放阶段留在同一显示器、帧计数逐轮增加、内核/渲染上下文始终只创建一次、没有执行最小化恢复且退出资源已释放时，才输出完成摘要。窗口不可见、丢失新帧、尺寸未生效或资源身份变化，由原生基准立即失败并保留部分报告。基准是单独测试宿主，不替代规范 Debug `Bomu.app` 的 Welcome/Library/Settings 三尺寸交互验收。

桌面工具验收时，先用 `./scripts/build-dev.sh --benchmark -quiet` 编译，再保持 `scripts/ordinary-resize-session.sh` 运行。会话脚本核验锁定依赖与许可样片、把长样片 APFS 克隆到临时目录、设置基准应用专用启动变量并保存源码/工具链快照；它**不会启动窗口**。按脚本输出的 `BomuBenchmark.app` 绝对路径由桌面自动化启动唯一窗口，等待测试进程结束后给会话脚本发送 Return；脚本收集报告、运行汇总并撤销变量与临时素材。普通 shell 中 `launchctl setenv` 可能被当前工具沙盒拒绝；在已获授权的非沙盒本地执行环境运行会话脚本。`ordinary-resize` 模式固定跳过最小化恢复，不会因启动配置改变该限制。旧 `scripts/benchmark-dev.sh` 会自行调用 Launch Services，不用于桌面工具控制的此轮启动。

## 当前验证

2026-10-24：`python3 -m unittest Tests.test_window_summary` 19 项通过，新增用例会拒绝少轮、错误尺寸、资源重建、未增加的视频帧、持续播放换屏和退出资源残留；完整 `./scripts/test-dev.sh --direct-hostless` 此前结果为 159 项 Python、207 项 XCTest（2 项显式 APFS 专项跳过），0 失败；`./scripts/build-dev.sh --benchmark -quiet` 编译通过。桌面工具准备脚本通过 `bash -n`、`--help`、许可样片核验和无窗口中断演练：启动变量回读为普通缩放/100 轮/无最小化，中断后六个变量、临时样片和空结果目录均已清除。

解锁后进行四次单窗口尝试，均未达到 100 轮，不能记 A07 通过：

| 报告目录（`.build/benchmarks/` 下） | 结果与修正 |
| --- | --- |
| `ordinary-resize-20261024-152105` | 启动时实际窗口显示器与 `NSScreen.main` 不一致；无显式显示器请求时改以窗口实际可见屏幕作为后续固定基线。 |
| `ordinary-resize-20261024-152254` | 原目标 `900×560 pt` 低于生产 `PlayerScreen` 的 `600 pt` 最小高度，内容视图不会保持该尺寸；改为 `920×640 pt`，汇总器与测试同步更新。 |
| `ordinary-resize-20261024-152442` | 第 1 轮在显示器 3 完成，随后报告跨显示器变化而退出；无证据判定是窗口边界还是桌面活动影响。在实际可见屏幕内居中后再缩放，不主动跨屏。 |
| `ordinary-resize-20261024-152611` | 15 秒启动期未取得前台 key window（`appActive=false`），0 轮，未抢焦点重试。 |

最后一轮源码已通过基准编译、规范 Debug 构建、Xcode 静态分析、19 项汇总器测试以及 160 项 Python / 207 项无宿主 XCTest（2 项显式 APFS 专项跳过）。所有失败会话均由脚本清理启动环境与临时样片，桌面状态无遗留基准进程。截至上述四次尝试，完整 100 轮及 120 秒 soak 尚无收据。全屏与跨屏仍需单独授权和单独记录。

### 当前规范包的成功收据

摘要 `c6d44ee94f52e430b434142049a5dcc29e1b84d060960538ff47fe45815e2c6a` 对应的独立基准报告保存在忽略目录 `.build/benchmarks/ordinary-resize-20261024-154931/`。`summarize-window-benchmark.py` 以退出码 0 校验 `window-lifecycle.json` 并生成 `summary.md`：100/100 轮交替达到 `920×640` 与 `960×600 pt`，每轮暂停/恢复有原生确认和新视频帧，显示器 ID 始终为内建屏幕 1，播放内核与渲染上下文始终各创建 1 次。随后连续播放 120.1 秒，位置推进 120.1 秒，新增 3,595 帧，平均约 29.94 帧/秒；进程 footprint 观测范围 222.4–243.7 MiB。停止后的 5.3 秒内新增帧、绘制和快照均为 0；退出时 `coreAlive`、`renderContextAlive`、`graphicsContextAlive` 均为 false。报告 `completed=true`、`failure` 缺省。测试进程退出后才收集报告，六个启动变量和临时样片均回读为已清理。

同源码较早一次诊断报告 `.build/benchmarks/ordinary-resize-20261024-154624/` 仅保留 7 轮、`completed=false` 且无失败字段；它不能用于判断通过或失败。后一次运行避免在进程退出后重新读取已绑定窗口，完整报告独立留存。**A07 仅普通同屏缩放子项通过**；全屏与跨屏迁移、物理声画、用户拖拽流畅度仍需各自验收。
