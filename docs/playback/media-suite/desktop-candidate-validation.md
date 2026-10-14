# 候选运行库的单窗口可见验证

日期：2026-10-14。状态：**未通过；两次运行在启动阶段结束，未到达 TS 用例**。正式运行库未替换，A04 正式结果仍为 29/30。

## 输入与操作范围

复用 `.build/seek-candidates/20261013-232523` 中已通过的 `playback-format` 原生实验。候选 `libavformat.63.dylib` SHA-256 为 `d376ff4eae9342a1acf32f79f0c498d40cda086874e34481cece94eb7426ed5f`，其余动态库沿用正式固定版本。

`prepare-seek-candidate-app.py --output` 为每次应用准备创建新的目录，保留旧应用与 receipt。实际启动前核对 52 个源码身份、47 个二进制身份，以及素材 manifest。一次只创建一个普通窗口，指定 `media-suite`、100 次暂停/恢复、120 秒持续播放、每个素材 2 秒观察时间；未启用自动全屏或显示器迁移模式。默认 `benchmark-dev.sh` 会重建原始运行库，所以本次直接启动候选中的 `BomuBenchmark`，调用环境与日志保存在各运行目录。

## 失败结果

| 运行目录（`.build/benchmarks/` 下） | 观察与结果 |
| --- | --- |
| `20261014-ts-candidate` | 第 1 项 MP4 起始 display ID 为 3，结束检查失败；第 2 项 MP4 在 display ID 1 上通过。工具随后以 `Media suite changed displays` 停止，0 次生命周期轮次 |
| `20261014-ts-candidate-stationary` | 移除 `.moveToActiveSpace` 并等待应用激活后仍重复上述结果；0 次生命周期轮次 |

两次运行各自只有一个 window number，均在外接屏与内建屏之间出现屏幕 ID 变化。两个原生资源标记在退出时均为 false；进程日志没有原生事务警告。没有覆盖失败记录、删掉失败样本、放宽显示器断言或把失败改记为通过。

两次都接入过桌面控制工具，现有日志不足以区分 AppKit 启动、桌面控制接入或外部窗口管理行为。移除跟随活动 Space 的设置符合单屏约束，但第二次仍失败，因此不是已验证的根因修复。

原始报告、日志与各次应用 receipt 的哈希及关键字段保存在 [desktop-candidate-validation-2026-10-14.json](desktop-candidate-validation-2026-10-14.json)。这些运行没有进入 TS 样本，不能用于支持或否定候选的实际 TS 画面，也没有新的持续播放、性能或物理同步结论。

## 已准备的后续诊断

测试工具补充窗口创建、置前、移动及换屏事件的时间、窗口编号、frame、屏幕名称和激活状态日志。新的诊断应用位于 `.build/seek-candidates/desktop-20261014-location-diagnostics/BomuSeekCandidate.app`；固定工具链构建、临时签名及二进制身份核验通过，尚未启动。52 项 Python 行为测试通过。

继续可见诊断前须先解决单屏操作约束：再次启动可能重现屏幕移动，不能通过反复启动或去掉断言规避。先安排一次明确允许的启动诊断，确认窗口位置变化的来源，再恢复完整矩阵。当前没有把正式 TS 缺陷关闭，也没有提前进入 v0.1。

实际构建与验证调用链仍见 [flow.md](flow.md#播放用候选构建与独立应用准备) 和 [原生窗口验证链路](../native-poc/flow.md#正式界面的窗口验证)。
