# 原生播放完整链路

以下链路对应本次实现的 `BomuApp`、`PlayerModel`、`BMMPVSession`、`BMVideoSurface` 与 `PlaybackState`。所有媒体读取发生在本机，不写原视频，不经过业务服务器。

## 开发构建与工具链校验

构建、测试和基准共享工具链锁。Xcode 中直接构建也经过 target 的首个检查阶段，避免只在入口脚本中校验而遗漏实际构建参数。

```mermaid
sequenceDiagram
    actor Developer as 开发者
    participant Entry as build-dev.sh / test-dev.sh / benchmark-dev.sh
    participant Check as toolchain.py
    participant Lock as Dependencies.lock.json
    participant Tools as xcodebuild / xcrun / swiftc
    participant Target as Xcode target
    Developer->>Entry: 构建 / 测试 / 明确选择基准模式
    Entry->>Check: 检查选中的工具链
    Check->>Lock: 读取 toolchain
    Check->>Tools: 读取 Xcode / Swift / SDK 版本和 build
    alt 版本匹配
        Check-->>Entry: 通过
        Entry->>Target: 执行请求的构建动作
        Note over Developer,Target: 从 Xcode 直接构建也从下面的阶段开始校验
        Target->>Check: --build-environment
        Check->>Tools: 探测实际 SWIFT_EXEC / SDKROOT
        Check->>Check: 核对展开后的架构、部署目标、语言模式和 SDK
        alt 构建设置匹配
            Check-->>Target: 通过；继续编译与依赖校验
            Target-->>Developer: 构建或测试结果
        else 设置不匹配或缺失
            Check-->>Developer: 错误；列出期望值和实测值
        end
    else 版本不匹配或探测失败
        Check-->>Developer: 错误；不启动构建或基准
    end
```

- 检查只读取当前工具链；不会修改系统 Xcode 选择或安装工具。
- 基准保存经过校验的 `toolchain.json`，运行库与媒体仍分别校验 SHA-256。

## 打开、替换与播放状态

系统文件入口和选择面板汇入同一模型。图中将原生内部串行队列标在相应参与者后，体现异步命令与结果的区别。

`OpenMediaPanel` 仅在主窗口存在且没有附着 sheet 时创建选择面板，取消不提交 `open`。MKV 的导入类型在 `Info.plist` 中归属 `public.movie`，系统完成类型解析，播放层不按扩展名分支。选择器与系统打开方式的具体回归见 [file-opening.md](file-opening.md)。

```mermaid
sequenceDiagram
    actor User as 用户
    participant UI as BomuApp / OpenMediaPanel
    participant Model as PlayerModel
    participant Engine as MPVPlaybackEngine
    participant Session as BMMPVSession（controlQueue）
    participant MPV as libmpv
    participant State as PlaybackState
    User->>UI: 选择本地文件 / 系统打开文件
    UI->>Model: open(URL)
    Model->>State: open(PlaybackRequest)
    State-->>UI: opening；清除旧快照
    opt 尚未 prepare
        Model->>Engine: await prepare()
        Engine->>Session: prepareWithCompletion
        Session->>MPV: create / configure / initialize
        Note over Session,MPV: 挂接独立 render context 后返回；初始化期间只提交最新请求
        Engine-->>Model: 完成或初始化错误
    end
    Model->>Engine: open(request)
    Engine->>Session: openURL(requestID)
    alt 文件不可达或 loadfile 失败
        Session->>MPV: stop
        Session-->>Engine: failed(requestID, message)
        Engine-->>Model: PlaybackEvent.failed
        Model->>State: receive(event)
        State-->>UI: failed；可重新选择
    else 正常读取
        Session->>MPV: loadfile replace；读取 playlist/0/id
        MPV-->>Session: START_FILE / FILE_LOADED
        Session-->>Engine: loaded（仅匹配 desiredEntryID）
        Engine-->>Model: PlaybackEvent.loaded
        Model->>State: receive(event)
        loop 当前文件已加载，每 100 ms
            Session->>MPV: 读取真实播放属性
            Session-->>Engine: snapshot(requestID)
            Engine-->>Model: PlaybackEvent.snapshot
            Model->>State: receive(event)
            State-->>UI: 显示当前进度与状态
        end
    end
```

- `PlaybackState` 丢弃旧 request ID，即便事件已排进主线程也不会覆盖当前文件。
- `loadfile` 成功只表示接受命令；`FILE_LOADED` 才进入 ready，首个快照之前控制仍禁用。
- 用户文件保持原位，仅由 libmpv 只读打开。损坏文件恢复走同一 `open` 链路。

## 视频绘制、暂停和定位

视频 callback 独立于 SwiftUI 刷新；控制命令通过控制队列执行，快照确认后再更新界面。

```mermaid
sequenceDiagram
    actor User as 用户
    participant Controls as PlaybackControls
    participant Model as PlayerModel
    participant Session as BMMPVSession
    participant MPV as libmpv
    participant Render as BMGLRenderer / BMVideoLayer
    participant Surface as BMVideoSurface
    MPV-->>Render: update callback → dispatch source
    Render->>Render: 锁定 CGL context；render_context_update
    alt layer 可绘制
        Render->>MPV: render 到 CAOpenGLLayer FBO
        Render-->>Surface: 真实视频帧
        Surface-->>User: 保持媒体比例的画面
    else 隐藏或最小化
        Render->>MPV: render(SKIP_RENDERING)
    end
    User->>Controls: 暂停 / 定位 / 音量
    Controls->>Model: togglePause / seek / skip / setVolume
    Model->>Model: 校验当前状态、可定位性和数值范围
    Model->>Session: 经 MPVPlaybackEngine 提交命令（暂停、定位均含 requestID）
    Session->>Session: 拒绝旧文件命令；暂停校验 commandID
    Session->>MPV: 设置属性 / seek absolute+exact 或 relative+exact
    Note over Session,MPV: 相对偏移由内核定位队列累计，不从界面快照计算
    Session-->>Model: 经 MPVPlaybackEngine 返回真实 snapshot（含已执行暂停编号）
    Model-->>Controls: 当前状态和已确认的暂停意图
    User->>Controls: 全屏
    Controls->>Surface: videoView.window.toggleFullScreen
    Surface-->>User: 同一会话继续显示
```

- 时间线拖动期间只保留局部预览，释放时提交一次 seek；seek 不改变暂停状态。
- 前后跳转提交 `.relative`，拖动提交 `.absolute`，连续操作均由内核定位队列排序；进度仍只展示原生快照。所有定位入口共用 `canSeek`。
- 悬停、焦点、拖动和暂停会保留控制层，恢复空闲后重新计算隐藏时间。
- 普通 mpv 命令不进入 render 路径，渲染也不等待控制队列。核心采用音频时钟与零提前量，绘制和隐藏跳帧均不等待未来目标时间。
- 暂停意图按请求与命令编号确认；布尔值相同的旧状态不能提前确认新意图，旧编号不能覆盖已确认的新状态。

## 自然结束、停止与退出

自然 EOF、手动停止和应用退出是不同用例。退出必须按资源依赖顺序完成才能允许进程结束。

```mermaid
sequenceDiagram
    actor User as 用户 / 系统
    participant Lifecycle as AppLifecycle
    participant Model as PlayerModel
    participant Session as BMMPVSession
    participant MPV as libmpv
    participant Render as BMVideoSurface / BMGLRenderer
    MPV-->>Session: END_FILE(EOF, playlist_entry_id)
    Session-->>Model: ended（只接受当前 entry）
    Model-->>User: 播放结束；可重新播放
    opt 用户停止
        User->>Model: stop()
        Model->>Model: 清空请求与快照
        Model->>Session: stop()
        Session->>MPV: stop；停用采样
        Model-->>User: 回到启动页
    end
    User->>Lifecycle: 关闭最后窗口 / 退出应用
    Lifecycle->>Model: await shutdown()
    Model->>Model: 拒绝新意图；停止接收事件；等待初始化
    Model->>Session: shutdownWithCompletion
    Session->>MPV: 解除 wakeup callback
    Session->>Session: 取消事件 source 和采样 timer
    Session->>Render: shutdownWithCompletion
    Render->>MPV: 解除 render callback；free render context
    Render-->>Session: 完成
    Session->>MPV: terminate_destroy(handle)
    Session-->>Model: 完成
    Model-->>Lifecycle: 完成
    Lifecycle-->>User: 允许应用退出
```

- 退出 task 由模型持有，重复调用等待同一个 task，不重复释放资源。
- 所有跨队列步骤异步串接，没有主线程同步等待控制队列的调用。
- 完整验收和未验证项见 [requirements.md](requirements.md)。

## 开发基准与诊断采集

该入口属于同一工程中的独立开发工具，不进入产品界面。诊断只复制资源所有者提供的事实，不改变播放阶段。

```mermaid
sequenceDiagram
    participant Script as benchmark-dev.sh
    participant Test as BomuBenchmark（AppKit 应用）
    participant Engine as MPVPlaybackEngine
    participant Control as BMMPVSession（controlQueue）
    participant Render as BMGLRenderer（renderQueue + lock）
    participant OS as macOS 进程统计
    Script->>Script: 校验运行库与合成媒体 SHA-256
    Script->>Test: 启动独立应用；常规模式限制 300 秒
    Test->>Test: NSApplication.run；确认窗口实际可见
    Test->>Engine: prepare / open / pause / replace / stop
    loop 检查点按需采集
        Test->>Engine: await diagnostics()
        Engine->>Control: 复制存活状态、解码器、真实尺寸、采样次数
        Control->>Render: 经主队列异步请求渲染统计
        Render->>Render: 加锁复制绘制计数、首帧与目标提交时序
        Render-->>Engine: 主队列完成；转换为 Swift 值
        Engine-->>Test: PlaybackDiagnostics
        Test->>OS: CPU 累计时间与当前内存
        OS-->>Test: 进程统计
    end
    Test->>Engine: await shutdown()
    Test->>Engine: 确认 core 和 render context 已释放
    Test-->>Script: JSON 与进程日志；成功或失败
    Script->>Script: 仅对完整结果生成汇总
```

文件名、用户路径与媒体内容不进入诊断对象。首帧发生在渲染成功且 `glFlush` 之后；重绘旧帧或绘制空白背景不算首帧。指标口径与复现方式见 [benchmark.md](benchmark.md)。

## 正式界面的窗口验证

`--single-window` 使用同一个普通窗口承载正式 SwiftUI 页面。只有明确选择 `--display-transitions` 才执行下图中的可选迁移和全屏步骤。全屏完成来自系统委托回调，调用 `toggleFullScreen` 本身不代表通过。

2026-10-14 单窗口模式移除 `.moveToActiveSpace`，启动先等待激活、主窗口焦点及可见状态；窗口创建、显示、移动和换屏会留下位置日志。两次候选启动仍有屏幕变化失败，新日志尚未取得运行证据，不能据此宣称跨屏问题已解决，见 [候选启动记录](../media-suite/desktop-candidate-validation.md)。

```mermaid
sequenceDiagram
    participant Script as benchmark-dev.sh（明确指定模式）
    participant Test as WindowLifecycleBenchmark
    participant UI as PlayerScreen / PlaybackControls
    participant Model as PlayerModel
    participant Engine as MPVPlaybackEngine
    participant Window as NSWindow / NSWindowDelegate
    Script->>Script: 校验连续 15 分钟合成片与源码哈希
    Script->>Test: single-window / display-transitions；限制 1800 秒
    Test->>UI: NSHostingView 承载生产页面和稳定 videoView
    UI->>Model: prepare（同一 startupTask）
    Test->>Model: 静音；open 一次
    Model->>Engine: prepare / open
    loop 每轮窗口组合操作
        opt display-transitions 模式
            Test->>Window: 同一窗口迁移到下一屏并改变尺寸
        end
        Test->>Model: togglePause；等待真实暂停快照
        Model-->>UI: 暂停使控制层保持可见
        opt display-transitions 模式
            Test->>Window: toggleFullScreen
            Window-->>Test: windowDidEnterFullScreen
        end
        Test->>Model: togglePause；等待较新编号的恢复快照
        opt display-transitions 模式
            Test->>Window: toggleFullScreen
            Window-->>Test: windowDidExitFullScreen
        end
        Test->>Engine: 等待恢复后新帧；采集 diagnostics
        Test->>Test: 校验屏幕 / 倍率 / 宿主 / 创建次数；保存轮次
    end
    Test->>Test: 开始 soakVisibility；读取初始可见性
    loop 同文件连续播放
        Window-->>Test: windowDidChangeOcclusionState（状态改变时）
        Test->>Test: 记录变化时间；恢复可见不清除中断
        Test->>Test: 每 10 秒保存帧与进程检查点；任一遮挡使本轮失败
    end
    Test->>Test: 成功、失败或取消均结束并保存可见性记录
    Test->>Model: stop；等待原生 idle
    Test->>Engine: 5 秒内新帧、绘制和快照应不增长
    Test->>Model: await shutdown
    Test->>Engine: 验证 core / render context 已释放
    Test-->>Script: 完成报告；异常则保存失败及释放状态
    Script->>Script: 仅为完成报告生成 summary.md
```

- `WindowLifecycleReport` 与常规播放基线使用独立 schema；原始输入、源码与日志仍放在同一个运行目录。
- schema 3 的汇总要求可见性观察已经结束且没有遮挡记录；schema 1/2 汇总明确说明只验证过周期采样点，不升级历史证据。
- 播放器只打开长片一次；素材生成器将有许可的合成片复用为连续时间戳文件，不通过播放器反复 seek 或 reopen 冒充连续播放。
- 报告中的图层提交、屏幕属性和短时进程统计不能代替物理音画同步、色准或长时间泄漏验收。
