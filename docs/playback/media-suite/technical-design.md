# 最终设计

## 所有权与依赖

继续使用独立 `BomuBenchmark` target。`WindowLifecycleBenchmark` 唯一拥有窗口、正式页面、播放器模型与播放引擎；`MediaSuiteBenchmark` 只接收这些已有对象，执行一个素材用例，不创建窗口或播放会话。用例结果写入 `WindowLifecycleReport` schema 4。

素材预期集中在生成后的 manifest。Python 生成器先比较配方和实际 FFprobe 结果，再完整解码，最后输出预期与校验值。Swift 在测试边界一次解析为 `MediaSuiteManifest.Sample.Expected`，用 `play/reject` 表达预期，用可选视频/音频结构表达真实流。运行前的通用素材校验检查全部文件 SHA-256。播放控制使用已有 `PlayerModel`，没有为某个容器、文件名或样本 ID 添加播放分支。

按需诊断在 C 适配层的控制队列读取 `audio-params/samplerate`、`audio-params/channel-count`、`audio-out-params/samplerate`，Swift 转换为可空值。不存在的原生属性保持未知；不能拿系统默认音频参数补成“通过”。这些诊断字段不参与 UI 或播放状态决策。属性含义参考 [mpv 官方手册](https://mpv.io/manual/stable/#properties)。

实际画面检查另发现了纯音频残留上一视频画面的缺陷。修复在播放/渲染边界：`BMMPVSession` 观察权威 `vo-configured` 属性，经主队列交给 `BMVideoSurface`；渲染队列持有是否允许呈现视频的状态。视频输出关闭或不可用时主动触发一次绘制，清空整个 FBO，停止调用会重放旧纹理的 mpv 视频绘制路径。隐藏窗口仍走 skip-render 消费更新，保持高级 render API 的调度契约。清屏和真实视频帧分别计数；测试检查最后一次绘制是否为 clear-only，并用实际窗口确认纯音频背景已清空。

这条规则作用于所有文件和视频输出生命周期，不依赖扩展名或某个素材。播放状态模型与 UI 不负责遮盖错误画面，也不持有新的 mpv 指针。

## 用例与失败处理

每个正常素材要求：当前请求 ready 且时间推进，真实视频尺寸/音频参数符合 manifest，视频有新媒体帧，暂停收到原生确认，暂停中定位到时长中点并保持暂停，恢复后时间和视频帧继续推进。纯音频要求无活动视频输出，无音轨视频要求无上一文件遗留音频输出。

两个故障文件要求进入 failed 并使原生内核 idle。每次尝试后检查打开次数增加一次、core/render context 各只创建一次、视频宿主仍属于原窗口。测试结果保留请求 ID、文件 SHA、窗口/屏幕 ID 和前后诊断。

单项播放失败写入结果后继续下一独立文件，以验证恢复路径；取消、窗口被完全遮挡或丢失窗口等全局条件立即退出。全部独立检查结束后，任何素材失败仍使整体 `completed=false`、进程返回非零。所有异常路径都会等待引擎关闭并保存部分报告。

## 可见性与桌面约束

素材与持续播放分别使用 `NSWindowDelegate.windowDidChangeOcclusionState` 记录整个区间，端点/定时检查补充状态，恢复可见不能抹去中间的遮挡。

主动检查仅最小化和恢复当前窗口各一次，要求真实 delegate 回调报告隐藏及恢复、保留隐藏记录、恢复后提交新帧；其间不以轮询状态代替回调。主动检查结束后重新开始持续播放观察。

单窗口场景使用 960×600 点窗口，创建时仅设置一次 floating level，让用户使用其他应用时仍能完成可见性测量。测试不循环抢焦点、不调整其他窗口、不迁移屏幕或切换桌面空间，结束即关闭自己拥有的窗口。正式应用的窗口策略不变。`display-transitions` 仍是独立、需另行安排的入口。

AppKit 的 visible 表示窗口未被完全遮住，不证明每个像素在物理屏幕上都无遮挡；此限制在报告和摘要中保留。

## 运行入口

```sh
/usr/bin/python3 scripts/generate-media-suite.py
./scripts/benchmark-dev.sh --media-suite
```

首个命令生成 `.build/media-suite/`；第二个命令核验素材与依赖、构建、运行并保存源码校验值/日志/原始 JSON。Xcode 等环境变量沿用仓库构建约定。可使用 `BOMU_BENCHMARK_CYCLES` 和 `BOMU_BENCHMARK_SOAK_SECONDS` 调整预检长度。`BOMU_BENCHMARK_PREVIEW_SECONDS` 为每个素材统一保留 0–10 秒画面观察时间，默认 0；不参与用例中的时序断言。验收记录保留真实请求值，不能把短预检写成完整验收。启动窗口最多等待 60 秒，以容纳一次人工/辅助功能置前；播放超时保持原值，测试中途不会反复抢焦点。

Python 行为测试覆盖生成参数被错误降级、旋转元数据缺失、音轨缺失、窗口变更、短暂遮挡和缺少原生恢复证据时拒绝通过；真机运行补足 mock 无法证明的播放、音频输出初始化、回调、停止与释放。
