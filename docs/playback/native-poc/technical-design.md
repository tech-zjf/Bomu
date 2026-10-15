# 原生播放设计

## 模块和所有权

当前保留一个应用工程，按稳定职责分目录。正式产品为 `Bomu` target；`BomuLogicTests` 提供无应用宿主的逻辑测试，`BomuTests` 提供应用宿主中的原生集成测试；`BomuBenchmark` 为可见播放测量提供独立窗口事件循环。没有为测试分离新增 Swift package 或改动产品模块边界。

| 边界 | 责任与所有者 |
| --- | --- |
| `App` | 组合 `MPVPlaybackEngine` 和 `PlayerModel`，保持整个窗口生命周期的单一实例，协调系统退出 |
| `PlayerFeature` | `@MainActor @Observable PlayerModel` 接受播放意图；SwiftUI 视图读取状态，持有局部拖动、焦点、浮层状态 |
| `Playback` | 值类型 `PlaybackRequest`、`PlaybackSnapshot`、`PlaybackEvent`、`PlaybackState`；窄接口 `PlaybackEngine` 不泄漏 mpv 指针或视频视图 |
| `Playback/MPV` | `MPVPlaybackEngine` 一次性转换事件；`BMMPVSession` 独占 core handle、命令和事件队列 |
| `Rendering` | `BMVideoSurface` 持有 OpenGL renderer/layer；`VideoHostView` 只把既有 NSView 放进 SwiftUI 布局 |
| `DesignSystem` / `Resources` | 品牌颜色与本地化文案，不能混入播放逻辑 |

这是边界适配器和显式状态机的组合。没有引入通用 Service 层、动作级类、全局播放器或 DI 框架。`PlaybackEngine` 的隔离点对应实际的 C API 边界和状态测试需求，而非假想的多内核切换。

## Swift 与原生边界

Swift 负责应用和功能状态，全部播放 UI 变更在 `MainActor`。初始化和释放使用 `async`/`await`，由模型持有 task，退出会等待尚未完成的初始化。打开、暂停等命令只提交到适配器的串行队列，最终结果通过事件返回，不能把“命令已提交”当成“文件已加载”。

引擎生命周期由 `PlayerModel.StartupState` 单独表达：未启动、初始化中、可用、失败、正在退出、已退出。初始化失败后保留错误并拒绝新的媒体意图；界面显示错误和退出重开动作，⌘O 同步禁用，避免出现看似可操作但被模型静默丢弃的入口。初始化完成前仍允许提交打开意图，模型只保留最后一个请求并在引擎就绪后发送。该状态与单个文件的 `PlaybackState.Phase` 分开，因为它们生命周期不同。

C 回调、OpenGL current context 和生命周期跨线程的部分留在两个小型 Objective-C 适配文件中。这样 Swift 不需要把不可发送的裸指针包装为 `@unchecked Sendable`，也不会为了满足编译器而伪造线程安全。

Objective-C 不自动提供并发安全；安全性来自以下明确合同：

1. `BMMPVSession` 的 `_controlQueue` 是 handle 与请求映射的唯一访问者。wakeup callback 只合并 dispatch source，不执行命令。
2. render API 使用独立 `_renderQueue`。Core Animation 也可能在主线程触发绘制，两条路径经同一递归锁和 CGL context 锁串行化，使用同一个 current context。
3. 渲染路径不调用普通 mpv 命令，也不等待 control queue；control queue 不同步等待主线程。释放按异步完成回调串起来。
4. layer 隐藏时仍消费 pending render updates，避免 advanced control 等待一个永不绘制的帧。
5. 解除 C 回调后再释放对应 dispatch source；render context 与自有 CGL context/pixel format 在 render queue 释放，随后主线程从 view 分离 CAOpenGLLayer，再销毁 mpv handle。Swift 停止接收状态之后才开始 teardown。
6. CAOpenGLLayer 的 context/pixel format 复制、显示和绘制回调，在同一 renderer 锁下读取并保留资源。关闭先获取该锁并清空所有者指针；关闭后迟到的回调在接触已释放的 CGL 资源前直接返回。
7. Core Animation 的 CGL 复制回调要求非空返回。renderer 自有资源创建失败或关闭后已清空时，回调使用 superclass 提供的有效备用对象；播放器仍由 `creationError` 显式失败，随后正常 teardown，不会把备用对象当作可播放 renderer。

主线程的 layer 绘制沿用 AppKit 的现有事务，避免在系统提交过程中重复开启事务；后台渲染队列没有 AppKit run loop，必须使用显式 `CATransaction` 完成更新。该区别由线程和框架职责决定，不按视频格式或测试样本添加分支。

## 状态与请求身份

`PlaybackState.Phase` 区分 `idle`、`opening`、`ready`、`ended`、`failed`。暂停、定位、缓冲是 snapshot 中独立事实，不再组合多个含义重叠的“正在播放”布尔值。

每次打开由模型生成递增 request ID。mpv 的 `loadfile replace` 返回后，适配层读取 `playlist/0/id`；通过 `START_FILE` / `END_FILE` 的 `playlist_entry_id` 判断事件属于哪一个请求。相同路径连续重播也有不同身份。到 Swift 边界后再校验 request ID，阻止已经排进主线程的旧事件污染当前文件。

初始化期间只保留最后一次打开意图；停止立即清空当前请求，之后晚到的快照和错误都无效。自然 EOF 与手动 stop 分离。文件失败时先停止内核，避免错误页背后继续播放声音。

时间、时长、暂停与音量来自 mpv。时长未知时展示未知并停止提供定位，首次快照之前禁用播放控制。`pendingPause` 保存尚未确认的 `PlaybackPauseRequest`，包含文件请求和命令编号；原生控制队列设置属性成功后，采样结果才携带对应编号。仅当文件、编号及目标值均匹配才解除意图。值恰好相同的旧快照不能确认新命令，已确认编号之前的快照也不能回退状态。时间线在拖动时仅显示局部预览，释放时提交一次定位。

播放快照最多每秒采样 10 次，仅在文件加载后启用；空闲、错误、结束和退出都会停用采样。视频绘制通过 render callback 驱动，不由 SwiftUI 或快照采样驱动。后续能耗优化以测量为依据。

定位使用 `PlaybackSeekRequest`，包含文件 `requestID` 和 `.absolute` / `.relative` 目标。时间线提交绝对秒数，前后跳转保留相对偏移；模型不把偏移加到可能落后的 10 Hz 快照，也不另存一份“已播放位置”。`BMMPVSession` 在控制队列拒绝旧文件请求，然后映射为 `absolute+exact` / `relative+exact`。固定 mpv 的 `queue_seek` 会合并尚未执行的相对定位；正在解码时也会沿用上一定位目标。因此连续相对定位、绝对定位后接相对定位共用同一个内核事实源。命令成功表示接受意图，实际位置与 `isSeeking` 仍由原生快照确认。

`PlayerModel.canSeek` 是本阶段定位能力的统一判断：当前文件 ready、有快照、原生允许定位且时长已知。按钮、菜单、时间线与模型入口共用它；停止、终态和切文件加载期间不可定位。未知时长的定位策略仍留待后续需求，不做隐式降级。

恢复播放位置属于文件打开意图，不是文件加载后的普通定位。`PlayerModel` 在打开前读取历史，并把通过有限非负值校验的位置放进 `PlaybackOpenOptions`；`BMMPVSession` 使用结构化 `mpv_command_node` 将它作为该文件的 `loadfile` `start` 选项提交。首个解码/呈现阶段因此从目标附近开始，不依赖主线程收到首份快照后再补发 seek。无历史、关闭自动恢复和显式从头播放都会传空选项；重试与明确的“继续播放”会重新读取并带上保存点。mpv 0.41 的 `loadfile` 文件选项及节点映射格式以[官方参考手册](https://mpv.io/manual/stable/)为准。真实内核首分快照验证尚待应用宿主验收，不把逻辑测试视为画面证据。

## 视频与窗口

SwiftUI 对视频宿主的更新不创建会话、切换内核或释放渲染器。切文件和调整布局都复用同一 NSView。全屏操作针对该宿主所在窗口，不查询可能属于其他窗口的全局 key window。

当前使用 `CAOpenGLLayer`、OpenGL 3.2 core、sRGB layer 和固定 SDR 输出目标；mpv 负责适配文件显示比例。没有硬编码 16:9，也不为本次用户样本添加专用缩放逻辑。HDR 源文件可能被内核映射到 SDR，但尚未验证，不能作为原生 HDR 能力宣传。

视频调度显式采用 `video-sync=audio` 与 `video-timing-offset=0`。这样 mpv 在音频时钟目标到期时交付视频，渲染与跳帧路径均使用非阻塞调用，避免在 AppKit 绘制和持锁期间等待未来目标。它是 render API 文档提供的零提前量方案；不能同时保留默认 50 ms 提前量却禁用等待。窗口合成和实际屏幕刷新还有额外延迟，物理音画同步仍需外部测量。

## 原生播放器界面合同（A02）

视觉事实源是 `player_plan/开发定稿/UI设计稿.html` 和同目录 `设计规范.json`。播放器窗口使用系统标题栏，视频内容区保持源宽高比；控制层依次提供顶部文件/打开/停止操作、中央前后 10 秒与播放/暂停、底部时间线/音量/全屏。静止 2.5 秒后隐藏控制；暂停、拖动、焦点或悬停时保留。按钮尺寸、间距、颜色、字体和减少透明度时的高对比回退使用设计 token，不另创一套视觉方向。

原生结构映射为 `PlayerScreen` 按 `PlaybackState.Phase` 选择空闲、打开中、播放中、自然结束或失败界面；空闲页由 `EmptyPlayerView` 提供打开本地媒体的入口，启动失败由应用外壳覆盖显示 `StartupFailureView`，给出可复制的错误详情和退出重开的动作。`VideoHostView` 始终占据黑色视频区域；播放中由 `PlaybackControls` 组成覆盖层。`PlayerModel` 是状态事实源，视图不访问 mpv。播放中当前文件名来自 request URL，时间与音量来自原生快照；尚无真实数据时不伪造时长或媒体信息。

| 窗口内容尺寸 | 设计用途 | 需核对的重点 |
| --- | --- | --- |
| 960 × 640 pt | 常用小窗口 | 中央控制不遮挡主体；时间、音量和全屏仍可达 |
| 1280 × 800 pt | 常用工作窗口 | 控件布局与自动隐藏稳定；长文件名截断而不挤压按钮 |
| 1440 × 900 pt | 大窗口 | 画面比例与控制层边距保持一致，不拉伸视频 |

当前代码已具备对应尺寸下的最小播放布局、⌘O/空格/左右方向键、局部焦点状态、本地化可访问标签和减少透明度回退。初始化失败时提供明确退出重开操作；相关启动阶段状态测试见 `PlayerModelTests.testStartupFailureIsVisibleAndRejectsMediaRequests`。本轮在同一个普通窗口现场确认了 ⌘O 打开系统面板、Escape 取消后返回启动页，并重新打开 16:9 本机素材播放至自然结束。字幕、音轨、倍速和队列入口属于 B03/B05/B06，不把它们提前做成无效按钮。三种尺寸下的可见核对、VoiceOver 顺序及完整播放中键盘路径仍未完成；因此 A02 暂记为部分完成，不用源码检查替代实际界面验收。

## 验证与演进

工具链校验由 `scripts/toolchain.py` 独占，使用 `Config/Dependencies.lock.json` 中已有的 `toolchain` 事实源。脚本入口提前检查选中的 Xcode、Swift 编译器与 macOS SDK，四个 target 的首个构建阶段再检查实际展开的 `ARCHS`、`MACOSX_DEPLOYMENT_TARGET`、`SWIFT_VERSION` 和 SDK/build；`SWIFT_EXEC` 与 `SDKROOT` 覆盖参与实际探测。缺失或不匹配明确失败，不自动安装、切换或按版本大小猜兼容性。默认测试入口同时运行该校验器的输入/拒绝行为测试，播放运行时没有新增检查或开销。

`PlaybackStateTests` / `PlayerModelTests` 在 `BomuLogicTests` 中验证可观察状态和竞态。该 target 直接编译同一份生产 `PlaybackEngine`、`PlaybackState` 与 `PlayerModel`，不包含应用入口、AppKit 视频宿主或 libmpv；默认 `test-dev.sh` 因而不会打开播放器。`MPVIntegrationTests` 保留在 `BomuTests`，通过 `TEST_HOST` / `BUNDLE_LOADER` 与 `@testable import Bomu` 运行实际应用模块，使用显式 `--native` 入口。窗口可见性和持续出帧负载由独立基准另外验证，不能由逻辑测试通过推断。

`Tools/PlaybackBenchmark` 用普通 AppKit 应用事件循环执行较长基准，直接编译生产播放/渲染源文件。它用合成样片记录首帧、CPU、内存、100 次实际进入播放的切换、独立缩放以及停止/销毁检查点。窗口可见性或帧提交不足会让报告失败。`PlaybackDiagnostics` 留在 MPV 适配目录，不扩大业务 `PlaybackEngine` 协议，也不与 `PlaybackSnapshot` 共用语义。原生属性只由控制队列读取，渲染统计只由渲染所有者加锁复制，再经主队列转换为 Swift 值。缺失属性保留未知；诊断不依赖文件路径、日志文案或 UI 轮询。

同一开发 target 的 `WindowLifecycleBenchmark` 直接编译并承载生产 `PlayerScreen`、`PlayerModel`、`PlaybackControls` 和 `VideoHostView`，没有另一套测试播放器 UI。一个 `NSWindow`、一个模型和一个引擎贯穿全部轮次。`single-window` 保持普通窗口，程序不再调整它的几何或显示模式，只提交暂停/恢复并检查新帧与资源。`display-transitions` 是另一个明确模式，才会执行缩放、迁移和全屏；全屏必须收到 `windowDidEnterFullScreen` / `windowDidExitFullScreen` 确认，并校验目标屏和 backing scale。两个模式均经正式模型提交暂停与恢复，等待原生快照确认。窗口被遮挡时如实失败，不使用反复置前或抢焦点维持测量。

`coreCreationCount` 与 `renderContextCreationCount` 分别在对应资源成功创建时由原所有者递增，退出后保留累计值。`renderContextAlive` 与 `graphicsContextAlive` 分别核验 libmpv render context 和 Bomu 自有 CGL context，不能用前者代替后者。这些诊断字段用于证明窗口与控件重算期间没有重建播放会话，以及 shutdown 后两层渲染资源都已释放；不进入 UI 状态或播放器协议。组合模式逐轮落盘，异常或取消先等待模型释放资源，再写失败报告。固定几何的底层 CPU 基线与含 SwiftUI、全屏动画的组合负载分别记录，不直接混作性能前后对比。

窗口基准 schema 3 增加 `soakVisibility`。持续播放区间的首尾和检查点读取当前状态，区间内通过 `windowDidChangeOcclusionState` 记录 AppKit 可见性变化；恢复可见不会删除先前中断。记录只在该区间启用，成功、失败或取消都会结束记录并写入报告。SwiftUI 产品状态不持有测试可见性。schema 1/2 的历史记录仍只证明采样点可见，不能追认为已经记录了中间事件；AppKit 的可见状态也不等于整幅视频毫无遮挡或物理出光验证。

测试媒体的 SHA-256 校验集中在 `scripts/media_fixtures.py`，按块读取文件，兼容系统 Python 3.9。原生测试入口、Xcode 测试素材复制阶段、播放基准以及长素材生成器复用同一校验。缺失、被修改或合同不完整的素材明确失败，不依据 manifest 的存在推断内容有效，也不自动覆盖被修改的媒体。

首帧计数排除重复帧和旧帧重绘，时间戳记录在 OpenGL 命令提交后。两个队列间的采集不是原子操作，适用于稳定检查点；测试不会据此声称物理显示、音频首声或 GPU 功耗已验收。完整口径见 [benchmark.md](benchmark.md)。

时序诊断比较 `glFlush` 后的 mpv 时钟与当前帧目标，并记录总数、均值、极值和提前超过 2 ms 的计数。固定 0.41.0 实现返回的目标为纳秒，与其头文件的旧微秒注释不一致；适配层按已核验实现使用 `mpv_get_time_ns`，再统一单位，不做数值猜测。版本依据、交错状态复现及同步素材口径见 [审查跟进](review-follow-up.md)。

后续 v0.1 在现有边界中引入轨道、队列和权限生命周期；数据库由独立持久化职责拥有。继续采用单一事实源和明确失败语义，不从 UI 直接读写 mpv，也不添加按文件名、编码样本或报错文案匹配的特例。

## 参考依据

- [mpv v0.41.0 定位队列](https://github.com/mpv-player/mpv/blob/v0.41.0/player/playloop.c#L386)：待执行相对定位合并，以及解码期间沿用上一定位目标。
- [Apple NSWindowDelegate 遮挡回调](https://developer.apple.com/documentation/appkit/nswindowdelegate/windowdidchangeocclusionstate(_:))：窗口可见性变化的原生通知入口。
- [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/)：以调用处可读性和清晰命名为先。
- [Swift Sendable](https://docs.swift.org/latest/documentation/swift/sendable/)：值类型跨并发边界，显式隔离可变状态。
- [mpv v0.41.0 render API](https://github.com/mpv-player/mpv/blob/v0.41.0/include/mpv/render.h)：线程、current context、advanced control 和销毁顺序合同。
- [Apple CAOpenGLLayer](https://developer.apple.com/documentation/quartzcore/caopengllayer)：CGL 复制回调返回 Core Animation 所需的像素格式与上下文对象；OpenGL API 已弃用，当前只用于已锁定的 SDR 验证路径。
- [IINA](https://github.com/iina/iina)：研究成熟 macOS 播放器的视频宿主和内核边界；未复制其应用实现。
- 用户提供的 CreatOK 工程规范：采纳稳定职责、窄契约、单一事实源、根因修复、交付链路文档；不照搬静态 Service、REST 或 Next.js 分层。
