# 播放性能与资源验证

这是 v0.0 的开发基线，用于发现首帧延迟、停止后持续工作和资源释放问题。独立的 `BomuBenchmark` 开发 target 直接编译生产源文件，使用自己的 `NSApplication.run()` 事件循环。`--playback` 测量 `Playback` 与 `BMVideoSurface`；单窗口和显示器迁移模式还承载完整的 SwiftUI 播放控制界面。没有复制播放器实现，也不向正式应用加入测试入口。GPU 功耗、实际屏幕出光和声音起播延迟仍需另外测量。

## 运行与产物

```sh
./scripts/benchmark-dev.sh --playback
```

首次运行会调用本机 FFmpeg 生成 3 个 16:9、30 fps 的 SDR 测试片：1080p H.264、1080p H.265 Main10、4K H.265 Main10。画面为 `testsrc2` 彩条与移动图形，声音为合成正弦波；来源、CC0 声明、真实媒体属性和 SHA-256 在 `.build/benchmark-media/manifest.json` 中。它们用于可复现测量，不能代表复杂实拍素材或完整兼容性样本库。

另生成并解码校验一段 1080p/60 fps 闪光与 PCM 短音同步片，保存在 `.build/sync-fixture/`。基准静音播放其中 12 秒，检查持续可见性、出帧和提交目标；物理声音与画面偏差不在该自动测量范围内。素材的 15 次闪光/短音起点记录在独立 manifest，生成和验证方式见 [审查跟进](review-follow-up.md)。

这一模式会激活独立工具，显示注明用途的静音窗口，确认窗口可见后采集持续播放负载；结束后明确关闭并解除视频宿主。它不会成为产品入口或默认播放内容，也不读取用户原视频。普通 `test-dev.sh` 只运行无应用宿主的 7 项逻辑测试；`test-dev.sh --native` 才启动应用宿主运行 3 项原生集成测试。

不带模式运行 `benchmark-dev.sh` 仅显示帮助，不创建或激活测试窗口。当前日常可见验证使用下文的 `--single-window`；会频繁打开/关闭窗口的 `--playback` 和跨屏模式需单独安排桌面使用。

每次运行在 `.build/benchmarks/<时间>/` 保存：

- `playback-baseline.json`：逐次首帧、分阶段 CPU/内存、渲染计数与切换检查点。
- `summary.md`：由同一 JSON 生成的汇总表。
- `source-provenance.json`：基准提交及工作区源文件 SHA-256，包含未提交修改。
- `media-manifest.json`、`sync-manifest.json`、`dependencies.json`、`hardware.txt`、`toolchain.txt`：输入与环境。工具链校验接入后的新运行另外保存 `toolchain.json`，含已检查的 Xcode / Swift / SDK 版本与 build；历史报告不补写未执行过的检查。
- `build.log`、`process.log`：开发工具构建与实际运行日志。

每次先核验运行库和测试片哈希。普通异常和取消会保存未完成报告及失败原因；父进程将运行时间限制为 300 秒，超时只结束此次子进程。崩溃或强制退出不能假定有完整 JSON。只有完成全部断言才生成汇总，原始产物均被 `.gitignore` 排除。

## 测量合同

| 指标 | 定义与边界 |
| --- | --- |
| 首帧 | 已完成 `prepare` 后，从提交 `open` 到首个有效媒体帧完成 `glFlush`；每个样本新建会话 10 次。文件系统为暖缓存，不包含进程启动、内核初始化、GPU 完成或屏幕扫描延迟 |
| 有效媒体帧 | mpv 标记 `PRESENT`，排除 `REDRAW` / `REPEAT`，render 成功；首次时间戳属于当前 render context 生命周期，不能用作同一会话的每次切换耗时 |
| P95 | 对 10 次结果采用 nearest-rank；此时等于最大值，样本数量不足以代表稳定的大规模分布 |
| CPU | `getrusage(RUSAGE_SELF)` 用户态与内核态 CPU 秒数增量 / 同阶段墙钟秒数；100% 表示一个逻辑核。包括开发工具与播放/渲染，不包括正式 SwiftUI 控件、WindowServer 或系统解码服务 |
| 窗口可见性 | 每个进程采样同时记录 `NSWindow.occlusionState`；持续播放要求全部采样可见，8 秒内至少提交 200 个有效媒体帧，否则报告失败。测试窗口显式置前，但仍以实际采样结果为准 |
| 内存 | `proc_pid_rusage` 的当前 physical footprint 与 resident bytes，每 250 ms 采样；包含工具本身及进程内缓存，不能把一次高水位直接认定为泄漏 |
| 连续切换 | 同一会话交替打开 1080p H.264/H.265 共 100 次，每次等待当前 request ID 的播放时间超过 0.2 秒，每 10 次保存检查点；窗口尺寸保持不变 |
| 缩放 | 内存检查点采集结束后独立改变窗口尺寸 100 次；不等于全屏、跨屏与现场拖动组合验收 |
| 停止 | 等待 `idle-active=true` 且 `vo-configured=false`，留出收尾时间，再测量 5 秒；断言新视频帧、绘制与播放快照均不再增长 |
| 退出 | 等待异步 shutdown 完成，断言 core 与 render context 均已释放；不把缓存未立即归零当作仍持有内核 |
| 帧提交时序 | 稳定播放阶段要求实际配置为音频时钟、零提前量；提交目标样本持续增加，提前超过 2 ms 的计数不增长。差值基于固定 mpv 版本的同源纳秒时钟，不能当作扬声器到屏幕偏差 |

诊断由控制队列复制内核值，再由渲染队列加锁复制计数，最终返回 Swift 值类型。它是跨两个所有者的非原子快照，适用于稳定检查点，不能作为播放业务状态或并发事件的全局顺序证明。不可用的内核字段保留 `nil`。产品 UI 不轮询这些信息。

CPU 秒数采用系统明确的秒/微秒字段，不把 `proc_pid_rusage` 的 Mach 时间单位误当成纳秒。连续切换的内存采样与缩放压力分开，避免不同大小的图形缓冲区干扰比较。测试窗口使用 `close` 完成生命周期，仅 `orderOut` 用于需要重新显示的隐藏阶段。

隐藏阶段包含 AppKit 遮挡状态传播过程，原始数据保留可见性和收尾绘制计数；不把它直接视为稳定后台负载。暂停时仍以 10 Hz 读取播放状态，视频帧则应停止推进。

此前在 XCTest 中测量时，出现了窗口可见性未通过、持续出帧不足的结果；这些运行不作为可见播放基线。耗时测量因此由独立应用承担，避免依赖测试运行器的窗口调度。原生 XCTest 通过 `TEST_HOST` / `BUNDLE_LOADER` 使用 Bomu 宿主和 `@testable import Bomu`，其 target 只编译原生测试文件。逻辑 XCTest 使用独立的 hostless target，不链接应用或 libmpv。不同测试入口分别提供证据。

## 单窗口模式与桌面使用边界

```sh
./scripts/benchmark-dev.sh --single-window
```

这个模式使用同一个普通 `NSWindow`、生产 `PlayerScreen` 和 `PlayerModel`。默认进行 100 轮暂停/恢复，之后连续播放 120 秒。程序只在开始时显示窗口，不自动调整窗口位置、大小或全屏状态，不在两个屏幕之间移动；用户遮挡窗口后，测试记录可见性失败并结束，不反复置前重试。

素材由已有 CC0 合成片通过 stream copy 复用为连续 15 分钟的 H.264/AAC 文件，保存在 `.build/window-fixture/`。源 SHA-256、生成关系、实际时长和输出哈希保存在 manifest；播放器只打开一次，不用 seek、重新打开或循环命令冒充连续播放。

`window-lifecycle.json` 使用 schema 3，明确记录 `scenario=single-window`；未运行的全屏耗时保持缺失，不记成 0。每轮等待原生暂停和较新编号的恢复确认，恢复后必须再提交新帧。检查点要求视频宿主仍属于同一窗口、图层倍率匹配窗口、该会话的 core/render context 累计创建次数各为 1、媒体打开次数为 1。连续播放每 10 秒保存时间、进程内存和帧数，同时在整个区间记录 `windowDidChangeOcclusionState` 的可见性变化及首尾状态；任何遮挡记录都会使该区间失败，即使下次采样时已恢复可见。`soakVisibility` 保存变化时间和观察结束时间，异常或取消也会保留；停止后的 5 秒要求帧、绘制、快照均不增长，退出后验证两个资源已释放。

`BOMU_BENCHMARK_CYCLES`（1–100）和 `BOMU_BENCHMARK_SOAK_SECONDS`（0–600）允许缩短调试运行，实际请求值始终写进报告。该模式包含 SwiftUI 控件开销，与固定几何的底层 CPU 基线分别比较；120 秒也不能替代数小时泄漏测试或物理音画同步。

`--display-transitions` 复用相同测量所有者，但额外执行缩放、屏幕迁移与原生全屏确认，至少需要两个显示器，父进程超时为 1800 秒。它会占用桌面，只能在用户针对这些操作明确许可后安排，不能把普通“继续”视为跨屏测试许可。当前完整 100 轮显示器组合验收仍未完成。

## 2026-10-13 初始本机基线（时序修复前）

Apple M5，10 逻辑核，16 GiB，macOS 26.0（25A8353），Xcode 26.1.1。运行目录为 `.build/benchmarks/20261013-172558/`；归档的 [逐次测量与来源校验](baseline-2026-10-13.json) 包含工作区源码哈希，实际内核为 mpv 0.41.0 / FFmpeg 9.0.1。运行完成，无 Core Animation 事务错误。

| 样本 | 次数 | 首帧中位数 | 首帧 P95 | 解码器 |
| --- | ---: | ---: | ---: | --- |
| 1080p H.264 | 10 | 79.3 ms | 428.7 ms | VideoToolbox |
| 1080p H.265 Main10 | 10 | 48.9 ms | 61.4 ms | VideoToolbox |
| 4K H.265 Main10 | 10 | 82.3 ms | 173.5 ms | VideoToolbox |

| 阶段 | 进程 CPU | 末次 footprint | 新视频帧 | 新绘制 | 新状态快照 | 可见采样 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 初始化后空闲，3 秒 | 0.73% | 192.9 MiB | 0 | 0 | 0 | 13/13 |
| 1080p 播放，8 秒 | 7.36% | 319.4 MiB | 241 | 241 | 80 | 32/32 |
| 暂停，3 秒 | 0.51% | 247.0 MiB | 0 | 1 | 31 | 13/13 |
| 隐藏过程，3 秒 | 4.32% | 370.2 MiB | 13 | 13 | 31 | 1/13 |
| 停止，5 秒 | 0.12% | 174.0 MiB | 0 | 0 | 0 | 21/21 |
| 销毁后，3 秒 | 0.09% | 114.4 MiB | 0 | 0 | 0 | 13/13 |

100 次切换的 10 个检查点 footprint 为 234.4–285.0 MiB，末次 237.8 MiB；该轮没有持续增长趋势。另完成 100 次独立缩放，停止后没有新帧、绘制或状态采样，销毁后确认内核与 render context 均已释放。

这份 Debug、合成片、短时测量用于后续回归比较，不代表完整 A09 验收或长期无泄漏。产品启动、首声、GPU、跨屏色准与长时间实拍素材运行仍有独立验收项。

## 审查修复后的基线

暂停确认增加命令编号，调度改为音频时钟、零提前量后，17:45:38 的完整基准通过；当前比较应使用 [本轮逐次结果](baseline-2026-10-13-after-review.json)。同机 1080p 稳定播放 8 秒提交 242 帧、32/32 次可见、进程 CPU 5.55%；停止后 0.12%，帧/绘制/快照增量均为 0。

帧提交相对目标的阶段均值由修复前提前 30.483 ms 变为延后 3.600 ms；提前超过 2 ms 的帧由 241 变为 0。60 fps 同步片另外提交 720 帧，均值延后 3.878 ms，提前计数为 0。这是提交时序证据，物理音画偏差仍未测量。完整对照、单位依据及事务警告边界见 [审查跟进](review-follow-up.md)。

## 2026-10-13 窗口验证记录

以下三个运行分别保留，不能拼接为一个完成的验收；[原始报告与源码来源](window-validation-2026-10-13.json) 同时保留 `completed`、失败原因、媒体 manifest 与未过滤进程日志。

| 运行 | 结果 | 边界 |
| --- | --- | --- |
| 19:04，两轮显示器预检 | 2/2 轮及 10 秒可见播放完成 | 验证驱动流程，不代表 100 轮验收 |
| 19:05，完整显示器组合 | 29/100 轮后因遮挡失败 | `completed=false`，尚未完成 A07；停止续跑 |
| 19:18，单普通窗口 | 100/100 次暂停/恢复；其后约 50.285 秒检查点区间提交 1507 帧，采样点均可见 | 请求的 120 秒持续可见阶段因遮挡结束，整体仍为 `completed=false` |

单窗口的 100 个轮次记录均为同一内建屏、960×600 内容尺寸、2× backing scale，未出现全屏耗时字段。core、render context 和文件打开计数始终各为 1；失败收尾后的两个资源存活标志均为 false。没有将窗口置前重试，也没有过滤原生警告；这三份进程日志中未出现之前的事务警告，但历史警告调用栈仍未取得。

当前主机内建屏为 1512×982 点、2×、最高 120 Hz，外接屏为 1920×1080 点、2×、最高 60 Hz。本轮两块屏的 backing scale 相同，不能声称已覆盖不同倍率迁移；读取显示器属性也不等于色准、HDR 或刷新同步已验收。

## 参考

- [Apple XCTest performance tests](https://developer.apple.com/documentation/xctest/performance-tests)：性能测量与功能断言分工。
- [Apple CATransaction](https://developer.apple.com/documentation/quartzcore/catransaction)：线程上的隐式/显式图层更新事务。
- [Apple application unit tests](https://developer.apple.com/library/archive/documentation/DeveloperTools/Conceptual/UnitTesting/02-Setting_Up_Unit_Tests_in_a_Project/setting_up.html)、[NSApplication.run](https://developer.apple.com/documentation/appkit/nsapplication/run())：应用宿主与真正的窗口事件循环。
- [mpv v0.41.0 render API](https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/render.h)：帧标志与线程约束。

完整运行链路见 [flow.md](flow.md)，实际通过项与缺口见 [requirements.md](requirements.md)。

## 可见性记录升级的证据边界

schema 3 使用 AppKit 可见性变化通知，补足两次检查点之间的短暂遮挡。schema 1/2 的历史 JSON 保留原状；其可见性结论限定为采样点可见，不证明采样之间没有遮挡。新的无界面测试验证了短暂遮挡后恢复仍判失败、初始/结束遮挡、结束后记录不再改变以及汇总拒绝中断记录；实际窗口事件链与持续播放仍需后续单窗口可见运行，不能用这些逻辑测试替代。AppKit 的 visible 也不证明整个画面均无遮挡。
