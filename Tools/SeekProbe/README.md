# TS 定位诊断

此工具把 Bomu 已发现的 TS 精确定位故障缩小到播放内核。它只在 `.build/seek-candidates/` 构建独立实验，不修改正式运行库、应用配置或用户视频，也不创建窗口。

## 运行

先按仓库说明准备固定运行库、工具链和 A04 素材，再执行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=macosx \
  /usr/bin/python3 scripts/verify-seek-candidate.py
```

需要 Python 3.9+、FFmpeg/ffprobe、macOS 的编译与签名工具。首次下载官方 FFmpeg 9.0.1 源码，校验固定 SHA-256；每次运行创建新目录，以相同参数构建原版和候选 `libavformat`，其余库均复制已核验的固定运行库。`--output` 可指定尚不存在的实验目录。

`main.c` 是独立 libmpv 适配器。控制线程持有 core，专用线程持有软件 render API 调用；回调只通知，不调用 mpv。输出为 JSON 行，日志另存。它先暂停并消耗在途帧，随后记录定位前、暂停定位后、恢复后的状态。`PLAYBACK_RESTART` 仅用于时间测量，成功还要求目标误差不超过 0.2 秒，并在暂停定位和恢复两个阶段分别产生新视频帧。纯音频明确要求没有视频帧且 null 音频输出存在。

退出顺序是停止播放、移除渲染回调、回收渲染线程、释放 render context、销毁 core。单个子进程最长 30 秒，超时会终止该子进程并判为失败。

## 报告解释

- `pinned`：仓库当前固定运行库；`rebuilt`：同参数重编的未修改解封装库；`candidate`：只加上视频关键帧定位修正的解封装库。
- 8 组媒体覆盖相同视频的三种容器、长片 MP4/TS、H.265 Main10 TS、MPEG-2 TS、纯音频 TS。新增媒体仅来自经校验的 CC0 样本或数学图案。
- 另有完整缓存短片与有限缓存长片对照。原版失败被保留，不能从报告里删除。
- `experimentPassed` 表示候选用例全部满足断言、原版故障复现、控制组通过，以及缓存对照符合实测。它不是 A04 或 v0.0 验收结果。
- `promotedToApplication=false`、`desktopVerified=false` 始终保留。软件内存帧、null 音频输出和单次内核重启用时不代表实际画面、声音或界面响应。

当前修正与 15 分钟补充验证见 [定位调查](../../docs/playback/media-suite/seek-investigation.md)。正式接入还需要完整运行库能力/许可审计与应用层回归；不要把实验 dylib 覆盖到 `.build/dependencies/lib`。

## 连续操作与关闭回归

对已经成功的独立实验继续运行，不重新构建或替换其中的解封装库：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer SDKROOT=macosx \
  /usr/bin/python3 scripts/verify-seek-lifecycle.py .build/seek-candidates/<实验目录>
```

入口先核对原报告、正式依赖锁、候选修正、每个动态库和媒体的 SHA-256；任何身份变化都显式拒绝。新的 probe 以 `-Wall -Wextra -Werror` 编译，结果存入全新的 `lifecycle-*` 目录。

- 短 TS、长 TS 和 MP4 对照各在一个 core/render context 中完成四次前后定位、100 条异步定位、定位请求后立即替换文件及停止。分别检查目标位置、暂停意图、新帧、全部命令回复、替换文件身份和停止后一秒无新增帧。
- 固定运行库与候选各做 10 次 `loadfile` 排队后立即关闭；不等待 `FILE_LOADED`，关闭必须在五秒内返回，渲染线程已回收，render context 和 core 已释放。外层每个进程有 30 秒上限。
- 未收到所有命令回复、未知资源状态、报告缺阶段、原生非零退出均不能通过。原版 TS 失败保留为对照。

这是内核队列交错检查：没有运行 `PlayerModel` 或应用的 request ID 过滤，也没有证明取消发生在某个特定解码指令中途。释放记录说明销毁 API 返回和线程回收，不等同于泄漏分析。原来的单次定位 JSON 协议保持兼容。

## 上游代码与许可

`ffmpeg-9.0.1-ts-keyframes.patch` 是对 [FFmpeg 9.0.1 `libavformat/mpegts.c`](https://github.com/FFmpeg/FFmpeg/blob/n9.0.1/libavformat/mpegts.c) 的候选修改，遵循该文件的 **LGPL-2.1-or-later** 许可。完整原始源码、版权声明和 `COPYING.LGPLv2.1` 随经校验的官方源码包保留在实验目录。尚未向上游提交，也未形成正式发行依赖。
