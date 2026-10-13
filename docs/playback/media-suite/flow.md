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
