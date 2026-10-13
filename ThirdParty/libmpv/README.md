# libmpv 开发依赖

当前依赖只用于 v0.0 本机播放验证。唯一版本事实源为 [`Config/Dependencies.lock.json`](../../Config/Dependencies.lock.json)：

- 二进制来自 [IINA 1.5.0 官方 Release](https://github.com/iina/iina/releases/tag/v1.5.0)，固定完整磁盘映像的 SHA-256。
- 从 `libmpv.2.dylib` 的 arm64 动态链接关系解析出 44 个非系统依赖，逐个固定 SHA-256 和依赖名称。开发构建将这些库复制到应用内部。
- 运行时查询得到 `mpv v0.41.0`、`FFmpeg 9.0.1`；实际构建配置原文保存在 lock 中。生成测试片使用的本机 FFmpeg 与应用内核彼此独立。
- `include/mpv/` 使用 [mpv v0.41.0 的公开头文件](https://github.com/mpv-player/mpv/tree/v0.41.0/include/mpv)，校验值同样写入 lock。

## 初始化与构建

```sh
python3 scripts/dependencies.py bootstrap
./scripts/build-dev.sh
./scripts/test-dev.sh
```

`bootstrap` 校验下载包，只读挂载，提取锁定的库，随后卸载；不会安装或运行 IINA。已有下载缓存时无需再次下载。`check` 会拒绝缺失、内容变化和额外的动态库。所有二进制及下载缓存位于忽略的 `.build/`，不进入 Git。头文件随代码归档。

`toolchain.py` 读取同一份 lock，核对 Xcode 版本与 build、Apple Swift 版本与编译器 build，以及 macOS SDK 版本与 build。当前为 Xcode 26.1.1（17B100）、Swift 6.2.1、SDK 26.1（25B74）；Swift 语言模式仍为 6.0，应用部署目标仍为 macOS 14.0。SDK 版本不是最低系统版本。

构建、测试和基准脚本先执行工具链检查；四个 Xcode target 的首个构建阶段也检查实际展开的架构、部署目标、语言模式及 SDK，因此直接在 Xcode 中构建或传入命令行覆盖也会核对。失败会列出期望值和实测值，不下载、安装或切换 Xcode。多版本 Xcode 可按 [Apple 的命令行工具配置说明](https://developer.apple.com/documentation/xcode/configuring-command-line-tools-settings) 为当前命令设置 `DEVELOPER_DIR`；更新 lock 需要重新取得构建与播放证据。

工具链按版本/build 身份固定；现有 SHA-256 校验覆盖运行库、头文件和来源镜像，不宣称已校验整个 Xcode 安装包。基准同时保存 `toolchain.json`，让证据对应实际经过检查的编译器和 SDK。

构建时仅对产物中的库做本地 ad-hoc 签名，原始缓存保持校验值不变。可用的开发产物不代表发行验收已经完成。

## 许可与发行边界

已保留 mpv [`Copyright`](Copyright) 和 IINA [`IINA-LICENSE`](IINA-LICENSE) 原文。此次没有复制 IINA 应用代码。当前 FFmpeg 构建配置包含 `--enable-gpl`，这套二进制不能被当作未核验的宽松许可组件。

Release 构建暂时由依赖脚本阻止。对外分发前，需要完成全部传递依赖的许可清单、对应源码与构建材料、应用许可兼容性确认，以及 Developer ID 签名、公证和干净机器安装验证。当前两个许可文件并不代替这项工作。
