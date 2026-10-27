# 显式外部文件加载边界

2026-10-26。当前播放阶段由用户明确选择外部字幕，媒体库封面由真实视频抽帧获得；本地封面/NFO 整理属于后续任务。打开一个文件不应由内核额外发现目录中的封面或音轨。

## 发现与修改

在规范包 `a9f3332e…` 的正常 Home 中打开既有合成样片，界面持续 Opening。取消后 UI 回 Home，但再打开另一文件仍停在 Opening；通过应用菜单请求 Quit 后没有观察到进程退出。

三份线程样本位于 `.build/acceptance/a9f3332e-ui/`：`opening-sample.txt`、`opening-after-cancel-sample.txt`、`quit-after-opening-sample.txt`。mpv worker 停在 `load_external_opts_thread → autoload_external_files → find_external_files → append_dir_subtitles → opendir/open`，取消后控制队列还在等待同步 stop 命令。样本不能解释操作系统为什么让该目录调用长时间等待，也不能证明退出内部已走到哪个阶段。

固定 mpv 0.41.0 的 `audiofile_auto` 默认为 no，但 `coverart_auto` 默认为 exact。Bomu 原来仅设置 `sub-auto=no`；这不足以跳过共用目录扫描。`autoload_external_files` 只有在字幕、音频、封面三类自动发现全部关闭时才提前返回，而目录扫描中的 `opendir` 发生在后续取消检查前。依据为锁定源码归档及 [mpv 0.41.0 loadfile.c](https://github.com/mpv-player/mpv/blob/v0.41.0/player/loadfile.c)、[external_files.c](https://github.com/mpv-player/mpv/blob/v0.41.0/player/external_files.c)。

`BMMPVSession.configureCore` 现明确设置 `sub-auto=no`、`audio-file-auto=no`、`cover-art-auto=no`。内嵌轨道照常来自文件；用户选择外部字幕仍调用现有 `sub-add`。不增加目录权限、不复制/修改用户媒体，不按单个路径或文件名加例外。该改动避免不属于当前产品用例的目录发现，不声称解决所有不可中断文件系统调用。

调用链：打开意图 → PlayerModel 当前 request → MPVPlaybackEngine → BMMPVSession 单一内核配置 → libmpv 跳过自动 sidecar 发现 → 原有媒体加载；外部字幕选择 → 带 request ID 的显式 `sub-add` → 真实 track-list → 菜单。

## 当前验证

- 规范 Debug `afdcd42296645439dad980031fde5603b64e934e03bdeec80f2363cbffe4db2c`，0.0.1 (2)，仅英文，构建成功。该包也包含已核对的离线标题色与紧凑网格行距 16 pt 修正。
- 唯一 PID 36756 从正常 Home 打开之前卡住的 `43a8d4-long-silent.mp4`，实际合成画面可见，时间由 0:23 推进到 0:38。菜单 Stop 遇到自动化元素失效，不能计为通过；最终通过 ⌘Q 正常退出，进程查询确认无 Bomu 残留。
- 新增真实内核行为测试：音频-only WAV 配同名 JPEG 不发现外部封面；带视频样片保持内嵌轨道、显式添加 SRT、停止后重开不隐式恢复 sidecar。WAV/SRT 由测试生成，JPEG 来自既有合成视频抽帧。
- 带视频文件本身会让 mpv 跳过附加封面轨，不能靠“视频 + JPEG 没有外部轨”证明封面扫描关闭。因此另设音频-only 测试。
- 原生测试宿主目前在 dyld 文件加载阶段阻塞，尚未执行新用例。两次脚本默认签名禁用、一轮使用本地 ad-hoc 签名后仍未进入 XCTest；签名本身不是已证实根因。相关 TCC AllFiles preflight 请求已快速返回，不能据此要求用户扩大权限。随后标准 build-for-testing 成功，使用同一已签名产物和 xctestrun 在带标记临时目录运行，仍停在 dyld __open、没有进入 XCTest。四轮未初始化宿主与 runner 均已结束，临时产物已清理，保留日志与样本，不将启动失败算作测试通过。两项新增 XCTest 的执行仍待完成。
- 补充独立无窗口真实 libmpv 对照：生成 12 秒静音 PCM WAV，同名 JPEG 来自已有合成 H.264 抽帧，SRT 为生成文本。相同固定库、`vo=null`/`ao=null`、暂停加载，旧 `cover-art-auto=exact` 得到 1 个音轨和 1 个外部封面视频轨；新 `no` 得到 1 个音轨、0 外部轨。两组起初均无字幕，随后显式 `sub-add select` 均选中 1 个外部字幕，Stop 与 core 销毁正常完成。原始输出 `.build/mpv-backport-preparation/sidecar-{exact,no}.json`，探针为同目录 `sidecar_probe.c`。这证明配置的内核行为差异，不替代应用适配层的 XCTest、可见画面/声音或异常目录取消验收。
- `./scripts/build-dev.sh --analyze` 在当前源码（含 `9c11ad82…` UI 修正）成功；日志 `.build/sidecar-scan-2026-10-26/analyze.log`。

本问题与用户报告的播放中 9 GB 内存占用没有已证实因果关系。GL fence 回补和长时内存对照独立跟踪。

测试收尾后从同一规范包恢复正常 Home，唯一 PID 40057、无 sheet/菜单，窗口交还 UI 验收任务；运行依赖仍为原固定 libmpv，尚未采用 GL fence 回补候选。
