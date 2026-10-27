# 播放中约 9 GB 内存反馈

## 问题与边界

用户于 2026-10-26 报告：当天有一段时间 Bomu 的内存持续约 9 GB，随后补充当时正在播放视频。原进程已不在，缺少当时文件格式、时长、操作序列和内存区域快照。用户再次确认无法回忆具体路径或时长，后续采用有来源的标准合成媒体做长时间复现，不以补充原文件为前置阻塞；根因未定位，问题保持开放。不能用重启后的低占用或短期基准判定已修复。

本轮先取证，不盲目调整解码、缓存参数，也不据此更换内核。当前应用只对本地文件播放，mpv 禁用用户配置与脚本；重点仍需结合复现检查解码器、图形缓冲与业务对象的持有。

## 已有证据

- 规范 Debug 包 0.0.1 (2)，仅英文；应用源码摘要 `cc83b441202af071a4ba98270f3eb8c7478cd7915f8b7ad19f8b5c7d90da39d3`。采样脚本在该包构建后新增，不改变运行中的应用代码。
- 19:21 的唯一 Bomu PID 15797，启动于 19:15:48：`vmmap -summary` 的 physical footprint 为 207.6 MiB，进程峰值 287.9 MiB。当时临时媒体库、合成短片暂停；不代表用户原文件播放场景。
- 后续 60 秒暂停采样峰值约 207.7 MiB。为验证取证分支，**仅这次脚本自检**把触发阈值设为 1 MiB，成功生成一次 vmmap 汇总；不是内存异常。原始数据在忽略目录 `.build/benchmarks/memory-20261026-192326-15797/`。
- 仓库本地 25 份包含 footprint 的历史基准报告，最高采样约 496.6 MiB，包含未完成的测试。它们以短时、独立基准为主，不覆盖用户本次长时间运行。
- 正常缩略图目录当前 54 个 JPEG，总磁盘 1,412,897 字节，最长边均不超过 640。每张展开一次 RGBA 的像素估算合计约 48.4 MiB；不是实测内存，也不包含重复持有、生成器或 GPU。缓存的 512 MiB 限制属于磁盘 JPEG，不是进程内存上限。该集合大小不足以直接解释 9 GB，不能据此排除历史泄漏。

## 同窗口高分辨率复核

沿用 PID 15797、同屏普通窗口与临时库。校验 `.build/benchmark-media/manifest.json` 中 CC0 合成 HEVC Main10 4K30 样片哈希后，以流复制扩展为 240 秒并移除测试音频；新片及来源记录为 `.build/acceptance/memory-hevc-main10-4k-240s.{mp4,json}`。没有改动用户媒体。

- 播放中可见时间从 0:04 推进到 2:23，画面为合成测试图。连续采样 150 秒，共 151 点：footprint 范围 503.1–556.6 MiB；前约两分钟在 503–532 MiB，后段包含暂停与打开/取消文件面板，最终 10 点约 527.3 MiB。没有复现 9 GB，也不能据短测排除长时问题。
- 同窗口切换到既有 CC0 `43a8d4-long-silent.mp4`（ffprobe 确认 H.264、960×540），随后 30 秒 31 点 footprint 为 213.9–236.9 MiB，末点 234.7 MiB。该次 4K 增量随文件切换明显回落。
- 数据分别在 `.build/benchmarks/memory-20261026-192458-15797/` 与 `memory-20261026-192917-15797/`。未触发默认 2 GiB 取证阈值。未取得本轮 Stop 菜单的可靠操作证据，不将其记录为停止释放通过。
- 通过 ⌘Q 正常退出本轮测试进程，确认退出后清理带标记的临时库，再从规范包显式清除两个验收库环境变量恢复正常 Home，唯一新 PID 17760。所有有限时长内存采样均已结束。

## 取证入口

在问题进程仍然存在时运行：

```sh
python3 scripts/capture-memory.py --pid <已核实的Bomu进程号> --seconds 300
```

调用链：命令行参数 → `proc_pidpath` 核对规范 Debug 可执行文件 → `proc_pid_rusage(RUSAGE_INFO_V0)` 核对进程 UUID/启动时间并采样 → 本地 JSONL → 首次超过阈值时 `vmmap -summary` → 最终摘要。

默认每秒采样，默认触发阈值 2048 MiB。阈值只用于保留现场，不是产品验收上限或泄漏判定。目标必须是已经运行的规范 Debug 包；脚本不启动应用、不切换焦点、不操作窗口、不关闭目标、不读取媒体内容或进程环境，也不导出堆对象。目标退出、PID 被复用、权限错误或操作员中断均结束记录，保留已采样数据并将 `completed` 置为 false。正常结束后不留下监控进程。

最长采样参数 3600 秒，区域汇总最多执行一次、15 秒超时；最后一次采样触发汇总时可能使总耗时超过采样时长至多约 15 秒。结果仅写入忽略目录 `.build/benchmarks/memory-日期-进程号/`，不会自动上传。阈值 vmmap 可能包含本机应用路径，分享前应检查。

已实际验证 ABI 读数与 vmmap 同量级、60 秒完成、阈值捕获成功、非 Bomu PID 被拒绝。尚未验证复用 PID 的真实操作系统场景；此保护由启动身份比较提供，不能写成实际复现通过。

## 代码持有边界复查

针对反馈又检查了当前源码，以下只说明实现边界，不作为无泄漏证明：

- `AppLifecycle` 持有一个 `MPVPlaybackEngine`，其拥有一个 `BMMPVSession`；SwiftUI 页面接收已有视频宿主。
- `BMMPVSession.currentTracks` 在转换完每次 `track-list` 后调用 `mpv_free_node_contents`。10 Hz 状态快照通过主队列交付，不保存历史快照数组；如果主线程长期阻塞，仍需结合现场排查排队对象，不能仅凭没有数组排除积压。
- 渲染唤醒通过合并式 dispatch source 触发已有 layer；应用统计是标量，计时查询只在基准编译开关下使用固定 8 槽。退出按 render context → CGL → mpv core 顺序释放。核心/驱动内部缓冲仍需要区域与分配证据。
- 缩略图 JPEG 上限 512 MiB 是磁盘限额。生成及显示解码共用许可池，播放活跃时额度为 1；媒体卡片隐藏时清理图像状态。这不能证明 AVFoundation 或框架内部不保留资源。

未找到足以解释 9 GB 的确定应用层持有链，因此没有直接修改缓冲上限、降低画质或把重启作为修复。随后找到下述上游原生资源问题，仍需区分它与用户原始现场。

## 长时复现与同进程释放检查

已校验 CC0 源 `h265-main10-4k.mp4` 的 SHA-256，并以视频流复制重复为 `.build/acceptance/memory-hevc-main10-4k-1860s.mp4`（1860.067 秒、HEVC Main10 3840×2160/30 fps、无音频），来源和新哈希保存在同名 JSON。计划在固定包 `a9f3332e…`、标记临时库及同一普通窗口播放，连续采样 1800 秒，再切换低分辨率文件及停止，观察回落。2 GiB 仅为一次区域快照触发值。

颜色/菜单任务明确释放后，遗留 GoToWindow 的快捷键取消/退出未生效；通过应用菜单 Quit Bomu 正常退出旧 PID 22232，再以标记临时库启动唯一规范包进程 PID 23637。20:10 可见片名、播放中 Pause 按钮及 0:04 时间，随后开始 1800 秒采样，数据在 `.build/benchmarks/memory-20261026-201037-23637/`。运行信息、构建身份和临时库指针位于 `.build/acceptance/memory-soak-2026-10-26/`。1800 秒采样已完成，共 1791 点，footprint 为 502.7–642.8 MiB；首分钟中位 507.1 MiB、末分钟中位 533.6 MiB、末点 534.1 MiB，没有触发 2 GiB 快照阈值。终点另取 vmmap，footprint 546.5 MiB，IOSurface 虚拟区域仍为 268.3 MiB（开始也为 268.3 MiB），不是物理占用 268.3 MiB。不能将这些有限读数解释为无泄漏。

最后一次成功的只读界面观察为视频位置 23:59；30 分钟采样结束时桌面工具报告锁屏。用户确认解锁后看到 Playback finished（31 分钟样片已自然结束）。锁屏时间未知，因此只签收进程采样完整，不签收全程前台可见播放或第 30 分钟画面。摘要与区域汇总位于 `baseline-result.json`、`end-vmmap.txt`。

随后同一 PID、同一窗口打开 `43a8d4-long-silent.mp4`，可见时间从 0:04 推进到 1:07；45 秒共 46 点 footprint 为 194.9–248.0 MiB，末点 195.9 MiB。通过 Playback → Stop 明确操作后返回 Welcome，再采样 45 秒共 46 点为 102.1–122.6 MiB，末点 102.1 MiB。Stop 后 vmmap footprint 102.1 MiB，IOSurface 虚拟区域 11.0 MiB；此轮已取得停止操作及释放回落证据。数据分别在 `memory-20261026-204312-23637`、`memory-20261026-204428-23637`。

通过应用菜单 Quit Bomu 正常退出 PID 23637，确认不存在 Bomu 进程后清理带标记的测试库；显式清除两个验收库环境变量后从同一规范包恢复正常 Home，唯一 PID 28613。所有采样已结束，窗口已交还菜单/UI 验收任务。实际库仍是修复前版本，不把本轮回落当作上游缺陷或原始 9 GB 问题已修复。

## 已定位的上游资源风险（尚未修复，不等于 9 GB 根因）

mpv [PR #17303](https://github.com/mpv-player/mpv/pull/17303) 于 2026-01-23 合入，说明 `vo_libmpv` 不执行内部 swap-buffers 清理，而原提交路径仍创建并保存 GL fences。修复要求存在 swap-buffers 回调才创建这类同步对象。对应首个修复提交为 `dd710281580135b40c98e95bc6a9ad562052f010`；后一个提交移除无用间接层，不是本轮定位的必要改变。

本地证据：

- `ThirdParty/mpv-build-recipe.json` 固定 mpv 0.41.0，记录 `patchesApplied: []`。核对其固定上游 build script 确有通用补丁入口，不能只凭版本文本猜测是否已回补。
- 实际 `.build/dependencies/lib/libmpv.2.dylib` 和规范应用 Frameworks 内的库 SHA-256 一致，均为 `f762a69094fbc3b2365a1abd793a0800f7f51ce5a2fde3e7523e87c47d5d292a`，与锁文件和构建来源记录相符。
- 对该实际二进制的 `_ra_gl_ctx_submit_frame` 反汇编显示，仅检查 FenceSync 函数指针后即调用并 append，没有上游新增的 swap-buffers 条件；证据在 `.build/acceptance/memory-soak-2026-10-26/libmpv-submit-frame-disassembly.txt`。
- [0.41.0 的 OpenGL libmpv 适配](https://github.com/mpv-player/mpv/blob/v0.41.0/video/out/opengl/libmpv_gl.c) 使用空的呈现回调参数并在每帧调用提交路径；Bomu 当前通过 render API 和 OpenGL 使用该路径。

已下载并核对 mpv 0.41.0 源码归档 SHA-256 `ee21092a5ee427353392360929dc64645c54479aefdb5babc5cfbb5fad626209`，以及上游原始补丁 SHA-256 `5978742f49bc5db256674097dc5feabda2435823bc3e76ef34ac87d109df76bb`，均保留在忽略的下载缓存。补丁关联的 [mpv #17217](https://github.com/mpv-player/mpv/issues/17217) 原始复现在 Linux / Mesa，不能把其文件描述符症状直接套用于 macOS；本仓库仍需实际图形资源对照。

这确认当前固定依赖仍包含上游指出的同步对象累积缺陷，但没有取得用户 9 GB 现场，不能断言两者等同。当前长测未修改依赖，保留为修复前基线。已在 `.build/mpv-backport-preparation/` 用锁定版本依赖头文件与原动态库完成隔离候选构建，候选反汇编确认新增 swap-buffers 条件。它尚未集成：仍需完成可复现依赖构建、哈希和许可记录，并验证相同输入、停止/切换/销毁及真实播放；不得用临时二进制改字节、全局屏蔽 GL 同步函数或直接放宽依赖锁替代。

另查到的 [IINA #5818](https://github.com/iina/iina/pull/5818) 修复的是其 Now Playing 封面读取路径。Bomu 没有采用该 IINA UI/封面代码，因此该报告不能直接作为本仓库根因。

### macOS 真实 GL 对象对照

使用独立无窗口 CGL 上下文、固定 H.264 合成样片、软件解码及 64×64 FBO，分别渲染 120 帧。探针通过 render API 的 GL resolver 包装 `glFenceSync` / `glDeleteSync`：继续调用原函数，仅统计成功创建和删除调用，不替换同步行为。三组均成功加载、渲染 120 帧，`glGetError=0`：

| 库 | 创建 GLsync | render context 释放后累计删除 |
| --- | ---: | ---: |
| 当前锁定库 | 120 | 0 |
| 同工具链/配置本地未修补控制组 | 120 | 0 |
| 本地单行上游回补候选 | 0 | 0 |

计数发生在 CGL 上下文销毁之前；不宣称进程退出后仍泄漏。控制组与候选使用相同源码版本、头文件、编译配置和动态依赖，仅切换上述上游条件；当前锁定库作为第三组。结果证实当前 macOS render API 路径会逐帧积累这类同步对象，回补消除了无消费者的创建。它不是原始 9 GB 现场复现，也没有测得单个对象占用或长时增长斜率。

证据位于 `.build/mpv-backport-preparation/fence-comparison.json`，包含三组库/探针/样片哈希；原始输出为 `baseline-fence-signed.json`、`local-control-fence.json`、`candidate-fence-signed.json`。探针和依赖副本均留在忽略缓存。首次加载依赖缓存发生 `CODESIGNING Invalid Page`，之后对独立副本重新签名并移除控制组的构建缓存 rpath 后执行成功，未改写规范依赖。OpenGL 上下文创建需正常本机图形服务权限，默认沙箱内失败的尝试不计通过。

当前正式依赖仍未替换。候选的隔离构建与无窗口生命周期对照如下；来源/正式构建入口与规范应用长时验收仍未完成。

后续无窗口生命周期对照使用 H.264 → HEVC Main10 → Stop → 重开 H.264 → Stop → render/core 销毁，各播放阶段 120 帧。原库累计创建 120 → 241 → 362 个 GLsync，停止确认与空闲状态到达后计数未回落，render free 后累计删除仍为 0；候选全程创建/删除均为 0，全部阶段和停止均成功。切片的过渡绘制也可能创建对象，故累计数不是简单 3×120。早期 `locked-lifecycle.jsonl` / `patched-lifecycle.jsonl` 只在销毁前读取 GL 错误，不证明销毁阶段无错误；后续最终对照见下段。仍不等于应用内 VideoToolbox、可见声画及长时内存验收。

候选先完成两次同目录干净重编译。差异来自调试符号的对象时间戳、LC_UUID 及签名；以标准 `strip -S` 去除调试信息、仓库已有 `normalize_build_uuid` 按内容生成 UUID，再以固定 identifier ad-hoc 签名后，二者均为 SHA-256 `c995b5e917f06935d1873eeb5106b97d6b4ee4b3e1e95a3f9a8baf9c1f0f563f`。仅调整构建元数据，没有修改机器指令。

进一步在不同源码/build/sysroot 路径重新配置和编译，发现构建目录 rpath 的长度会影响链接布局，即使安装后删除也无法得到相同字节。最终链接使用 Meson 生成的原链接命令，仅将构建 sysroot rpath 改为固定 `@loader_path`，移除构建用 Xcode Swift rpath，保留系统 `/usr/lib/swift`；再按上段处理调试信息、UUID 和签名。两处独立编译产物最终均为 SHA-256 `aafdabc082ed9a2ce66726554a6d9ec24fc9bf2706579ae5ca4535f29ec463a6`、4,159,056 字节，记录为 `portable-link-results.json`。新路径构建使用复制的已生成头文件和原固定动态库，尚未覆盖全空缓存下载、头文件生成与正式 bootstrap，不能称为完整发行可复现。

对这份最终候选重跑生命周期对照，结果仍为原库累积 362/删除 0、候选创建/删除 0；销毁前、render free 后、core destroy 后三个独立 GL 错误读数均为 0，且纳入探针退出码。`lifecycle-comparison-final.json` 绑定探针源文件与实际可执行文件、两份样片、两份动态库的各自 SHA-256；原始输出为 `locked-lifecycle-final.jsonl` / `portablePatched-lifecycle-final.jsonl`。两组均正常退出，没有留下探针进程。

这些实际对象计数推翻了 A09 当前内核资源边界已完整签收的结论，故 `开发任务.json` 的 A09 重新打开为进行中。历史首帧/能耗、短时基准及 Stop footprint 回落保留真实测量范围；A10 继续等待修补集成与完整证据。原始 9 GB 反馈作为独立未复现问题保留。

### 正式接入边界

来源复核确认补丁对应文件仅改变上述条件，原有 Copyright/GPL/LGPL 文本与源码归档一致；整体构建仍含 GPL 组件，不因修复文件的 LGPL 声明而改变整体登记。正式接入应保持现有 staging 原子替换流程，并区分从发布 ZIP 校验的 `baseSHA256` 与本地 overlay 产物哈希；现有 bootstrap 用最终锁哈希直接校验 ZIP，不能只替换一个 hash 字段。

后续需同时更新 mpv 构建器、依赖锁、build recipe、notice、ThirdPartyLicenses 及许可审计的来源模型，保留旧发布产物证据，禁止继续宣称回补产物与上游发布文件逐字节相同。构建器须覆盖所有归档/工具与生成头文件的依据，并验证错误输入、失败不替换正式缓存和换路径确定性。原 FFmpeg TS seek overlay 保持其独立来源与回归合同。

候选 54 个 `mpv_` 公开符号与原库一致（`candidate-abi-comparison.json`）；非系统动态库集合未变化。新工具链的系统 Swift 链接项有变化，符号集合一致不替代兼容性验证。仍需实际核对 VideoToolbox、音频、字幕与现有样片矩阵，不用软件解码/空音频探针替代。

## 后续定位与关闭标准

取得原文件/同类格式和长时间操作序列；复现高占用时在重启前保存曲线及区域汇总。依据主要增长区域决定使用分配栈还是解码/图形资源诊断。确认具体持有链后修正，并比较相同输入与操作序列下的增长趋势、停止/切文件/销毁回落；新进程低占用不满足关闭标准。

## 2026-10-27 回补接入进展

本页前述“当前正式依赖仍未替换”等表述是 10 月 26 日的阶段记录。10 月 27 日已将 mpv 0.41.0 的上游 render-fence 条件回补接入规范依赖构建：`scripts/mpv_overlay.py`、`scripts/mpv_overlay_headers.py`、`Tools/MPVOverlay/inputs.json`、补丁文件和 `scripts/dependencies.py bootstrap` 共同固定输入及构建过程。`Config/Dependencies.lock.json` 分开记录原 IINA 发布库 `baseSHA256=f762a690…` 与本地回补库 `SHA256=68befb71…`；来源、NOTICE、许可审计也已同步。三处不同长度及含空格路径的独立干净构建均得到完整相同的 `68befb7152a917850db3b345bc54129f79815d845675f65c8243490801f7e9db`。最终 `bootstrap` 在 staging 校验后更新依赖缓存，`python3 scripts/dependencies.py check` 通过；规范 Debug 包内嵌库与缓存哈希一致，构建成功，source receipt 为 `fd5b5d9979dd7687fa2651f491cd2415e0ce77b3f688873ffc9372ec7f5d5225`。

无窗口真实 OpenGL / VideoToolbox 对照使用 H.264 → HEVC Main10 → Stop → H.264 → Stop，各阶段 120 帧，实际 `hwdec-current=videotoolbox`。回补库 `glFenceSync` 创建与删除均为 0，Stop 确认、空闲及销毁后的 GL 错误均为 0；原库同序列累计创建 362、删除 0。隔离测试记录为 `.build/mpv-backport-preparation/formal-vt-lifecycle-manifest.json` 与同目录生命周期日志。185 项 Python 回归及 233 项无宿主逻辑测试通过（2 项按配置跳过）。这些证明回补进入当前 Debug 构建且目标同步对象不再累积，不替代应用窗口中的物理画面、声音、较长运行及原始 9 GB 内存现场复现。

A09 仍为进行中：规范新版窗口的播放矩阵、长时内存对照和 Stop/切片/退出回落待验。用户不记得原始文件信息，不再以它作为测试前提；保留原始 9 GB 反馈为单独开放问题。若同类高占用再次发生，应在进程仍在时保存 footprint 曲线和区域快照，不能把此处 GL 缺陷直接定为原始根因。

### 新版规范窗口的短时物理 footprint

同日从 `fd5b5d99…` 规范 Debug 包启动的唯一 PID 62956，已由同仓库 UI 验收任务播放过静音和有声样片。该任务准备打开 240 秒 4K HEVC Main10 合成片并在播放期间返回 Library 滚动时，本任务仅用 `scripts/capture-memory.py` 对已运行进程只读采样；未控制窗口。10:30:45–10:34:45（本地）每秒一点，共 240 点、完整结束。首点约 147.0 MiB（新片启动前），全程物理 footprint 峰值 598.8 MiB；30–90 秒中位 580.2 MiB，最后 30 秒中位 558.8 MiB，终点 558.8 MiB。2 GiB 的 `vmmap` 触发阈值未达到。原始采样和摘要保存在 `.build/benchmarks/memory-20261027-103045-62956/`。

这份曲线证明此**短时混合播放/浏览操作序列**没有接近 9 GB，不能与修复前 30 分钟长测直接作等时长增长比较；它不含已标记的 Stop 后窗口，也没有用户原始视频。下一轮仍需同种 4K 输入的长时播放、明确 Stop/切片/退出时间戳和资源回落，必要时在高占用现场触发区域快照。

### 回补版同素材 30 分钟与同进程切片

2026-10-27 使用唯一规范 Debug 包 `b92331d7…`（0.0.1 (2)、仅英文、内嵌回补库 `68befb71…`），在已解锁的同一屏幕、同一个普通 Bomu 窗口中播放与修复前相同的 CC0 4K HEVC Main10 静音流复制样片（SHA-256 `ac8251be…`）。测试进程 PID 66755 使用带标记临时库；独立 `caffeinate -d -t 1950` 只覆盖本轮显示保持时段，已自动结束，没有改动完整键盘访问等系统设置。30 分钟终点的辅助功能进度为 30:28，播放器仍显示播放状态。

`scripts/capture-memory.py` 在 `.build/benchmarks/memory-20261027-104752-66755/` 每秒采样，1800.0 秒共 1794 点，physical footprint 为 **503.6–556.6 MiB**，首分钟中位 **533.6 MiB**、末分钟中位 **510.3 MiB**、末点 **510.3 MiB**，未触发 2 GiB 阈值。修复前同素材 1800 秒样本为 502.7–642.8 MiB、首/末分钟中位 507.1/533.6 MiB；两轮启动条件与窗口活动不完全相同，因此只说明此固定样本没有持续向 9 GB 增长，不用两条曲线计算补丁节省内存的因果数值。

在同一 PID 和窗口切到 CC0 960×540 H.264 静音样片（SHA-256 `c66e8484…`）后，进度从 0:04 推进到至少 1:00；45 秒 46 点 footprint 为 **178.2–199.8 MiB**，末点 **198.7 MiB**，见 `memory-20261027-111841-66755`。切片后的 `vmmap` 摘要（不是长片终点快照）显示 physical footprint 182.2 MiB、IOSurface 虚拟区域 26.5 MiB，留在 `.build/acceptance/memory-soak-2026-10-27/end-vmmap.txt`。低清片随后自然结束，再采样 45 秒 46 点恒为 **143.3 MiB**，见 `memory-20261027-112115-66755`。

本轮 Playback 菜单的 Stop 项虽可见，但 CUA 点击均返回元素失效；键盘菜单尝试也未取得可核对的 Stop 结果，低清片已自然结束，所以**不记 Stop 验收通过**。对 PID 66755 执行正常 Cmd-Q 后已确认进程不存在；启动脚本报告带标记临时库清除，常用库的单个规范 Bomu Home 窗口已恢复。详细范围、进程/素材哈希和每段采样路径记录在 `.build/acceptance/memory-soak-2026-10-27/plan.json`。原始 9 GB 视频和操作序列未知，仍保持单独开放；本轮静音样片也不证明声音或物理色彩。
