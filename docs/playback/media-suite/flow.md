# 真实调用链

## 素材矩阵与单窗口播放

以下链路使用正式播放页面与渲染适配层，分别记录素材结果、窗口可见性和资源释放。

```mermaid
flowchart TD
    R[30 个配方 / 自有图案与波形] --> G[FFmpeg 生成 + FFprobe 参数核对]
    G --> D[完整解码 / 特殊时间戳检查]
    D --> M[manifest: 来源 / CC0 / SHA / 预期]
    M --> C[benchmark-dev.sh 核验文件和依赖]
    C --> W[WindowLifecycleBenchmark 创建唯一窗口、模型和引擎]
    W --> S[MediaSuiteManifest 一次解析]
    S --> L[逐个素材复用窗口和播放会话]
    L --> P[PlayerModel 提交打开、暂停、定位与恢复意图]
    P --> E[MPVPlaybackEngine → BMMPVSession 控制队列]
    E --> V[BMVideoSurface / CAOpenGLLayer 真实帧提交]
    E --> VO[观察 vo-configured]
    VO -->|视频输出关闭或未知| CL[渲染队列完整清屏；不重画上一视频纹理]
    CL --> Q
    E --> A[真实音频解码器和音频输出，测试音量为零]
    E --> B[原生事件 → PlaybackState → PlayerScreen]
    V --> Q[按需诊断与行为断言]
    A --> Q
    B --> Q
    Q --> F{单项结果}
    F -->|通过或播放失败均记录| N[继续下一文件，观察恢复]
    N --> L
    N -->|30 项完成| T[同窗口 100 次暂停/恢复]
    T --> O[最小化 / 恢复各一次 + 真实遮挡回调]
    O --> U[独立开始 120 秒持续可见观察]
    U --> X[停止后 5 秒无新增帧 / 绘制 / 采样]
    X --> Z[先释放 render context，再销毁 mpv]
    Z --> J[保存完整或失败报告；关闭唯一测试窗口]
    W -->|取消 / 全局条件失败| Z
    Q -->|窗口不可见 / 取消| Z
```

存在素材失败时，后面的独立检查可以继续执行，但最终整体仍失败。主动最小化、素材播放和持续播放的可见性记录互相独立。交付结果以实际报告为准，图中流程不代表每轮必然走完。

## TS 定位的独立内核对照

该链路用于隔离解封装问题，所有帧写入内存，声音送入 null 输出。它不启动应用窗口，也不提供桌面播放或实际听感验收证据。

```mermaid
sequenceDiagram
    participant Dev as 开发者
    participant Script as verify-seek-candidate.py
    participant Build as FFmpeg 9.0.1 源码构建
    participant Probe as SeekProbe
    participant MPV as libmpv
    participant Format as libavformat
    participant Render as 软件渲染线程
    Dev->>Script: 运行独立对照
    Script->>Script: 核验工具链、固定运行库、源码 SHA 与 CC0 素材
    Script->>Build: 同参数构建未修改版本与候选版本
    Build-->>Script: 两个独立 libavformat，正式依赖缓存不变
    Script->>Script: 只重封装 MP4/MKV/TS，对照完整解码像素 SHA
    loop 固定运行库 / 重编原版 / 候选版本
        Script->>Probe: 媒体、目标、明确的视频或音频预期
        Probe->>MPV: loadfile → pause → absolute+exact seek
        MPV->>Format: 按目标时间请求定位
        Format-->>MPV: 定位后的编码包
        MPV->>Render: 解码帧 / render update
        Render-->>Probe: 只统计 PRESENT 且非 REDRAW/REPEAT 的新帧
        MPV-->>Probe: PLAYBACK_RESTART、原生位置、暂停及音频输出状态
        Probe->>MPV: resume，继续观察新帧
        Probe->>Probe: stop → 回收渲染线程 → render context → core
        Probe-->>Script: JSON 测量与独立日志
        Script->>Script: 判定目标误差、暂停保留、定位和恢复的新帧
    end
    Script-->>Dev: report.json：实验结果、哈希、未接入应用的状态
```

源码修正限定在 MPEG-TS 视频包的定位语义。脚本不会根据文件名或扩展名修改播放器策略，也不会改写正式 `Dependencies.lock.json`。任何构建、协议、超时或候选行为失败都会阻止实验整体通过；原版已知失败作为对照如实保留。

## 候选内核的交错操作与释放

该链路复用已经验证的实验运行库，单个子进程始终拥有自己的 core 和渲染线程；可见应用与正式依赖均不受修改。

```mermaid
sequenceDiagram
    participant Dev as 开发者
    participant Script as verify-seek-lifecycle.py
    participant Probe as SeekProbe
    participant MPV as libmpv / 候选 libavformat
    participant Render as 软件渲染线程
    Dev->>Script: 指定已成功的实验目录
    Script->>Script: 核对报告、依赖锁、库文件、修正及 CC0 媒体 SHA
    Script->>Probe: 编译并启动独立进程，30 秒期限
    Probe->>MPV: loadfile，四次 pause / seek / resume
    MPV->>Render: 定位帧与恢复后的新帧
    Probe->>MPV: 100 条异步 seek
    MPV-->>Probe: 全部命令回复、最终位置、保留暂停状态
    Probe->>MPV: seek 后立即 loadfile replace
    MPV-->>Probe: 新路径、从头播放位置与持续新帧
    Probe->>MPV: seek 后立即 stop
    MPV-->>Probe: idle-active=true，vo-configured=false
    Probe->>Probe: 观察停止后一秒无新增媒体帧
    Probe->>Render: 移除回调、通知退出并 join
    Probe->>MPV: 释放 render context，再销毁 core
    Probe-->>Script: 有序测量、退出状态与独立日志
    Script->>Probe: 每种运行库另做 10 次 loadfile 排队后立即关闭
    alt 断言失败、协议不完整或超时
        Script-->>Dev: 保留失败证据，整体不通过
    else 候选全部通过且原版对照符合预期
        Script-->>Dev: 后台生命周期验证通过；桌面验收仍独立
    end
```

该工具检查 libmpv 命令交错，不提供应用层 request ID、OpenGL、实际声音或物理同步证据。时间测量在 core 销毁后使用系统单调时钟，避免再次调用已失效的 mpv handle。

## 播放用候选构建与独立应用准备

该链路补齐最小诊断配置不覆盖的读取能力，先核验运行库清单和实际媒体行为，再准备供单窗口验收的应用。准备应用的步骤不会启动它。

```mermaid
sequenceDiagram
    participant Dev as 开发者
    participant Verify as verify-seek-candidate.py
    participant Inspect as runtime_capabilities.py
    participant Probe as SeekProbe
    participant Prepare as prepare-seek-candidate-app.py
    participant Xcode as BomuBenchmark 构建
    Dev->>Verify: --profile playback-format
    Verify->>Verify: 核验固定源码与运行库；同参数构建原版和 TS 候选
    loop 每种运行库使用独立进程
        Verify->>Inspect: 核验版本、库许可、格式/协议注册及导出符号
        Inspect-->>Verify: 逐项清单，保留重复注册项
    end
    alt 与固定运行库存在清单差异
        Verify-->>Dev: 保存失败报告并停止
    else 清单一致
        Verify->>Verify: 生成压缩 MOV，保持媒体偏移，核对完整解码校验值
        Verify->>Probe: 9 组候选/原版/未修改重编真实内核对照
        Probe-->>Verify: 定位位置、暂停意图和新帧记录
        Verify-->>Dev: 完整报告、源文件和运行库身份
    end
    Dev->>Prepare: 指定成功的播放配置实验，可选新的 --output 目录
    Prepare->>Prepare: 重新核验实验、媒体、源码与运行库
    Prepare->>Xcode: 构建当前生产播放界面的基准 target
    Xcode-->>Prepare: BomuBenchmark.app
    Prepare->>Prepare: 克隆候选，仅替换 libavformat，临时签名并验证
    Prepare->>Prepare: 核对其他动态库不变，保存 desktop-candidate.json 及原实验身份
    Prepare-->>Dev: 独立 BomuSeekCandidate.app，未启动、未计为桌面通过
```

正式依赖缓存和 `Dependencies.lock.json` 不参与修改。清单比较、内存帧、应用构建和临时签名分别提供有限证据；可见播放、物理声音和发行条件仍有独立验收边界。

## 候选应用的单窗口运行与归档

2026-10-14 的运行复用已准备的应用，通过各结果目录保留的 `invocation.py` 启动。运行期间仅读取进程日志，不接入桌面操控工具；短时诊断与完整矩阵分别保存，不改变准备时 receipt。

```mermaid
sequenceDiagram
    participant Dev as 开发者
    participant Run as invocation.py
    participant App as BomuSeekCandidate.app
    participant Window as WindowLifecycleBenchmark
    participant Player as PlayerModel / MPVPlaybackEngine
    participant Report as window-lifecycle.json / process.log
    Dev->>Run: 明确选择 single-window 或 media-suite
    Run->>Run: 核对 receipt 的源码/二进制身份与素材 SHA
    Run->>Run: 创建独立结果目录，保留 receipt、参数与素材清单
    Run->>App: 启动已有候选，可见、静音、一个窗口
    App->>Window: 等待激活与可见，记录创建/移动/换屏事件
    opt media-suite
        loop 30 个独立素材
            Window->>Player: 打开、暂停、定位、恢复或预期拒绝
            Player-->>Window: 内核状态、实际新帧、音视频参数
            Window->>Report: 保存结果及窗口/屏幕身份
        end
    end
    Window->>Player: 暂停恢复、同窗口最小化恢复、持续播放、停止
    Player-->>Window: 命令确认、新帧、停止静默与资源释放
    Window->>Report: 保存完成或失败状态，不抹去此前失败
    App-->>Run: 自动关闭自己的窗口并退出
    Run-->>Dev: 退出码与原始证据
    Dev->>Report: 核对汇总断言、身份与哈希后归档
```

- 完整矩阵的 100 次暂停恢复及 120 秒持续播放与短诊断分开记录；短诊断不计作完整验收。
- 同屏、可见性及新帧断言保留；窗口发生变化时不能通过强制搬回或抢焦点修饰结果。
- 自动报告、用户实际观感和物理音画同步各有证据边界。正式运行库仍未替换，工具链升级后的重建也需独立验证。
