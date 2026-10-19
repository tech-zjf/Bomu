# 本地视频缩略图与缓存

## 职责

`MediaThumbnailCache` 从本地视频抽取一帧并生成受限 JPEG 缓存。它只持有缓存目录、生成器和缓存策略，不改变来源文件，也不依赖 SwiftUI。媒体库 UI 通过文件 ID、内容版本和本地 URL 请求缩略图；修改后的文件使用新的内容版本，自然得到独立缓存键。

缓存服务、抽帧适配器及媒体卡片的加载/占位/取消状态已接入 C05 首页。媒体库隐藏时卡片任务会因 `isVisible` 变化而取消。

## 调用与资源生命周期

1. 媒体库展示层应先调用 `cachedThumbnail`。命中时直接显示缓存，不创建 AVFoundation 资源。
2. 未命中时调用 `thumbnail`。缓存 actor 验证来源文件存在，以媒体 ID 和内容版本对应的缓存 URL 合并进行中的请求；每个调用方有独立等待者。不同键最多允许两个生成任务并行，等待名额也可取消。
3. 生成器读取 AVAsset 时限为十秒，选择约一秒处的画面、应用轨道变换并限制像素尺寸。取消会向 AVAssetImageGenerator 发出取消请求。
4. 生成返回后在缓存 actor 内重新检查同一个键：其他请求已经提交时直接复用，避免把同一条目的字节再次计入待腾出的空间。仍未命中时才按最近访问时间淘汰旧 JPEG 并原子写入；检查、淘汰和写入之间没有异步暂停点。命中和淘汰都要求缓存键对应普通文件；符号链接不会作为缓存返回或被清理，避免访问时间更新到来源文件。目录由调用方指定，清理只遍历该目录。
5. 缓存错误由调用方转成占位图；不能阻塞文件名和媒体条目先显示。

`MediaThumbnailCache` 应由媒体库场景或应用级依赖持有，不能在视图重算时重复创建。缓存文件允许系统清理，因此数据库不把缓存 URL 当成永久媒体事实。

## 失败与边界

- 缺失或非普通文件返回来源不可用错误；只有音轨或不可抽帧的视频返回无画面错误。
- 超时和抽帧失败不提交缓存。单个调用方取消只退出自己的等待；最后一个等待者取消才取消工作任务。提交前再次检查取消；已经完成的原子缓存写入不因迟到的取消被删除。
- 单张图大于整个缓存上限时返回明确错误，不删除来源媒体。
- 内容版本由媒体身份层提供。版本变化不会展示旧内容缩略图；旧版本缓存通过后续 LRU 淘汰。
- 超时取消依赖 AVFoundation 生成器响应取消。替代生成器也必须遵守协作式取消契约。

## 行为验收

`MediaThumbnailCacheTests` 验证并发最多为二、缓存命中复用、超时会取消生成器、容量淘汰遵守 LRU、符号链接不会触碰其来源，并逐字节确认来源文件未被修改。当前逻辑测试通过。H.264 与 HEVC Main10 的后台真实抽帧已有下述证据；应用卡片里的可见呈现仍需要 Screen 1 的单个普通窗口验收。

2026-10-19 的并发提交回归先复现了同键请求重复生成完成后过度淘汰其他缓存的问题：容量足够容纳两个不同条目，原实现却在第二次提交同一条目时删除第一个条目。修复后两个请求返回同一缓存文件且原条目保留。该检查使用极小的临时文件，不扩大真实缩略图缓存；它验证提交和容量计算。随后本页记录的共享任务改动进一步消除了同键的重复生成。

该修复后的无宿主回归通过 143 项 Python 检查和 117 项 XCTest（2026-10-19 10:34），随后 Debug 应用构建通过。

## 同版本请求共享生成

首页多个分区可能同时展示同一媒体。缓存 actor 用一个进行中条目拥有生成任务和等待者集合；每个等待者通过独立 continuation 接收结果。一个卡片消失时只取消自身等待，仍可见的卡片继续接收同一生成结果。最后一个等待者退出时删除进行中条目并取消工作任务，后续请求可以重试。每次工作都有独立 ID，旧工作晚完成不能清除或回复新工作的等待者。

共享仅按媒体身份与内容版本合并，来源 URL 不是持久缓存身份。不同版本继续生成独立缓存文件。生成工作仍通过最多两份许可，超时与取消沿既有适配器传播；取消清理未结束时不会凭空增加许可。错误回复所有当前等待者并移除条目，下次请求可以重试。缓存提交与 LRU 计算保持 actor 内连续执行，来源媒体保持只读。

```mermaid
sequenceDiagram
    participant CardA as Continue Watching
    participant CardB as Recently Added
    participant Cache as MediaThumbnailCache
    participant Worker as Shared generation
    CardA->>Cache: thumbnail(file ID, revision)
    Cache->>Worker: acquire permit, generate with timeout
    CardB->>Cache: same file ID and revision
    Cache->>Cache: join existing waiter set
    alt one caller leaves
        CardA->>Cache: cancellation
        Cache-->>CardA: CancellationError
        Worker-->>Cache: JPEG
        Cache->>Cache: validate, evict if needed, atomic write
        Cache-->>CardB: cached URL
    else all callers leave
        CardA->>Cache: cancellation
        CardB->>Cache: cancellation
        Cache->>Worker: cancel task
        Worker->>Worker: cancel generator or queued permit; release held permit
        Cache->>Cache: ignore late completion for abandoned ID
    end
```

2026-10-19 的修复前计数回归对两个不同媒体及第二个媒体的重复并发请求记录到 3 次抽帧；共享后为 2 次，重复请求返回同一缓存文件且第一条缓存保留。新增回归覆盖单个消费者取消后另一个仍成功、最后消费者取消生成且许可可用于重试、共享超大结果向所有等待者报错且下次能重试，以及不同内容版本不会复用旧图。测试使用临时缓存和受控生成器，不扩大用户缓存。这是抽帧任务数量与资源边界证据，不是实际首页耗时或 CPU 降幅测量。

### 最终验证

2026-10-19 12:33 完整无宿主回归通过 143 项 Python 检查和 152 项 XCTest；Debug 构建及 Xcode 静态分析通过。并发上限仍为 2，未增加生产缓存预算。

随后直接编译当前缓存源文件，使用默认 AVFoundation 生成器进行后台真实抽帧。每个视频使用独立临时缓存目录、8 个同键并发请求；返回 URL 去重后均为 1，ImageIO 解码输出为 640×360，源视频抽帧前后按完整字节比较一致。两张 JPEG 均目视呈现测试片的 1.000 秒彩条帧。

| Fixture | SHA-256 |
| --- | --- |
| `h264-sdr.mp4` | `fe4dbcc9d476976084991517ec5c45349fa2327598a8431060fae28ee1cfa59d` |
| `h265-main10-sdr.mp4` | `c8f8580d420865294a00366a044e6050774cf6d28e846428984b58441c1c822d` |

受限 shell 的首次 H.264 运行报告系统查询失败并返回 noVideoFrame，不能算成功证据；相同源文件和视频在正常本机权限下通过。临时验证工具、二进制和 JPEG 随后删除，未写入用户生产缓存。以上是默认适配器输出证据，不替代整个媒体格式矩阵、应用可见加载延迟或辅助功能验收。
