# 2026-10-24 规范 Debug 包可见验收

本记录只覆盖本次实际执行的操作。规划与剩余门槛见 [v0.0 验收 Todo](v0.0-acceptance-todo.md)，当前工程状态见 [进度](progress.md)。

## 构建与窗口

- 规范包：`.build/DerivedData/Build/Products/Debug/Bomu.app`，版本 `0.0.1 (2)`，只打包英文界面。启动前 `scripts/build_identity.py verify` 通过；源码摘要 `1d94de7334b2e031fa4198599aa8cf64a329c7f60c0df19608eadc859d4a8399`，包摘要 `e2c18fc4c70c07404ca3c87880f32bfeb1ea44df025677cd2baab8be3331dc08`。
- 已确认屏幕解锁。经用户明确授权，先退出该路径下早于当前构建的旧进程，再从规范包启动一个普通窗口；本轮可见操作结束后退出本轮进程。未开第二个播放器窗口，未主动换屏、切换桌面空间或进入全屏。
- 可见窗口约 `1512×884 pt`；它不在三种标准验收尺寸中，下面的观察不能关闭三尺寸门槛。没有逐像素测量或持续滚动采样。

## UI 和真实播放观察

- Library：分类与观看状态分开筛选；`Watched` 只显示已看完的同步样片；List 行有独立播放、收藏和更多操作；按名称排序后文件名呈自然顺序。选择无媒体的 Movies 分类出现明确空态，`Clear Filters` 恢复完整列表。最后恢复 `Recently Added` 与 Grid。Search 输入 `29-sync` 后只显示匹配项。
- `⌘,` 从 Library 进入同窗口 Settings；Appearance 与 Storage 可见，Storage 具备清除观看历史、私有文件夹及媒体库数据导出/导入/清除入口。点击导入按钮后，绑定主窗口的辅助功能树与截图没有呈现系统文件选择面板；无法判断是独立面板未被工具捕获还是入口失效，**导入交互未通过验收**。按 Escape 后可返回 Library，未留下可见弹窗。
- 播放 `15-hevc-main10-4k.mp4`：同窗口播放器出现 Pause、进度与结束状态；重播时截图捕获到实际彩条与动态图案，证明画面路径在该样本工作。该观察不证明物理扬声器声音、校准 SDR 色彩、音画延迟或完整 A04 矩阵。
- 播放 `29-sync.mov`：同窗口进度从头推进，完成后显示结束/重播。一次截图为黑底；素材清单说明该样本本来是黑底、每两秒短暂白闪与 PCM 脉冲，因此单张黑帧不是黑屏故障证据，也不能证明显示端声画同步。

## 单窗口基准与原生测试

- 本地许可媒体、同步与单窗口样本哈希预检通过。`BomuBenchmark` 编译通过；执行 `BOMU_BENCHMARK_CYCLES=1 BOMU_BENCHMARK_SOAK_SECONDS=0 BOMU_BENCHMARK_MINIMIZE_RESTORE_PROBE=0 ./scripts/benchmark-dev.sh --media-suite`。首轮原始报告在 `.build/benchmarks/20261024-113104/window-lifecycle.json`。01–18 的媒体检查通过；19 的窗口在检查期间从外接屏 ID 3 转到内屏 ID 1，因显示器约束失败；20 的播放检查通过，但整轮因显示器与首项不一致而中止。没有执行 21–30、后续生命周期循环或 soak，**这一轮不能算 A04 30/30**。报告记录同一窗口号、一个 native core 与一个 render context；退出时 `coreAlive`、`renderContextAlive` 和 `graphicsContextAlive` 均为 false。基准代码在媒体套件路径中没有主动迁移窗口；换屏原因待查，不以猜测归因。随后成功的独立复跑见文末。
- `./scripts/test-dev.sh --native -quiet` 完成；同次 Python 检查 154 项通过。`Test-Bomu-2026.10.24_11-32-11-+0800.xcresult` 摘要为原生 XCTest 12 项通过、0 失败、0 跳过，随后确认应用宿主退出。它验证代码路径和测试窗口行为，不代替用户可听声音、校准色彩或睡醒验收。
- 因本次意外换屏，基准报告新增每个样本结束时的显示器 ID，并在换屏后立即停止后续样本。`./scripts/build-dev.sh --benchmark -quiet` 编译通过；这一诊断改动发生在上述失败报告之后，不改变那次报告的结果，后续复跑见文末。
- 诊断代码改变了构建身份输入，随后执行 `./scripts/build-dev.sh -quiet` 并重新 `verify`。**当前**规范 Debug 包源码摘要为 `d0c5a22bfff2bb7e35d87fe0e228960cf263653054b123c455ec0247f7d59ce1`；上面的 UI 截图与播放观察属于改动前已核验的包，不自动转算为新收据的可见验收。

## 新收据下的同屏尺寸抽查

重建后只从当前规范包重启一个普通窗口，在当前屏幕内拖动右下角，没有跨屏或全屏。截图尺寸按屏幕 2× backing scale 换算：

- 约 `963×643 pt`（截图 `1926×1286 px`）：Home 的标题与两个继续观看卡片无明显截断；Library 的五个分类、观看状态、排序、Grid/List 控件和三列媒体封面均可见。Settings 的 Appearance 分区可读；Storage 底部操作起初不在视口，向下滚动后 Import、Clear 和说明均可见。该窗口比标准 `960×640 pt` 各大约 3 pt，故只记近似检查。
- `1280×800 pt`（截图 `2560×1600 px`）：Library 三列网格可见；切换 List 后，行内独立播放、收藏与更多操作均保留，文字和元数据没有明显交叠。Storage 的全部操作在当前视口可见。结束前恢复 Grid 和原窗口大小并退出本轮进程。
- 当前内屏可见高度约 `884 pt`，无法在不改变屏幕或让窗口越界的条件下准确检查 `1440×900 pt`；该尺寸保持未验收。上述为布局/可达性的抽查，未做设计稿逐像素差异测量、完整命中区、连续滚动或 VoiceOver 验收。

Library 的真实文件还暴露音频编码原始 FourCC `.mp3`、`lpcm` 直接进入技术标签。现将这两个已知值显示为 `MP3`、`PCM`，未知值仍保持原样；`./scripts/test-dev.sh --direct-hostless` 通过 202 项 XCTest（2 项存储专项按默认入口跳过、0 失败）和 154 项 Python 检查。再次 `./scripts/build-dev.sh -quiet` 后，**最新**规范 Debug 包源码摘要为 `b5177bcdb4ea54c6643dafe12e50580a035a764077db6a3cc7808f0755662303`，身份核验通过。只在一个新包窗口打开 Library，辅助功能描述分别显示 `MP3` 与 `PCM`，之后退出本轮进程。此前 A04 报告和尺寸抽查属于其各自记录的构建，不因该标签改动自动更新结果。

在该最新包又做一次同窗口导航检查：Library 中播放 `04-high-1080p60.mp4`，重播后立即暂停于约 `0.15 s`；按 `⌘,` 进入 Settings，仍可见 `Now Playing 04-high-1080p60` 与 `Show Player`。点击后回到播放器，位置仍约 `0.15 s` 且保持暂停，再返回 Settings 并退出。这验证本次设置往返保留同一可见会话状态；未测长时间后台负载或实际扬声器输出。

## 播放期间 Library 短时负载观察

在同一规范包单窗口中，从 Search 重播本地 `29-sync.mov`（30 秒、黑底闪光/PCM 脉冲），播放到约 5 秒时返回 Library；底部 `Now Playing` 保持 Pause 操作，表示播放仍在进行。滚动两页后，新进入视口的已支持 H.264/H.265、AAC/PCM/MP3 卡片显示真实缩略图与属性；不受 AVFoundation 支持的 MKV 仍明确显示 Unknown，没有伪造属性。结束后再看该位置，未见卡片持续显示加载占位。

同轮以 `/bin/ps` 每约 0.5 秒采集 45 秒、90 个样本，原始数据在忽略目录 `.build/benchmarks/20261024-library-playback-sample.tsv`。整个混合窗口的 `%CPU` 平均约 31.9、峰值 72.8；RSS 峰值约 179.1 MiB、末值约 118.5 MiB。采样**没有精确的阶段时间戳**，混合了启动、播放、Library 滚动和播放结束，不能据此计算播放相对空闲的增量、滚动帧率或节能收益；也未记录 AVFoundation 活跃工作数。这只是当前样本下没有明显持续增长或长期加载的探索性证据，播放期间后台负载门槛仍开放。

首轮换屏原因仍待查；同屏 A04 复跑与设置页文件选择入口复核结果见下文。Welcome 空库、标准尺寸、后台工作并发数/滚动帧率、辅助功能、真实声音与睡醒仍按 Todo 保持开放。

## Storage 文件选择入口修复

在上述同一版 Settings 中再次验证：点击 `Import Media Library Data` 与 `Do Not Remember a Folder` 均未弹出面板；同窗口侧栏 `Add Folder` 可正常弹出系统选择面板，故确认是 Settings 两个入口的缺陷，而非桌面工具无法捕获面板。将 Settings 两处嵌套 SwiftUI `fileImporter` 改为附着在当前主窗口的原生 `NSOpenPanel` sheet，保留 JSON 文件与文件夹的类型约束，以及原有导入预览、私有目录处理流程。

执行 `./scripts/build-dev.sh -quiet` 并核验源码/包收据，随后 `./scripts/build-dev.sh --analyze -quiet` 通过。**当前规范 Debug 包**源码摘要为 `35b92e30426c24f32fbd0481d65c2d14b589e6a6c45757ccd40fb4c31de96ce0`，版本仍为 `0.0.1 (2)`，只含 `en.lproj`。在该包的一个普通窗口中，两个 Settings 按钮分别打开名为 `Open` 的系统 sheet；归档入口的面板只允许 JSON，私有目录入口只允许目录。均通过 Cancel 关闭，未导入归档或修改私有目录，随后退出本轮应用进程。因此仅签收**面板打开与取消**；归档读取/预览/应用、私有目录实际保存仍需独立验收。此前 A04 与其他 UI 观察的构建身份不变。

同一构建又用忽略目录 `.build/acceptance/` 下的合成零文件 v2 归档验证**读取与预览**：选择 JSON 后出现确认 sheet，明确显示匹配 0、跳过 0、将替换 0 项；按 Cancel 返回 Storage。再选字段缺失的 JSON，Storage 显示归档无效错误；重新点击 Import 并选择有效归档，确认 sheet 再次出现，先前错误已清除。两次确认均取消，未按 `Import Matched Records`，也未修改现有库。此项仅覆盖零文件归档的预览/错误恢复；非空真实匹配、应用结果与私有目录写入仍开放。

## 同进程阶段负载对照

在当前规范包的一个普通窗口、同一屏幕和同一进程中，先固定 Library 首屏，再从本地已许可样片重播。长时素材 `.build/sync-soak-fixture/av-sync-33-minute.mp4` 的清单说明它由 Bomu 自生成 CC0 闪光/脉冲样片重复而成；本轮 SHA-256 与清单中的 `9f9e1549a552e331613256b1f839f2e73aa55bcff08a4a98f5cd8b0507ab31e4` 一致。直接打开时该文件有接近结尾的既存进度，因此使用 `Play Again` 从头播放，再返回原 Library 首屏。播放期间底栏持续显示 `Now Playing` / `Pause`；20 秒采样后切到播放器页，另采 20 秒，末尾仍显示 Pause 与约 95 秒的进度。退出本轮应用后，应用清单不再显示 Bomu 进程。

原始 `/bin/ps` 阶段样本在忽略目录 `.build/benchmarks/20261024-phase-load.tsv`，以同一 PID 每约 0.5 秒采集，数值为进程 `%CPU` 与 RSS：

| 阶段 | 样本 | CPU 均值 / 中位数 / 峰值 | RSS 首 / 末 / 峰值 |
| --- | ---: | --- | --- |
| Library 首屏空闲 | 24 | 0.4% / 0.0% / 7.9% | 82.2 / 57.0 / 103.7 MiB |
| 30 秒样片播放并显示 Library | 24 | 22.3% / 21.7% / 49.4% | 106.4 / 108.8 / 110.0 MiB |
| 33 分钟样片播放并显示 Library | 40 | 43.7% / 44.0% / 52.1% | 105.1 / 103.1 / 126.4 MiB |
| 同一长时播放会话显示 Player | 40 | 43.4% / 43.7% / 47.4% | 102.6 / 100.1 / 103.1 MiB |

30 秒样片阶段可能包含结束边界，只保留为探索样本。长时样片的 Library 与 Player CPU 均值接近，短窗 RSS 无持续增长；但两阶段先后采样且媒体库卡片已缓存，不能据此推出 UI 开销仅 0.3 个百分点，也不能证明新卡片加载并发上限、滚动帧率、音画稳定性或长期无泄漏。后续用带任务计数的观测与连续滚动/Instruments 关闭性能门槛；本轮仅说明这个真实播放负载下没有明显持续内存上涨或资料库页 CPU 异常增量。

## 当前工具链 A04 单窗口复跑

在规范 Debug 应用和前述采样进程均退出后，执行 `BOMU_BENCHMARK_CYCLES=1 BOMU_BENCHMARK_SOAK_SECONDS=0 BOMU_BENCHMARK_MINIMIZE_RESTORE_PROBE=0 ./scripts/benchmark-dev.sh --media-suite`。Xcode 27.1 / Swift 6.4 下编译并完成；报告位于 `.build/benchmarks/20261024-115559/window-lifecycle.json`，来源、工具链和素材清单同目录。30 个许可样本全部按预期通过（其中无效/截断文件按预期拒绝并恢复），每项开始与结束显示器 ID 均为 3，同一普通窗口未由驱动迁移或进入全屏。一次周期内 core/render context 创建数均为 1；暂停/恢复后得到新视频帧。完成时 core、render context、graphics context 均为 false，测试进程退出。规范 Bomu Debug 包身份随后再次核验通过，源码摘要仍为 `35b92e30426c24f32fbd0481d65c2d14b589e6a6c45757ccd40fb4c31de96ce0`。

这关闭了**当前工具链 A04 的 30 样本单窗口复跑**，不改变先前第 19 项换屏失败的原始记录，原因仍未知。该次显式关闭 minimize/restore，soak 为 0；音频静音，只核对解码属性与输出活动，不能视为用户可听声音、物理音画同步、校准色彩、睡醒或长期资源稳定验收。

## 快速替换与停止路径

执行 `BOMU_BENCHMARK_CYCLES=1 BOMU_BENCHMARK_SOAK_SECONDS=0 BOMU_BENCHMARK_MINIMIZE_RESTORE_PROBE=0 ./scripts/benchmark-dev.sh --replacement-burst`。第一次原生报告 `.build/benchmarks/20261024-115814/window-lifecycle.json` 已显示 `completed=true`：12 次待处理打开取消、停止后保持空闲、24 次连续替换、最终 MPEG-TS 请求播放、暂停定位恢复与继续播放都通过；core/render context 仅创建一次，退出均为 false。但命令最终退出 1，因为 `scripts/summarize-replacement-burst.py` 仍要求旧报告 schema 4，而当前基准写 schema 9。修正汇总器的精确版本检查后，对第一次报告复核通过，随后完整命令重跑通过；最终报告在 `.build/benchmarks/20261024-115856/window-lifecycle.json`，测试进程退出。

该基准为静音的生产 PlayerModel/PlayerScreen 路径，支持快速切文件、取消与停止后的状态/资源边界判断；它不证明用户可听声音、物理画面同步或长期 soak。修正验收脚本后重建规范 Debug 包并核验身份，**最新源码摘要**为 `acf33395c36645a747ce0e26865421fe80318ea8d8dac4be35b979cfc1d81ccc`。本节之前的可见 UI 观察来自各自已记录的包，不能自动当作新收据的 UI 复验。

## 最新收据的精确双尺寸复核

从上述最新、已核验的规范 Debug 包仅启动一个普通窗口，在当前屏幕内将截图尺寸分别调至 `1920×1280 px` 和 `2560×1600 px`（2× backing scale，即精确 `960×640 pt` 与 `1280×800 pt`）。没有换屏、切换桌面空间或进入全屏；结束时恢复 Library 的 Grid 布局并退出本轮进程，应用清单确认进程消失。

- `960×640 pt`：Home 的标题、继续观看卡片与最近添加标题可见。Library 三列网格与分类、观看状态、排序和布局切换控件可见；切至 List 后，行内播放、收藏和更多操作独立呈现，文件名及元数据无明显重叠。Movie 分类没有匹配项时显示专用空态与 `Clear Filters`；点击后恢复列表。Settings 的 Appearance 文案可读；Storage 的三个数据操作初始有部分位于视口下方，滚动到底后导出、导入、清除按钮及说明均可见。
- `1280×800 pt`：Home 两张继续观看封面及最近添加区域可见；Settings / Storage 的三个数据操作和说明可见；Library 的 List 行内操作与元数据无明显重叠。切回 Grid 时辅助功能树确认其选中。

这些是最新包的可见布局与可达性抽查，不等于视觉稿逐像素还原、完整点击热区、连续滚动/闪烁、VoiceOver 或状态矩阵验收。`1440×900 pt` 仍需获准在另一显示器上测量；当前屏幕可见高度不足以完整容纳该尺寸。

## 最新包的文件夹、搜索与设置状态

再次核验当前规范包身份后，只从该包启动一个普通窗口，同屏操作并于结束时退出，应用清单确认 Bomu 进程消失。本轮没有改动分类、收藏、播放偏好、私有目录或数据库记录。

- `1280×800 pt`：Folders 展示在线 `media-suite` 和离线 `fixtures` 两个真实来源。进入在线来源，网格与列表均显示文件名、已探测属性和独立的播放/收藏/更多操作；切回 Grid。Search 初始提示、无匹配查询的 `0 videos` 和空态、Clear search 返回初始状态都可见；查询 `08-` 找到真实中文文件名，更多操作及 Set Category 子菜单可展开，未选择会改动记录的菜单项。
- `960×640 pt`：Search 的单项结果、中文文件名、封面与元数据未明显重叠。进入离线 `fixtures`，原有条目仍在，卡片显式标记 Offline，未显示已失效的播放按钮；点击卡片只选中该项，没有进入播放器。这证明当前可见行为，未模拟拔盘/重新挂载。
- 同尺寸 Settings：Playback 的两个开关和默认速度、Subtitles 的偏移滑杆、About 的实际版本 `0.0.1 (2)` 与禁用的更新按钮均可见。Appearance 和 Storage 见上节；本轮只查看，没有更改设置值。退出前将窗口恢复为 `1280×800 pt`。

空库 Welcome 仍缺规范包可见验收。当前应用存储使用用户真实 Application Support 路径；不能为制造空库而清除或挪动现有库。逻辑回归已覆盖设置路由，但不能替代 Welcome 的布局与面板行为。完整键盘访问、第三尺寸和实际睡醒依旧按清单单独验收。

## 当前包的 Library 时长排序

Library 增加 Duration 排序后重新构建规范 Debug 包，启动前 `scripts/build_identity.py verify` 通过；源码摘要为 `6452a93d952d52f7e6828b2f793ba036870779817b42454646b080ad93f5ce5f`，版本仍为 `0.0.1 (2)`，只含英文界面。本次只启动一个普通窗口，没有主动换屏、切换桌面空间或进入全屏。Library 排序菜单显示 Duration；选择后，30 项许可样本中能读出时长的 5 秒、6 秒、30 秒条目按升序出现，离线、无效及无法探测时长的条目位于末尾，页面明确说明未知时长靠后。随后同一包、同一屏幕缩至精确 `960×640 pt`（截图 `1920×1280 px`），可见分类、排序、布局按钮，前三张卡片时长依次为 `0:05`、`0:05`、`0:06`，状态文案与卡片未见明显重叠。结束前恢复 Recently Added 与原窗口尺寸，并确认该进程退出。

同一源码的无宿主回归为 154 项 Python、205 项 XCTest（2 项显式 APFS 存储测试按默认入口跳过），0 失败；Debug 构建与 Xcode 静态分析通过。可见检查只覆盖当前样本与窗口交互，不证明 10,000 项首次完整探测耗时、连续滚动帧率、三尺寸布局或真实播放时并发排序的性能。A04、快速替换及前文其他 UI 证据分别属于当时的构建，未在这次重跑。

## 当前包的 Library 双尺寸筛选与名称排序

再次核验同一规范 Debug 包身份后，从已退出状态启动一个普通窗口，先在精确 `1280×800 pt` 下操作 Library。选择 Name 后，已许可样本从 `01-`、`02-`、`03-` 等按自然文件名升序出现；选择 Watched 后只留下真实已看完的 `29-sync.mov`。保持 Name/Watched 并点 Movie，出现“No media matches these filters”及 Clear Filters；点击清除后分类与观看状态均回到 All，Name 排序保持不变，完整列表恢复。没有改写媒体偏好或库记录。

同一窗口在当前屏幕内缩至精确 `960×640 pt`（截图 `1920×1280 px`），Name 下首行 `01-`、`02-`、`03-` 的三列封面、元数据与排序/布局控件可见且没有明显交叠。该尺寸下再次从菜单选 Watched，只显示 `29-sync.mov`，分类和排序控件仍可达。结束前把筛选恢复 All、排序恢复 Recently Added、窗口恢复 `1280×800 pt` 并退出；应用清单随后确认该进程消失。全程未主动换屏、全屏或更改系统键盘设置。

这补充两个尺寸下的有限菜单与状态组合；仍未完成每个控件全区域命中、连续滚动、键盘/VoiceOver、第三尺寸或全页面状态矩阵。

## 当前包的 Settings 双尺寸五分区

同一源码摘要的规范 Debug 包再次通过启动前身份核验；仅启动一个普通窗口。精确 `1280×800 pt` 下以 `⌘,` 从 Home 进入 Settings，依次查看 Appearance、Playback、Subtitles、Storage、About：外观说明、续播/自动下一项与 `1×` 默认倍速、字幕偏移滑杆、Storage 的历史清理/私有文件夹/导出/导入/清库入口和关于页 `0.0.1 (2)` 版本及禁用更新按钮均在当前视口可见。

同屏缩至精确 `960×640 pt` 后，五个分区导航仍可见。About、Playback、Subtitles、Appearance 的当前文案与控件没有明显截断；Storage 首屏显示本地数据和私有文件夹，滚动一次到端点后导出、导入、清库和底部说明均可见。没有点击会修改偏好或记录的控件，现有字幕偏移 `1.0 seconds` 只读观察。结束前回 Home、恢复 `1280×800 pt` 并退出本轮进程，应用清单确认进程消失。未改系统键盘设置，也没有换屏或全屏。

这证明当前有媒体库状态下两尺寸的分区导航和滚动可达性；不证明空库 Welcome 路由、完整按钮命中、键盘/VoiceOver、第三尺寸或存储操作的实际应用结果。

## Library 滚动的 Instruments 短时采样

对源码摘要 `6452a93d952d52f7e6828b2f793ba036870779817b42454646b080ad93f5ce5f` 的规范 Debug 包，单窗口同屏打开 30 项样本 Library，使用 Xcode 27.1 的 **Animation Hitches** 附加进程录制 25.97 秒，并在录制期间上下滚动。结束后从该窗口退出，应用清单确认 Bomu 进程消失。该样本卡片此前已加载过，且录制时没有视频播放。

导出的 `potential-hangs` 表记录主线程 14 次超过 33 ms 的潜在交互延迟，其中 2 次标为 Brief Unresponsiveness，时长分别为 122.38 ms 和 116.97 ms；另外 12 次为 Potential Interaction Delay，范围 35.94–56.81 ms。`hitches-updates` 表按开始时间与时长去重后，有 6 次画面更新间隔超过 33 ms，最长 141.63 ms。短时 Time Profiler 样本多落在 SwiftUI ViewGraph / DisplayList 的主线程渲染链路，但不能从这些样本可靠地定位到某一行 Bomu 代码，也不能判定具体延迟与每次滚动手势的一一对应关系。

因此本轮**发现性能缺口，未签收滚动流畅**。下一步应在固定脚本化滚动与同时播放/新卡片加载条件下重采样，记录交互时间戳、帧时长分布和缩略图/属性任务并发数，再依据堆栈定位热点。代码检查发现 `MediaLibraryThumbnail` 的视图计算直接调用 `NSImage(contentsOf:)`，卡片还有独立的缩略图与属性状态任务；这两处值得测量，当前 trace 尚不能证明它们是上述延迟的原因。原始 trace 会包含被附加进程的环境变量；只保留上述脱敏汇总，不将原始 trace 或其目录导出纳入仓库。

## 滚动缺口后的后台解码修正（待可见复测）

将 `NSImage(contentsOf:)` 从 SwiftUI 视图计算移除。卡片/列表已有的异步任务先经原有缩略图缓存取得 URL，再在后台用 ImageIO 提前解码，向视图提交不可变 `CGImage`；取消或展示键变化时不提交旧结果，离开视口清除卡片持有的图像。解码与抽帧、属性探测使用同一 `AsyncPermitPool`，播放阶段仍最多 1 项、非播放阶段最多 2 项后台媒体工作。

该轮规范 Debug 包源码摘要为 `157e202a3e0f6a752d4208616fb5bc83962250a25a38e9b78bb7372163b2e775`，版本 `0.0.1 (2)`，只包含 `en.lproj`；构建身份核验、Xcode 静态分析、156 项 Python 和 206 项无宿主 XCTest 通过（2 项显式存储专项按默认入口跳过）。新测试以真实 JPEG 验证解码尺寸、无效图像、等待共享许可时取消及许可释放。构建后桌面已锁定，**未启动该包做 Grid/List 缩略图、视觉或滚动复测**。上一节的延迟数据属于修正前源码；本次代码和逻辑测试不能证明延迟已消失。

## 最新 Debug 包的隔离 Welcome 与 Library 复核

后续脚本和首次加载路由调整后的规范 Debug 包源码摘要为 `345f0551f9a389cfde95506092375905c132278619523f5a70bf027fe5e9da8f`，身份核验通过，版本 `0.0.1 (2)`，只包含 `en.lproj`。桌面解锁后，用带标记的临时目录启动唯一普通窗口；该目录实际生成独立 SQLite、WAL 和 SHM，界面显示空库 Welcome，确认未打开现有用户库。Welcome 的 Settings 进入同窗口 Settings，Home 返回 Welcome；Restore from Backup 进入 Storage，Import Media Library Data 打开系统文件面板，取消后仍在 Storage。Open Video… 和 Add Folder 分别打开文件与目录选择面板，取消后回到 Welcome。`⌘,` 后界面到达 Settings / Storage，但自动化在焦点变化时报状态改变，保留快捷键复核项；应用菜单 Settings… 的元素点击失效，未计通过。未选择或导入任何文件。退出后临时库与启动环境变量均已清理；详见[隔离入口记录](../quality-hardening/isolated-welcome.md)。

随后从同一已核验包的绝对路径启动常规资料库的唯一窗口。Library Grid 中真实视频缩略图、音频占位和无效/离线占位均随滚动呈现；List 行提供独立播放、收藏和更多操作，离线行显示 Offline 且无播放操作。上下滚动后未观察到持续停在加载占位的卡片，当前窗口截图未见明显交叠。这是一次有限的可见抽查，不是逐像素比对，也没有证明首次大库加载、三个精确尺寸、长时间滚动帧率或播放中的后台预算。上一节修正前的 Instruments 延迟数据不能直接套用到本包。

## 最新包的滚动采样与 A07 尝试边界

对上述单窗口附加 Xcode Animation Hitches 录制并上下滚动，25 秒时间限制后 xctrace 长时间停在写出阶段；停止后进程以 137 退出，导出潜在卡顿表又触发 `SIGABRT`。因此**本轮没有可用的脱敏性能汇总**，不把滚动流畅度判为通过。已删除这次包含进程环境的未完成原始 trace，未写入仓库。短时可见抽查和前一包的 14 次潜在交互延迟分别按各自证据保留。

这次失败还暴露汇总脚本只在成功导出后清理原始 trace 的隐私缺口；现已让 `--remove-trace` 在导出失败时也清理经路径限制的 trace，并以失败导出的行为测试验证。该脚本修正不制造性能通过结果。

A07 普通窗口缩放尝试及每次失败报告见[专项记录](../../playback/native-poc/ordinary-resize-benchmark.md#当前验证)。最初的启动屏幕基线、低于生产最小高度的目标尺寸已修正；随后一次在第 1 轮后检测到显示器变化，最后一次在前台 key window 未激活时退出。均未完成 100 轮，不能签收 A07。修正后的当前源码摘要为 `22f96470841b82d26e7cf77695c9a0fb119ec8090ed8b2d28fd3a56a1d4699c4`，规范 Debug 构建与 Xcode 静态分析通过；本节前面的 Welcome/Library 可见观察属于摘要 `345f0551f9a389cfde95506092375905c132278619523f5a70bf027fe5e9da8f` 的包。两次摘要之间仅调整了开发基准宿主、报告校验、失败 trace 清理和文档，产品 UI 源码没有变化，但不把旧包的可见观察自动重记到新收据。

## 当前收据的隔离空库三尺寸复核

规范 Debug 包摘要 `22f96470841b82d26e7cf77695c9a0fb119ec8090ed8b2d28fd3a56a1d4699c4` 经启动前身份核验，从带标记的临时库路径启动唯一普通窗口。Welcome 确实为空库；同屏调整窗口后，截图尺寸依次为 `2560×1600`、`1920×1280`、`2880×1800 px`，在 2× backing scale 下对应精确 `1280×800`、`960×640`、`1440×900 pt`。三尺寸中欢迎标题、说明、Open Video…、Add Folder、Settings、Restore from Backup… 与底部离线说明均可见，截图未见文字或控件交叠。仅调整该窗口尺寸，没有主动跨屏、进入全屏或切换桌面空间；本轮未采集显示器 ID。

在 `1440×900 pt` 由 Welcome 的 Settings 链接进入同一窗口设置，Appearance、Playback、Subtitles、Storage、About 五分区均可导航并显示对应内容；`960×640 pt` 的 About 内容可见，Storage 的本地数据和私有文件夹位于首屏，滚动一次后导出、导入、清库和底部说明可见；`1280×800 pt` 的 Storage 全部操作位于首屏。没有修改任何偏好或库记录。从 Welcome 按 `⌘,` 后，AX 明确显示 Settings / Storage，因此快捷键入口本轮通过。应用菜单显示 Settings… 项，但桌面工具对菜单项的点击持续返回元素失效，键盘选择没有形成可见跳转，故菜单点击仍未签收。

本轮没有操作真实文件/归档，退出后临时库目录和启动变量均回读为已清理。三尺寸检查为可见布局与有限导航抽查，尚未按 UI 设计稿逐像素比对、验证各按钮全区域命中、VoiceOver 或非空备份应用。

## 当前收据的 Library 第三尺寸抽查

隔离空库会话完全清理后，再核验同一规范 Debug 包身份，从绝对路径启动常规资料库的唯一窗口。窗口截图精确 `2880×1800 px`（2× backing scale，即 `1440×900 pt`）。Grid 三列中真实视频缩略图、音频和未知媒体占位、元数据槽位、筛选与布局控件可见，当前视口未见交叠；切换 List 后，每行的 Play、Add to Favorites、More actions 在 AX 中保持独立，截图中行高和元数据对齐。

在 List 下选 Movie 出现居中的无结果说明和 Clear Filters，点击后恢复完整列表；观看状态选 Watched 后仅显示现有 `29-sync.mov`，恢复 All 后完整列表返回。Sort 菜单切到 Duration，列表显示未知时长置后说明并重排样片；切到 Name 后按文件名重排，最后恢复 Recently Added 与 Grid。窗口恢复 `1280×800 pt` 后退出，本轮进程消失。没有修改用户偏好、分类、收藏或资料库事实。

这补齐第三尺寸下的部分 Library 可见交互，不等于所有筛选/排序组合、逐控件完整命中区域、大库首次探测性能或播放期间滚动帧率验收。

## 隔离非空归档的清库恢复链路

在同一规范 Debug 包（摘要 `22f96470841b82d26e7cf77695c9a0fb119ec8090ed8b2d28fd3a56a1d4699c4`）的带标记临时库中，用 Welcome 的 Add Folder 选择已许可的 `.build/media-suite`，实际索引 1 个来源、30 个文件。Library List 的首项通过独立心形按钮加入收藏，AX 变为 Remove from Favorites。Settings / Storage 导出 `.build/acceptance/Bomu-isolated-2026-10-24.json`；只读检查确认 v2 JSON 有 1 个来源、30 个文件、1 项收藏。

随后仅清空该隔离库，SQLite 的来源、文件、关联与偏好计数均归零。第一次从 UI 导入同一归档时，确认预览为匹配 0、跳过 30，应用结果同样为导入 0、跳过 30；来源恢复后自动扫描，SQLite 重新出现 1 个来源、30 个文件，但收藏尚未恢复。第二次导入预览变为匹配 30、跳过 0；应用后偏好 30 项中有 1 项收藏，Favorites 页面显示原首项。这是当前“先匹配本机索引、再写入记录”的既定合同，不是一次导入即完整恢复。已针对跳过项补充本地化的扫描后重试指引，并把两阶段行为纳入回归；新文案的构建与可见复核另行记载。

本轮只有一个普通窗口，未主动换屏或进入全屏。结束时该进程退出，临时库目录和 `BOMU_ACCEPTANCE_LIBRARY_DIRECTORY` 均回读为已清理；真实用户库未清空。此处证明当前包的归档内容、两次 UI 导入及恢复结果，不证明首轮导入会自动重试、跨设备卷身份匹配或恢复超大库的耗时。

导入提示修正后的规范 Debug 包摘要为 `c6d44ee94f52e430b434142049a5dcc29e1b84d060960538ff47fe45815e2c6a`，构建身份核验通过。再次从隔离空库 Welcome 的 Restore from Backup… 进入 Storage，选择上一轮非空归档；确认 sheet 的 AX 与截图均显示匹配 0、跳过 30 以及“等待恢复的来源扫描完成后再次导入”的完整英文指引，未见截断。执行首次导入后，Storage 状态文案也显示同一指引。此轮只为核对新文案，未重复第二次导入；之后进程退出，第二个临时库目录和启动变量再次清理。与该源码对应的 160 项 Python、207 项无宿主 XCTest（2 项显式存储专项跳过）、Debug 构建及 Xcode 静态分析均通过。

## A07 当前源码的普通同屏缩放

同摘要的 `BomuBenchmark.app` 使用一个普通窗口与许可的 15 分钟静音样片，先在前台完整运行 100 次 `920×640` / `960×600 pt` 交替缩放、原生确认的暂停/恢复与新帧检查，再持续播放 120.1 秒。报告位于忽略目录 `.build/benchmarks/ordinary-resize-20261024-154931/`，原始 JSON `completed=true`，汇总器退出码 0。100 轮显示器 ID 均为内建屏幕 1，内核/渲染上下文各只创建一次；持续播放新增 3,595 帧，停止后没有新增帧、绘制或快照，退出时内核、渲染和图形上下文均已释放。该窗口退出、临时变量与样片清理已回读。详细数值与先前失败尝试见[专项记录](../../playback/native-poc/ordinary-resize-benchmark.md#当前规范包的成功收据)。这只关闭普通窗口同屏缩放子项，不覆盖全屏、跨屏、物理声画或手动拖拽流畅度。

同一源码另运行 `./scripts/test-dev.sh --direct-storage`：160 项 Python 先通过，随后临时 64 MiB APFS 稀疏映像中的重新挂载身份/历史与写满后保留已提交 checkpoint/恢复两项 XCTest 均通过（2/2，0 失败）。`hdiutil info` 回读未见 BomuStorageTest 挂载。此专项结果与默认无宿主回归里的两项显式跳过分开记录；没有把跳过视作通过。

## 当前规范包的真实声画与睡醒尝试

在已核验的规范 Debug 包（摘要 `c6d44ee94f52e430b434142049a5dcc29e1b84d060960538ff47fe45815e2c6a`）的隔离临时库中，从 Welcome 以同一个普通窗口打开 `.build/window-fixture/window-stress-1080p.mp4`。该样片是自生成 CC0、约 15 分钟的 H.264 图案和连续正弦测试音；截图显示实际彩条与运动图案，播放器进度从约 4 秒推进到 300 秒，前进 10 秒控件与音轨菜单可操作。用户在播放期间确认“声音和画面都正常”。这为该设备、该样片的可听与可见播放提供人工确认，不是校准色彩、逐帧同步或所有编码的验收。

随后在播放期间尝试受控睡醒。`pmset schedule wake` 因当前会话没有管理员权限而未设置自动唤醒；用户同意至少 30 秒后手动唤醒。`pmset sleepnow` 返回“Sleeping now…”，用户也报告曾从苹果菜单执行睡眠并唤醒，但两次之后 `pmset -g log` 均无 2026-10-24 的新 Sleep/Wake 记录（最近一组真实事件仍在 10 月 23 日），播放器位置按墙钟时间连续推进。`pmset -g assertions` 显示显示串流及音频等闲置睡眠阻止声明，但本轮不能据此确定阻止原因。**没有证据证明机器实际进入睡眠，睡醒恢复门槛保持开放**；没有为制造结果改动系统权限或关闭其他进程。

接着在同一窗口切换到 6 秒的 `.build/media-suite/14-hevc-main10.mp4`。第一次截图正好落在 Playback finished 页，不能用其黑色画面判断解码。用同一 CC0 样片、`ffmpeg -stream_loop 19 -map 0 -c copy -t 120` 在忽略目录生成约 120 秒的 `hevc-main10-loop-120s.mp4`，不重编码原始 HEVC Main10 视频和 AAC 音频。打开后播放器显示 Pause、真实彩条和运动图案，进度从约 5 秒持续推进到 95 秒，点击前进 10 秒后继续到结束页；用户确认能听到持续测试音。该观察关闭了这条样片的可见解码和实际出声疑点，尚无色彩测量或物理声画同步判定。结束后只退出本轮应用进程；应用清单不再显示 Bomu，隔离临时库目录与 `BOMU_ACCEPTANCE_LIBRARY_DIRECTORY` 均回读为已清理。

## 隔离库的私有目录添加与撤销

再次核验同一规范包身份，启动新的带标记临时库，Welcome 为空。Settings / Storage 的 `Do Not Remember a Folder` 在主窗口打开目录选择 sheet；选择该隔离库内部新建的 `Private-Test` 后，设置页出现目录名称和 `Allow History`，只读 SQLite 检查 `private_media_roots` 为 1 项。点击 `Allow History` 后该行消失，表内计数回到 0。退出本轮应用后清理整份临时库，启动变量回读为空。这个检查只验证设置页与存储记录的添加/撤销；未用真实媒体文件验证位置、轨道和音量不保存的端到端效果，也未触碰用户现有目录。

## 当前包的损坏文件恢复和暂停状态

在第三个隔离空库、同一普通窗口中，从 Welcome 选择许可套件的 `16-invalid.mp4`（41 字节）。Player 显示“This video could not be decoded”、原因说明，以及 Retry、Open Another Video…、Back to Library、Technical details；点击 Retry 后仍保持明确错误状态，没有假装播放。随后通过 Open Another Video… 选择许可的 `window-stress-1080p.mp4`，页面回到真实活动画面，Pause 控件和进度约 4.7 秒可见。点击 Pause 后控件变为 Play，位置固定在约 6.83 秒；稍后复核仍为同一位置，截图中画面与控件完整。点击 Play 后恢复到 Pause 控件，进度继续推进至约 11.9 秒。结束后退出本轮进程，隔离目录和启动变量均回读为已清理。这关闭了该坏文件到好文件的可见恢复、暂停与续播抽查；没有覆盖其它错误类型、连续切片竞态或精确音画同步。

## 原生内核的同路径替换与历史隔离

新增 `MPVIntegrationTests.testNativePlaybackRejectsCheckpointAfterAtomicFileReplacement`，复用唯一可见应用宿主窗口、真实 `MPVPlaybackEngine`、临时媒体与 `PlaybackHistoryStore`。先播放 H.264 到暂停的约 5 秒并保存旧文件 checkpoint；在 mpv 会话仍打开时，将路径原子替换成许可的 HEVC Main10 文件并重新索引。旧会话的下一次保存必须抛出 `mediaFileChanged`，新文件没有继承旧进度；随后以相同路径重新打开新文件，在约 2 秒暂停并退出，SQLite 只记录新会话自己的位置。测试还要求内核、渲染上下文和图形上下文均释放。

该用例单独重跑通过；完整 `./scripts/test-dev.sh --native -quiet` 的 XCTest 结果为 13/13、0 失败、0 跳过，同次 160 项 Python 检查通过，测试宿主退出。完整原生结果保留在忽略目录 `.build/DerivedData-Tests/Logs/Test/Test-Bomu-2026.10.24_16-16-30-+0800.xcresult`。测试只证明这条真实内核与存储调用链，不替代用户实际资料库的行为或物理声画判断。此次只新增测试源码，产品构建输入不变；规范 Debug 包重新构建和身份核验仍为 `c6d44ee94f52e430b434142049a5dcc29e1b84d060960538ff47fe45815e2c6a`。

## 当前包的 Library 滚动采样未完成

在同一规范 Debug 包的隔离空库中添加 30 项许可样本，于唯一普通窗口进入 Library Grid 并上下滚动。画面中的真实缩略图与占位仍正常呈现；这是短时可见抽查。尝试附加 Xcode 27.1 Animation Hitches，设置 12 秒时限，但 `xctrace record` 超过约 1 分 40 秒仍未结束，原始目录增长至约 4.8 GB，且仅有录制数据和问题存储、没有可导出的完成索引。本轮已结束自己启动的采样进程，并删除包含进程环境的未完成原始 trace；应用窗口退出，隔离库目录及启动环境变量均已回读为清理完成。

这次录制**没有可用的帧时长或主线程延迟数据**，不能证明后台解码修正后的滚动流畅度，也不能将修正前的 14 次延迟视为已消失。当前工具的两次写出失败提示需要先建立能受控完成、能脱敏导出的测量入口，再扩大到大库首次加载及播放期间滚动；短时截图不代替该门槛。

## 原生播放中的私有目录生效时机

新增 `MPVIntegrationTests.testNativePlaybackHonorsPrivateFolderRuleDuringActiveSession`，在唯一应用宿主窗口借用真实 mpv 视频表面。许可 H.264 文件先播放、暂停并在约 5 秒保存历史；不结束播放会话就将所在目录设为不记录历史，存储层立即删除原 checkpoint。随后该会话再次请求保存并退出，查询仍没有历史；内核、渲染及图形上下文均释放。使用临时目录和 SQLite，不触碰用户资料库。

单项原生结果 1/1，通过；完整 `./scripts/test-dev.sh --native -quiet` 同次 160 项 Python 与 14/14 项原生 XCTest 通过，0 失败、0 跳过。结果包位于忽略目录 `.build/DerivedData-Tests/Logs/Test/Test-Bomu-2026.10.24_16-24-00-+0800.xcresult`。这验证真实播放会话与排除规则的存储链路。产品构建输入未变，规范 Debug 包摘要仍为 `c6d44ee94f52e430b434142049a5dcc29e1b84d060960538ff47fe45815e2c6a`。

## 私有目录的设置页到真实播放

在同一已核验 Debug 包建立新的带标记隔离资料库，Welcome 显示空库。只在该临时库内创建 `Private-Media` 并复制许可的 H.264 小样片与约 15 分钟长样片；通过 Settings / Storage 的 `Do Not Remember a Folder` 系统面板选中此目录，设置页显示目录与 `Allow History`。随即用 `⌘O` 从该目录打开小样片，播放器显示真实视频进度；再打开长样片，约 8.6 秒暂停。此时只读 SQLite 查询为私有目录规则 1 条、媒体索引 2 条、`playback_history` 0 条。退出唯一普通窗口并确认应用进程消失后再次查询，规则仍为 1 条、历史仍为 0 条。结束时临时库、两份样片副本和启动变量均回读为已清理。

这完成当前包中“设置页写入私有规则→真实媒体播放/暂停→退出不保存播放历史”的端到端抽查，且没有修改用户现有库。规则显示的临时目录卷名为 `Unknown volume`，记录中的相对路径与隔离文件一致；因此此结论仅适用于这条本机临时目录与样片，不延伸到断连、跨卷或权限丢失场景。音轨和音量与位置存于同一历史记录；本轮未单独改变音轨/音量再验证其恢复表现。

## 后台许可竞态修正包的播放中资料库抽查

规范 Debug 包源码摘要 `ad6188f3bff3319552dc8bbd8a5b6ac1d65594a8fdd37dd392948764b9ca3ab2` 经身份核验，版本 `0.0.1 (2)`，只包含 `en.lproj`。以独立临时库启动唯一普通窗口，Welcome 为空；用 Add Folder 添加许可的 `.build/media-suite` 后，SQLite 中有 1 个来源、30 条来源关联、30 个媒体文件。Library Grid 的真实 H.264/HEVC 缩略图、音频和无法探测样本的占位可见；List 行的 Play、Favorite、More actions 在辅助功能树中为独立操作。随后在同窗口打开许可的 15 分钟 H.264 样片，播放器进度推进至约 10 秒；返回 Library 时 Now Playing 仍显示播放，List 向下滚动两页后，新出现行的缩略图、技术属性或 `Unknown` 占位均有结果，截图未见明显交叠。点击 Now Playing 的 Pause 后按钮变为 Play。退出本轮进程，隔离库与启动变量均回读为清理完成。

这只是播放期间的一次有限可见抽查；没有计量后台任务数、CPU、帧率、主线程延迟或音画同步，不能据此关闭性能和完整 UI 门槛。

## 最新包的 FLAC 标签可见复核

音频技术标签展示边界将 AVFoundation 返回的 `flac` / `fLaC` 统一显示为 `FLAC`，不改变探测到的文件事实。修正后的规范 Debug 包摘要为 `f1f91c807ed3e7a0d8e252a108a6114d10598855de0227796d74a15599e6cc76`，启动前身份核验通过，版本 `0.0.1 (2)`，只包含 `en.lproj`。再次建立独立临时库并从绝对路径启动唯一普通窗口，Welcome 为空；Add Folder 选择同一许可套件。Library 切换 List 并滚动到 `26-audio-flac.flac` 后，辅助功能值和当前窗口截图均显示 `0:06 · 1 audio track · FLAC`，同排的 PCM、AAC 和未知属性行保持正常布局。此次没有播放 FLAC 文件，不能把标签显示当作解码或出声验证。退出本轮进程后，隔离目录和 `BOMU_ACCEPTANCE_LIBRARY_DIRECTORY` 均回读为已清理。

最终源码另运行 `./scripts/test-dev.sh --native -quiet`：160 项 Python 检查通过，Xcode 结果包 `Test-Bomu-2026.10.24_16-38-23-+0800.xcresult` 的 `xcresulttool` 汇总为 14/14 项原生 XCTest 通过、0 失败、0 跳过，测试宿主已退出。该结果覆盖现有真实 mpv、历史隔离与资源释放回归；它不补齐未测的全屏、跨屏、物理声画同步或睡眠恢复。

## 播放中滚动的有界采样与进程负载

加入 `scripts/capture-animation-hitches.py`，只对指定 PID 附加 Animation Hitches，给录制、保留窗口、总墙钟时间和原始 trace 大小设上限；成功时调用现有脱敏汇总器并删除原始 trace，失败时也停止本轮采样进程并清理。该脚本被构建身份系统列为输入，因此重新构建并核验规范 Debug 包，源码摘要为 `6326ec31937648b89c77cd14c50679277d03fcf0f4dc759913e25b35c7810da4`，产品代码与前一摘要相同。

在已解锁桌面用带标记的临时库启动唯一普通窗口，添加 30 项许可样本，打开约 15 分钟的 H.264 样片，再返回 Library Grid。对已核验的唯一 Bomu PID 以 8 秒录制、保留末尾 5 秒、45 秒墙钟和 768 MiB 原始 trace 上限采样，并在期间上下滚动。Xcode 27.1 的 `xctrace` 再次超过自身录制时限，守护脚本按墙钟上限结束，**没有得到可用帧时长或主线程延迟数据**。这次原始 trace 在 28 秒时只有约 52 KiB，最终已删除；回读无本轮 `xctrace` 进程及 trace 目录。新的安全上限避免了此前数 GB 原始数据遗留，但没有修复 Instruments 的录制故障。

在同一进程、同一仍在播放的样片上，另用 `ps` 的累计 CPU 时间和 RSS 每约 0.5 秒采样，结果只保留忽略目录中的聚合 JSON：

| 阶段 | 样本 / 时间 | 进程 CPU（100% = 一个逻辑核） | RSS 起点 → 终点 / 峰值 |
| --- | ---: | ---: | ---: |
| Library Grid 上下滚动 | 35 / 17.50 s | 46.98% | 84.80 → 87.45 / 96.41 MiB |
| Player 页面持续播放 | 35 / 17.62 s | 52.95% | 84.03 → 87.02 / 87.02 MiB |

样本来自顺序阶段，Library 的 30 项卡片已加载过，短时 RSS 峰值后回落；CPU 数值包含播放、属性和界面共同开销。不能从两阶段差值推出资料库滚动更快，也不能据此签收帧率、首次大库加载、实际后台许可活动数或长期内存稳定性。播放器进度继续推进到约 2:47，但本轮未取得用户的声画主观确认。结束后只退出本轮 Bomu 进程，临时库目录与启动变量均回读为已清理。

## 当前包的 Welcome 应用菜单入口

在同摘要 `6326ec31937648b89c77cd14c50679277d03fcf0f4dc759913e25b35c7810da4` 的规范 Debug 包中，以新的带标记隔离空库打开唯一普通窗口，Welcome 显示 Open Video…、Add Folder、Settings 与 Restore from Backup…。从 macOS 顶部 Bomu 应用菜单选 `Settings…` 后，同一窗口显示 Settings / Appearance；点击侧栏 Home 回到 Welcome。再次从应用菜单选 `Settings…`，仍进入同一 Settings 窗口。菜单中的 Settings 路由因此有两次可见执行证据；先前桌面工具返回元素失效并非本次复现的产品故障。没有修改系统设置或用户资料库，结束后本轮进程、临时库与启动变量均已清理。首次加载期间的路由竞态和其它菜单操作仍需单独覆盖。

同日只读复查 `pmset -g log`，当前开机时间为 2026-10-19 10:17，系统汇总 `Total Sleep/Wakes since boot: 0`。`pmset -g assertions` 同时列出 DeviceHub 的显示串流、音频设备、ChatGPT/Electron 等闲置睡眠相关声明；`PreventSystemSleep` 为 0。这些是睡眠未被日志确认的环境线索，不能据此断言其中某一个声明就是手动睡眠失败的根因。没有关闭其他应用、断开显示串流、提升权限或再次触发睡眠；A08 睡醒恢复仍未验收。

为缩小 `xctrace` 失败范围，另启动本轮独有的 `/bin/sleep 60` 无界面进程，对它附加相同的 Animation Hitches 模板，设置 3 秒录制与 2 秒保留窗口。25 秒墙钟后 `xctrace` 仍未退出，原始 trace 已约 1,232 MiB；诊断脚本结束本轮进程并删除 trace，回读无残留。无界面进程不提供应用帧率结果；此对照只说明相同模板的命令行卡住不限于 Bomu PID，不能单凭它把原因归于 Bomu 的 SwiftUI 滚动。

## 双音轨菜单、停止与同路径恢复

从许可的 `.build/media-suite/28-two-audio-tracks.mkv` 以 `ffmpeg -stream_loop 19 -i <源文件> -map 0 -c copy -t 120 <输出文件>` 在忽略目录生成 `two-audio-tracks-120s.mkv`，不重编码源内容。`ffprobe` 回读时长 120.136 秒、1 条 H.264 视频和 2 条 AAC 音轨。新文件只作本机验收素材，没有纳入公开源码树。

在摘要 `6326ec31937648b89c77cd14c50679277d03fcf0f4dc759913e25b35c7810da4` 的已核验 Debug 包中，以新的隔离空库从 Welcome 打开该样片。播放器进度持续推进；Audio & Subtitles 菜单先显示 Track 1 选中，点击 Track 2 后重新打开菜单显示 Track 2 选中，切回 Track 1 后再查也恢复对应勾选。通过 Playback 顶部菜单执行 Stop，唯一窗口返回 Welcome；重开同一路径后继续播放。随后回退到约 36 秒，再次切到 Track 2 并在 57.466 秒暂停。只读 SQLite 查询 `playback_history` 为位置 57.466、`audio_track_id=2`；Stop 后该值保持。再次从 Welcome 打开同一路径，播放器从该 checkpoint 附近继续到约 62 秒，Audio & Subtitles 菜单仍显示 Track 2 选中，进度继续推进。

这为双音轨菜单选择、停止、同路径位置与音轨恢复提供了当前包的 UI→真实 mpv→SQLite→UI 链路证据；没有用户对两条音轨声音差异的本轮听感确认，也不覆盖快速连续切片或其它容器。原生测试另验证轨道 ID 切换与退出资源释放。结束后仅退出本轮 Bomu 进程，隔离库目录和启动变量均回读为已清理。

## 迁移备份修正后的规范包冒烟检查

收紧备份裁剪范围后，规范 Debug 包源码摘要更新为 `090398f03229f55068855942b40fa228455000059cdfa8f9daf27e850b0deb4d`；启动前后身份核验通过，版本仍为 `0.0.1 (2)`，仅打包 `en.lproj`。以带标记的临时空库启动唯一普通窗口，Welcome 显示两个打开入口及设置/恢复入口；点击 Settings 到 Appearance，再由 Home 返回 Welcome。从文件面板选择忽略目录中的 120 秒双音轨样片，单窗口进入真实播放，测试画面可见，播放位置从约 0 秒推进到 14.974 秒；按空格后 Pause 控件变为 Play，位置停止推进。退出本轮进程后，启动变量和临时库目录均确认清理。

本次是代码修正后包的入口与播放冒烟检查，不重做之前的 Track 1/2 切换、Stop/恢复全链路，不验证可听声音、声画同步或完整视觉差异。播放中的辅助功能元素索引两次失效，故没有从该索引操作音轨菜单；这只能说明本轮自动化绑定不稳定，不能据此判断播放器控件故障。

同一最新源码随后执行 `./scripts/test-dev.sh --native -quiet`，160 项 Python 检查通过；Xcode 结果包 `Test-Bomu-2026.10.24_17-06-48-+0800.xcresult` 的 `xcresulttool` 汇总为 14/14 项原生 XCTest 通过、0 失败、0 跳过。测试宿主已退出。此结果补齐当前源码的真实 mpv 回归，不构成声音听感、物理同步或睡醒验证。

同一源码执行 `./scripts/test-dev.sh --direct-storage`：160 项 Python 检查、2 项临时 64 MiB APFS 映像内的 XCTest 均通过。写满时 SQLite 返回 13，重挂载后设备号由 16777255 变为 16777259、inode 保持 16；`hdiutil info` 未见 Bomu 临时映像残留。此前同类测试的详细断言仍见存储专项代码和记录。

## 当前摘要 090398 的三尺寸与资料库抽查

再次核验源码摘要 `090398f03229f55068855942b40fa228455000059cdfa8f9daf27e850b0deb4d` 的规范 Debug 包，版本 `0.0.1 (2)`、仅 `en.lproj`。在同一块屏幕上启动唯一普通窗口和带标记的隔离空库。只用当前窗口右下角调整尺寸；CoreGraphics 窗口边界只读回查确认 `960×640 pt`、`1440×900 pt`，初始窗口为 `1280×800 pt`，屏幕截图的 2× 像素尺寸与之相符。没有进入全屏、切换桌面空间或跨屏迁移。

Welcome 在三尺寸下显示 Open Video…、Add Folder、Settings 与 Restore from Backup…，未见控件相互遮挡。`960×640 pt` 下从恢复入口进入 Settings / Storage，向下滚动可到达 Import、Export、Clear 和隐私说明；Appearance、Playback、Subtitles、About 也可进入。`1440×900 pt` 下复核 Settings 五个分区，Storage 操作在当前视口可见；About 显示 `0.0.1 (2)` 与禁用的 Check for Updates。这里只检查布局、可达性和少数操作，不等于每个设置项的行为或设计稿像素比对。

通过 Welcome 的 Add Folder 面板选择忽略目录中的许可 `.build/media-suite`，只写入本轮隔离资料库。`1440×900 pt` 的 Home 最近加入卡片、Library 三列 Grid 和 List 均显示真实文件缩略图/音频占位与元数据，未见明显交叠。Library 的 Movie 分类和 Watched 筛选各进入明确无结果状态，Clear Filters 恢复列表；Sort 选择 Duration 后，首项为两个约 5 秒文件，随后为约 6 秒文件，完成探测后显示“未知时长排最后”。`960×640 pt` 的 Library List 与三列 Grid 也可见，行内 Play、Favorite、More actions 分离；长文件名与技术信息在本轮可见样本中未互相覆盖。

同一窄窗口 Search 空态与输入框完整；搜索 `hevc` 返回 4 项真实结果，输入不存在的名字显示 0 项和提示，Clear search 返回空态。Folders 根页显示刚加入的来源为 Available；进入该来源后 Grid 与 List 都可浏览真实样本，面包屑 Folders 可见。List 第一行的独立收藏按钮点击后显示 Added to Favorites，Favorites 页出现对应文件卡片。这是隔离库的一次正向路径抽查，没有验证持久重启、离线来源、所有菜单命中或搜索键盘焦点顺序。一次辅助功能元素索引在动态列表更新中失效，刷新后使用屏幕上的可见按钮完成收藏；没有据此判定产品缺陷。

验收结束只退出本轮 Bomu 进程；应用清单回读不再运行，隔离临时目录已删除，`BOMU_ACCEPTANCE_LIBRARY_DIRECTORY` 回读为空。结束后构建身份再次核验通过。这轮有限抽查增加当前包 UI 证据，仍未取得逐像素差异、VoiceOver、完整三尺寸全状态、播放中可量化帧时长、物理声画同步或真实睡醒结果。

对照 `设计规范.json` 与 `AppTheme` 源码，侧栏宽 176 pt、内容横向内距 30 pt、媒体三列和列距 17 pt、页面标题 27 pt、卡片标题 13 pt、封面圆角 14 pt，以及侧栏灰/内容白的角色一致；本轮截图中的分栏、三列与无卡片外框也符合这些结构规则。此项是 token 与可见结构抽查，尚未用取样仪或图像配准测量颜色、字号渲染和间距误差；系统标题栏、真实媒体封面及英文文案属于规范已记录的原型差异。

## 当前摘要 414fdb 的 1280 点单窗口复核

对源码摘要 `414fdba99407e60e89d8662a4c5ca8bae63bf283736ddcd07ff387bb6ed3c825` 的规范 Debug 包先后核验构建身份；版本仍为 `0.0.1 (2)`，只含 `en.lproj`。该摘要相较上节只改动诊断脚本，应用源码相同，但本节仍单独记录当前包的可见执行。确认桌面解锁、无其它 Bomu 进程后，从绝对路径启动唯一普通窗口和新的带标记隔离空库，并在同一屏幕将窗口调至 `1280×800 pt`；未进入全屏或跨屏迁移。

Welcome 的 Open Video…、Add Folder、Settings、Restore from Backup… 在当前尺寸均可见。经 Welcome 的 Settings 进入同一窗口后，Appearance、Playback、Subtitles、Storage、About 五个分区可达；Storage 的历史清理、私有目录、导入、导出、清库和隐私说明在当前视口可见，About 显示 `0.0.1 (2)` 与禁用的 Check for Updates。没有改变设置或触发数据清理。返回 Home 后，经 Add Folder 系统面板选择许可的 `.build/media-suite`，媒体只入本轮隔离库；Home 的三张最近加入卡片和空的 Continue Watching 可见。

Library Grid 显示三列真实文件，H.264/HEVC 缩略图、音频占位和未知属性占位维持同排封面比例及元数据槽位；List 中独立的 Play、Add to Favorites、More actions 均在辅助功能树中，当前视口截图未见交叠。Movie 分类进入明确无结果页，Clear Filters 恢复列表；Sort→Duration 后首批可见项目从两个约 5 秒样片开始，页面提示未知时长排最后。此处只观察了当前视口和可访问树，没有逐项验证全部 30 个文件的排序，也未做颜色、间距或点击区域的像素测量。

退出本轮唯一 Bomu 进程后，应用清单回读无运行实例；隔离目录已删除，`BOMU_ACCEPTANCE_LIBRARY_DIRECTORY` 回读为空，构建身份复验通过。当前包因此补有 1280 点 Welcome、Settings、Home、Library 的有限可见证据；960/1440 点的抽查仍引用产品同码的前一收据。完整 A02、VoiceOver、帧时长、物理声画同步与睡醒不因此签收；用户明确暂不进行 A07 全屏和跨屏。

## 当前摘要 414fdb 的 960/1440 点补充抽查及中断清理

2026-10-24 再次先核验 `414fdba99407e60e89d8662a4c5ca8bae63bf283736ddcd07ff387bb6ed3c825` 的规范 Debug 包，确认控制台会话解锁且无 Bomu 实例后，从绝对路径启动单个普通窗口和新的带标记隔离空库。只拖动该窗口右下角，在同一屏幕从截图为 `2560×1600 px` 的状态调到 `1920×1280 px`；CoreGraphics 边界回读确认为 `960×640 pt`。随后把窗口调到截图为 `2880×1800 px` 的状态，对应目标 `1440×900 pt`；这一次没有再次用 CoreGraphics 回读 1440 点边界，故尺寸以拖动目标和 2× 窗口截图为依据。没有进入全屏、切换空间或跨屏迁移。

`960×640 pt` Welcome 四个入口均可见；进入 Settings / Appearance 后切到 Storage，首屏显示历史清理与私有目录入口，向下滚动一页后导出、导入、清库按钮和隐私说明均在视口内。放大窗口后，Storage 同一内容在较大视口完整显示；Home 返回 `1440×900 pt` 目标尺寸的 Welcome，四个入口没有相互遮挡。Welcome 的 Add Folder 系统面板显示所选位置为许可的 `.build/media-suite`，确认后 Home 显示三张最近加入卡片和空的 Continue Watching。

较大窗口的 Library Grid 为三列真实文件，H.264/HEVC 缩略图及无法探测文件占位可见；切到 List 后，辅助功能树将每行选择、Play、Add to Favorites、More actions 分为独立操作，截图中未见可见行交叠。Viewing status 选择 Watched 后显示筛选无结果页，Clear Filters 恢复列表。缩回 `960×640 pt` 后，Library List 与 Grid 都显示真实文件；窄网格的元数据按列宽换行，首屏未见标题或操作按钮相互覆盖。Search 空态完整，输入 `hevc` 得到 4 个真实结果，Clear search 返回空态。Folders 根页将 `.build/media-suite` 标为 Available，路径文本与状态在窄窗口可见；本次没有进入文件夹内部，也没有复核 Favorites 或 Search 无结果态。

本轮桌面操作在 Folders 根页后被任务中断，因此不能记为正常结束时即已清理。2026-10-26 回查原终端会话句柄已失效，桌面应用清单无 Bomu 运行实例，`BOMU_ACCEPTANCE_LIBRARY_DIRECTORY` 为空；带标记的 `bomu-welcome.wu7q4F` 目录仍占约 3.1 MiB。核对精确目录名和 `.bomu-acceptance-library` 标记内容后只删除该本轮测试目录，回读不存在；构建身份再次核验通过。没有处理任何其它应用或用户资料库。

这些结果补充当前摘要在三种目标尺寸下的部分页面可见证据，仍不能替代完整逐页状态、点击区域、VoiceOver、真实播放帧时长与声画同步验收。被中断的会话也没有做资源释放或睡醒测试。A07 全屏和跨屏按用户选择继续不执行。
