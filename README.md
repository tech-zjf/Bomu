# Bomu · 泊幕

一款面向 macOS 的本地视频播放器。当前名称暂定为 **Bomu**，先开发功能，后续可以调整品牌名称。

项目采用 Swift 6、SwiftUI 和 AppKit，以 libmpv 提供播放能力。核心功能按离线优先设计，不需要自建业务服务器。首个公开版本为 v0.2，当前处于 v0.0 播放验证阶段。

仓库：[tech-zjf/Bomu](https://github.com/tech-zjf/Bomu)。初始化时为私有仓库，公开发行按产品计划推进。

## 当前状态

- 当前开发里程碑为 **`v0.0.1-dev.1`**：最小原生播放器与审查修复快照。版本范围、验证结果和下一步见 [里程碑记录](docs/playback/native-poc/milestone.md)；v0.0 阶段验收尚未完成。
- 已实现 macOS 14+、Apple Silicon 的原生最小播放链路，固定 mpv 0.41.0 / FFmpeg 9.0.1。
- 支持本地单文件打开、播放/暂停、定位、音量、原生全屏、停止和失败恢复。
- 播放状态、内核适配和 AppKit 视频宿主分离；使用 OpenGL render API，当前验证 SDR。
- 已通过开发构建、状态测试和真实内核集成测试，并用用户指定的视频完成画面、比例及声音验证。
- 已归档产品方案、83 项版本任务、UI 参考和命名研究。
- v0.0 完整验收仍在进行；媒体库、原生 HDR 与公开发行包尚未实现。具体证据和待验收项见 [原生播放 POC](docs/playback/native-poc/requirements.md)。

## 打开项目

首次在仓库根目录准备固定的开发依赖，然后构建：

```sh
python3 scripts/dependencies.py bootstrap
./scripts/build-dev.sh
```

也可以在依赖准备后使用 Xcode 打开 [Bomu.xcodeproj](Bomu.xcodeproj)，选择 **Bomu** scheme，在本机 Mac 上运行。

脚本与 Xcode 构建均检查 [Dependencies.lock.json](Config/Dependencies.lock.json) 中的 Xcode、Swift 和 SDK 版本/build，以及实际架构和部署目标；不匹配时明确失败。当前使用 Xcode 26.1.1（17B100）、Swift 6.2.1、macOS SDK 26.1（25B74），应用最低支持 macOS 14。工具链选择与校验范围见 [依赖说明](ThirdParty/libmpv/README.md)。

该脚本构建无分发签名的本地开发版本，产物位于 `.build/DerivedData/Build/Products/Debug/Bomu.app`。应用内携带运行库，不依赖本机 Homebrew 的 libmpv。它不是经过签名公证的发布包；当前依赖配置会阻止 Release 构建，详见 [依赖来源与许可边界](ThirdParty/libmpv/README.md)。

默认验证命令运行构建校验的行为测试及无界面播放逻辑测试，不启动播放器：

```sh
./scripts/test-dev.sh
```

`BomuLogicTests` 直接编译生产播放状态与模型源码，不依赖应用宿主或 libmpv。需要真实内核验证时，另外运行 `./scripts/test-dev.sh --native`；此入口会启动应用宿主与测试窗口，应先安排好桌面使用。

首次原生测试需要本机 `ffmpeg` / `ffprobe`，用于生成有来源记录的合成测试片；生成器需包含 libx264、libx265 和 AAC 编码器。测试片、真实属性 manifest、依赖缓存和测试产物都在忽略的 `.build/` 下。原生自动测试静音运行，声音、颜色和同步仍有专门人工验收要求。

工程脚本兼容 Python 3.9+。原生测试和基准运行前会逐文件核对素材 manifest 的 SHA-256；Xcode 复制测试素材时也执行相同校验。文件缺失或发生变化会明确失败，需要确认来源后重新生成。

可见播放测试必须明确选择模式。日常使用同一个普通窗口，程序不会自动缩放、全屏或迁移屏幕：

```sh
./scripts/benchmark-dev.sh --single-window
```

此命令构建并运行独立开发工具，在一个静音窗口中承载正式播放控件，检查暂停恢复、持续出帧及停止后的资源。窗口被遮挡导致可见播放断言不成立时，记录失败并退出，不反复置前重试。完整证据保存到 `.build/benchmarks/`；测量口径和限制见 [播放性能与资源验证](docs/playback/native-poc/benchmark.md)。

不带参数只显示帮助。`--playback` 是首帧、CPU/内存和切换基线，会新建/关闭及缩放测试窗口；`--display-transitions` 会反复全屏与跨屏，仅在用户明确允许占用桌面时单独安排。普通“继续开发”不触发这两种测试。

`--playback` 模式也会生成并解码校验闪光/短音同步片，静音检查帧提交目标。物理音画同步仍需外部测量；暂停交错状态与时序调整的依据见 [第一轮审查跟进](docs/playback/native-poc/review-follow-up.md)。

品牌显示名称、版本和部署目标集中在 [Config/App.xcconfig](Config/App.xcconfig)。未来修改显示名称时，不要顺带变更已经发行的 Bundle ID 或用户数据目录。

## 开发资料入口

| 路径 | 用途 |
| --- | --- |
| [开发定稿](player_plan/开发定稿/Mori播放器开发定稿.html) | PRD、技术架构、版本范围与验收标准；开发执行基线为 1.1 版 |
| [UI 设计稿](player_plan/开发定稿/UI设计稿.html) | 可离线打开的交互原型；作为视觉和交互参考 |
| [开发任务](player_plan/开发定稿/开发任务.json) | 83 项任务、依赖和验收要求 |
| [设计规范](player_plan/开发定稿/设计规范.json) | 颜色、字体、间距和控件尺寸 |
| [player_ui](player_ui/) | 各页面截图、设计素材和早期预览 |
| [player_naming](player_naming/) | 命名过程的历史记录，不阻塞功能开发 |
| [AGENTS.md](AGENTS.md) | 面向开发协作者的工程约定 |
| [播放实现与验证记录](docs/playback/native-poc/requirements.md) | 当前实际行为、验证结果和未完成项 |
| [播放模块设计](docs/playback/native-poc/technical-design.md) | 状态、并发、资源与窗口边界 |
| [完整调用链](docs/playback/native-poc/flow.md) | 打开、渲染、控制、失败和退出的 Mermaid 链路 |

资料中的 **Mori** 是同一项目的旧暂定名；当前仓库与应用名称为 **Bomu**。历史文档和校验值保留原样，不需要为了改名重新制作设计稿。版本范围、UI 和交互规则存在差异时，以 `player_plan/开发定稿` 的 1.1 版为准，再应用用户后续明确的调整。

早期生成和预览脚本包含原机器路径，仅保留为制作过程记录。构建应用使用 `scripts/` 下的工程脚本。文档渲染缓存、重复导出包和中间检查图留在本地，由 `.gitignore` 排除。

## 第一阶段：v0.0 播放验证

按 `开发任务.json` 中 A 组任务推进，先完成下面这条完整路径：

1. 固定 libmpv/FFmpeg 版本、头文件、二进制来源、构建配置与校验值。
2. 建立 `PlaybackEngine`、mpv 适配层、事件循环和稳定的 AppKit 视频宿主。
3. 从本地选择真实 H.264/H.265 文件，验证画面、声音、暂停、定位和停止。
4. 加入已确认的播放浮层，验证窗口缩放、全屏和控制层不会重建播放会话。
5. 记录 SDR 颜色、资源释放和基础样本结果；通过后再进入 v0.1 本地播放器和 v0.2 媒体库。

当前最小播放链路不代表 A05 或 v0.0 已完成。任务完成必须有真实构建、播放或对应测试证据，完整验收缺口记录在本次实现文档中。

## 产品约束

- 仅做 macOS，最低 14，优先 Apple Silicon。
- SwiftUI/AppKit 原生界面；HTML 原型不作为生产应用的 WebView 界面。
- 先实现可靠本地播放；数据库、缩略图、更新和网络流按版本引入。
- 只读引用原视频；不转码、不覆盖、不移动或删除用户原文件。
- 首版采用已确认的浅灰蓝、白色、深海军蓝配色，以及 Apple TV 风格的播放控件。
- 不包含摄像头加密文件解密；兼容能力按实际测试公布，不承诺所有格式。
- 公开发行时再完成依赖许可、Developer ID、公证、自带依赖安装包和更新链路。

## 本地环境记录

2026-10-13 使用 Xcode 26.1.1、Apple Swift 6.2.1 完成本机验证。应用内核版本、构建配置、头文件、二进制来源和 SHA-256 见 [Dependencies.lock.json](Config/Dependencies.lock.json)。本机 FFmpeg 仅用于合成测试片，不作为应用运行时依赖。
