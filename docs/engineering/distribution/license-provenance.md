# 运行库来源与公开发行许可门

## 当前已核实

- 开发运行库来自锁定 SHA-256 的 IINA 1.5.0 arm64 二进制镜像；`Config/Dependencies.lock.json` 锁住 44 个运行时 dylib 的内容哈希、依赖名及传递依赖关系。
- 我只读检查了这份镜像内的 `IINA.app/Contents/Resources/Credits.rtf`：其中包含 mpv、FFmpeg、Just、PromiseKit、GRMustache 和 Sparkle 的许可文本，但没有 44 个运行时 dylib 的逐项清单。Credits 将 FFmpeg 描述为 LGPL，而 Bomu 锁定的二进制配置包含 `--enable-gpl`；这说明 Credits 不能直接当作这份二进制的精确许可证判断或完整 NOTICE。
- 通过运行时版本查询确认 mpv 0.41.0 与 FFmpeg 9.0.1。FFmpeg 的本项目构建参数明确包含 `--enable-gpl`；此外，`libavformat.63.dylib` 被替换为本仓库基于 FFmpeg 9.0.1 源码与补丁构建的 TS 定位版本，并锁住补丁与输出哈希。
- IINA 的依赖构建仓库说明其依赖按层组织，源版本和校验值记于 `versions.env`。这只能作为构建方法的线索；目前没有把与本地 IINA 1.5.0 镜像严格对应的依赖构建仓库提交、全部源码归档、补丁集合和安装脚本纳入本仓库。
- IINA 的版本化二进制端点 [`/dylibs/1.5.0/universal/`](https://iina.io/dylibs/1.5.0/universal/) 提供 44 个同名 dylib。**本轮替换前**，IINA 1.5.0 镜像中 43/44 个二进制的 arm64 内容与该 endpoint 对应；唯一差异是本项目按锁定补丁重建的 `libavformat.63.dylib`。本轮已有五项改用固定 CI Release 文件，因此这组 43/44 结果是历史比较，不代表当前 Bomu 缓存。逐文件哈希、签名边界和比对方法见 [`iina-1.5.0-deps-comparison-2026-10-14.json`](iina-1.5.0-deps-comparison-2026-10-14.json)。
- 同名 IINA 1.5.0 专用依赖发布 tag [`iina-1.5.0-release`](https://github.com/iina/deps-buildscripts/releases/tag/iina-1.5.0-release) 指向 commit `f86d54276547df6d14104583ea604af67433f1e1`。我核对了该 commit 对应的 [GitHub Actions 成功运行](https://github.com/iina/deps-buildscripts/actions/runs/35411161790)：arm64、x86_64 和 package 三项工作均成功；三个 Actions artifact 的 SHA-256 分别与同名 GitHub Release 附件完全一致。先前 IINA DMG 中有五个二进制虽匹配官网 endpoint，但不匹配该 Release 包；本轮已逐字节改用固定 Release 附件中的五个文件，依赖锁和许可清单同步更新。当前五项来源均绑定到 commit、成功 workflow、Release 附件哈希和本机二进制哈希。原始差异分析仍见 [`iina-1.5.0-deps-comparison-2026-10-14.json`](iina-1.5.0-deps-comparison-2026-10-14.json)，本轮替换映射见 [`iina-runtime-artifact-adoption-2026-10-15.json`](iina-runtime-artifact-adoption-2026-10-15.json)。
- IINA 当前托管的 [`filelist.txt`](https://iina.io/dylibs/universal/filelist.txt) 是可变清单，不含版本标识或内容哈希；本次同时保存的 1.5.0 版本化 `filelist.txt` SHA-256 为 `3f3555deb2107677b8060cd2c4ea9487b2adf8f40c70329742e3335f47024cf6`，用来固定本次逐文件比较的输入名称集合。
- `liblz4.1.dylib` 的证据链已闭合：源码归档固定为 lz4 1.10.0，构建脚本来自锁定的 IINA 依赖构建提交，arm64 内容与该提交成功 CI 的 Release artifact 匹配。许可证按实际构建目标取 `lib/LICENSE` 中的 BSD-2-Clause；仓库根目录程序使用的 GPL 条款不用于这个 dylib。原文快照、Git blob、源码摘要、配方和本机二进制哈希见 [`liblz4-build-recipe.json`](../../../ThirdParty/liblz4-build-recipe.json)。
- `libogg.0.dylib` 的证据链也已闭合：libogg 1.3.6 发布说明给出的 tarball SHA 与锁定 IINA `versions.env` 相同；上游 `COPYING` 原文 blob 为 BSD-3-Clause；arm64 Mach-O 内容与固定提交成功 CI 的 Release artifact 规范化后匹配。本机锁定二进制、发布包、构建脚本和来源版本均绑定在 [`libogg-build-recipe.json`](../../../ThirdParty/libogg-build-recipe.json)。
- WebP 家族的 `libsharpyuv.0.dylib`、`libwebp.7.dylib` 与 `libwebpmux.3.dylib` 共用 libwebp 1.6.0 源码包和 BSD-3-Clause `COPYING`。三个 arm64 二进制分别与锁定 IINA 构建提交的成功 CI Release artifact 匹配；CMake 开关、上游构建脚本、归档摘要、许可证原文和各自锁定哈希见 [`libwebp-build-recipe.json`](../../../ThirdParty/libwebp-build-recipe.json)。
- `libzstd.1.dylib` 使用 Zstandard 1.5.7 的 BSD-3-Clause `LICENSE`；归档 SHA 和 CMake 构建脚本由固定 IINA 依赖提交定义，arm64 二进制与同一提交的成功 CI Release artifact 匹配。证据见 [`zstd-build-recipe.json`](../../../ThirdParty/zstd-build-recipe.json)。
- `libass.9.dylib` 使用 libass 0.17.5 的 ISC 许可。已核对上游发行归档 SHA、启用 fontconfig 的固定构建脚本和 IINA 成功 CI artifact 的 arm64 内容；配方也保留了该构建对已审计 fontconfig 等传递库的实际依赖背景，详见 [`libass-build-recipe.json`](../../../ThirdParty/libass-build-recipe.json)。
- `libspeex.1.dylib` 使用 Speex 1.2.1 的 BSD-3-Clause 许可。构建脚本明确禁用 libogg，避免把 Ogg 组件混同到 Speex 许可记录中；源归档、构建选项、上游 COPYING blob 和 IINA 成功 CI 的 arm64 内容匹配见 [`speex-build-recipe.json`](../../../ThirdParty/speex-build-recipe.json)。
- `libfribidi.0.dylib` 绑定 GNU FriBidi 1.0.16 的 LGPL-2.1-or-later 全文、固定发行 tarball、Meson 构建配方和 IINA 成功 CI artifact 的 arm64 匹配；`AUTHORS` 原文一并留存并校验 Git blob，见 [`fribidi-build-recipe.json`](../../../ThirdParty/fribidi-build-recipe.json)。
- `libudfread.3.dylib` 已直接核验 VideoLAN 1.2.0 tarball SHA 与锁一致，并从该 tarball 原样保存 LGPL-2.1 COPYING；其源文件版权头覆盖 VideoLAN authors 与 hpi1。Meson 选项、固定 IINA 构建脚本、成功 CI artifact 的 arm64 匹配及本地哈希见 [`libudfread-build-recipe.json`](../../../ThirdParty/libudfread-build-recipe.json)。
- `libbs2b.0.dylib` 已直接核验 SourceForge 3.1.0 tarball SHA 与锁一致，并从归档根目录原样保存 MIT COPYING。配方还逐项记录 IINA 构建脚本对 configure/Makefile 输入所做的生成前编辑，避免把重建后的库误说成未经变换的发行归档产物；arm64 发布匹配见 [`libbs2b-build-recipe.json`](../../../ThirdParty/libbs2b-build-recipe.json)。
- `libbluray.2.dylib` 已直接核验 libbluray 1.4.1 源码归档 SHA 与锁一致，并保存归档中的 LGPL-2.1 原文。固定 IINA 构建脚本禁用 BD-J、示例和开发工具，并使用单独锁定的外部 libudfread；本机 arm64 内容与对应成功 CI Release artifact 匹配。源码、外部依赖关系、构建选项与二进制哈希见 [`libbluray-build-recipe.json`](../../../ThirdParty/libbluray-build-recipe.json)。
- Vorbis 1.3.7、SVT-AV1、libjpeg-turbo 与 mpv 的五个运行库现均精确采用固定 `deps-buildscripts` Release 附件二进制，并在锁、许可清单和配方中绑定其哈希；不再使用此前来源链不明的 IINA DMG 副本。相关源码归档、许可证原文、固定构建脚本和构建选项仍保留。mpv 配置默认启用 `gpl=true`，故记录 GPL-2.0-or-later；libjpeg-turbo 关闭 TurboJPEG，仅按 libjpeg API 的 IJG 许可记录。
- 字幕字体栈的 `libfontconfig.1.dylib`、`libfreetype.6.dylib` 与 `libharfbuzz.0.dylib` 已完成固定源码归档、原文 notice、固定 IINA 构建脚本与 CI 发布二进制匹配核验。FreeType 配置显式禁用循环依赖的 HarfBuzz，关闭未使用的 PNG、Brotli 和 BZip2，并选用 FreeType License；HarfBuzz 在 FreeType 完成后启用该依赖。三项配方记录实际构建开关与组件哈希。
- `liblcms2.2.dylib` 已从 Little CMS 2.19 固定归档原样提取 MIT `LICENSE`，核对 IINA 的锁定构建脚本明确关闭未使用的 JPEG、TIFF 和 zlib 支持，并确认 arm64 二进制匹配成功 CI Release artifact。配方记录源码摘要、依赖选项及本地二进制哈希。
- `libmujs.dylib` 与 `libzimg.2.dylib` 已分别绑定 MuJS 1.3.9 ISC 和 zimg 3.0.6 WTFPL-2.0 原文、锁定构建脚本、源归档 SHA 及 arm64 Release artifact 内容。配方保留 MuJS 的按架构源码副本构建/只安装动态库，以及 zimg 从固定归档运行 `autogen.sh` 生成构建文件的行为。
- `libsoxr.0.dylib` 已绑定 SoX Resampler 0.1.3 的 LGPL-2.1-or-later 许可说明和完整 LGPL 文本；配方保留 CMake 关闭测试、示例、OpenMP 与 LSR bindings 的实际构建选择。`libuchardet.0.dylib` 已绑定 uchardet 0.0.8 Mozilla Public License 1.1 全文、来源摘要及禁用静态库的构建脚本。两个 arm64 库都与固定 CI Release artifact 内容匹配。
- `libarchive.13.dylib` 已核实 libarchive 3.8.8 固定源码、BSD-2-Clause 主许可、编入压缩过滤器所带的 UC Regents 额外版权条件，以及因禁用 libb2 而编译的参考 BLAKE2 代码。本次为 BLAKE2 选择 CC0-1.0，随包保留完整 CC0 文本、上游 COPYING 和编译源文件中的 UC Regents 头部。配方还记录禁用 OpenSSL、LibB2、LZO、BZip2、LibXML2、Expat，以及单独打包的 zlib/zstd/lz4；arm64 内容匹配固定 CI Release artifact。
- `libplacebo.360.dylib` 已固定 libplacebo 7.360.1 根提交和递归子模块闭包，绑定 IINA 固定构建脚本、OpenGL/Glad 生成代码、fast_float 头文件、LGPL/Apache/MIT 与 Khronos EGL 自定义许可原文，并核对其 arm64 Mach-O 内容匹配固定 CI Release artifact。Little CMS 是另一个单独打包的动态依赖；配方明确记录 Vulkan、demos、tests、shaderc 和 glslang 均关闭。
- JPEG XL 0.11.2 的顶层 commit 和 10 个递归子模块均已锁定，源码闭包使用规范化提交清单 SHA-256。构建脚本使用第三方 Brotli 子模块并生成三个共享 dylib，静态引入 Highway，关闭 SKCMS 后在 `libjxl_cms` 中静态编入 Little CMS；按实际组件分别保留 BSD-3-Clause、Apache-2.0 与 MIT 通知。三项 libjxl 和三项 Brotli arm64 内容都匹配固定 CI Release artifact，配方与逐项证据见 [`libjxl-build-recipe.json`](../../../ThirdParty/libjxl-build-recipe.json)。
- `ThirdParty/libmpv/IINA-LICENSE`、mpv/FFmpeg 的公开声明和 GRDB MIT 许可已保留一部分。它们没有覆盖所有 44 个二进制组件的逐项许可证及版权声明。
- 本仓库自行构建的 `libavformat.63.dylib` 已完成逐二进制证据链：FFmpeg 9.0.1 源码归档 SHA-256 与锁一致；TS 定位补丁、构建器脚本、configure 参数、Xcode/部署目标和输出哈希写入 [`FFmpeg-libavformat-build-recipe.json`](../../../ThirdParty/FFmpeg-libavformat-build-recipe.json)。两次独立保存的构建结果均为锁定输出哈希。随附 [`FFmpeg-libavformat-NOTICE.txt`](../../../ThirdParty/FFmpeg-libavformat-NOTICE.txt)，保留该源码包的 `LICENSE.md`、`COPYING.GPLv2` 和 `CREDITS`。构建配置含 `--enable-gpl`，因此按 FFmpeg 官方说明记录为 GPL-2.0-or-later；这项记录只说明该二进制的来源和许可，不代表 Bomu 整体发行兼容性已经审定。
- 另有六个 FFmpeg 9.0.1 库（`libavcodec`、`libavdevice`、`libavfilter`、`libavutil`、`libswresample`、`libswscale`）的 arm64 Mach-O 内容与 IINA 依赖构建提交 `f86d54276547df6d14104583ea604af67433f1e1` 成功 workflow 的 fat 发布包逐项匹配。该提交内 `versions.env` 锁定同一 FFmpeg 源码归档和 SHA-256，build workflow、源码 commit、成功 run、GitHub Release 附件哈希及六个本地锁定二进制哈希已组成可复核链。精确的上游文件快照及 Git blob SHA 保存在 `docs/engineering/distribution/iina-deps-buildscripts-f86d542-*`；逐库映射见 [`FFmpeg-upstream-build-recipe.json`](../../../ThirdParty/FFmpeg-upstream-build-recipe.json)。这六项与本仓库补丁版 `libavformat` 共用上游 FFmpeg GPL-2.0-or-later notice。
- `libdav1d.7.dylib` 也已绑定到版本化 CI 证据：IINA 构建提交的 `versions.env` 固定 dav1d 1.5.3 源码 SHA-256；本地 arm64 Mach-O 内容与该提交成功 run 的 Release 依赖包匹配。BSD-2-Clause `COPYING` 来自 VideoLAN `dav1d` 1.5.3 tag，已逐字节验证 Git blob SHA 并保存在 [`dav1d-COPYING.txt`](../../../ThirdParty/dav1d-COPYING.txt)；构建与二进制哈希关系见 [`dav1d-build-recipe.json`](../../../ThirdParty/dav1d-build-recipe.json)。
- `libunibreak.7.dylib` 的 7.0 源码归档 SHA、构建脚本和固定 IINA Release artifact 的 arm64 内容匹配已绑定；其上游 `LICENCE` 为自定义许可文本，不误标为标准 BSD。原文按 `LicenseRef-libunibreak` 保存并校验 Git blob SHA，构建关系见 [`libunibreak-build-recipe.json`](../../../ThirdParty/libunibreak-build-recipe.json)。
- `python3 scripts/license_audit.py check` 读取 `Config/ThirdPartyLicenses.json`，逐库核对依赖锁中的二进制哈希、许可证表达式、版权文本、NOTICE 哈希、源码版本/哈希与构建配方哈希；同时将构建配方中的验证状态、逐库二进制摘要和发布件匹配结论与清单交叉核对。清单不能单独把配方仍标记为未验证或明确不匹配的二进制升级为已验证，NOTICE 与配方路径必须位于仓库内且摘要有效。审计失败时会按证据字段聚合并列出受影响组件，未验证记录仍会逐项显示其缺少的材料，不以一个状态错误遮盖后续缺项。截至 2026-10-15，运行库逐项核验数为 44/44；Bomu 自有代码与项目文档使用 MIT，许可证文件哈希记录在同一清单中，项目和依赖来源审计均通过。GRDB 的 MIT 通知、来源 URL 与锁定 revision 已通过核对。这个审计只证明所列组件的许可证和来源材料完整，不裁定把 GPL/LGPL 运行库与应用一起分发所需的义务。

## 不能据此公开发布

当前 MIT 项目许可不把第三方二进制转为 MIT。SHA-256 能证明本机缓存与固定二进制一致，不能单独证明公开发行时的源代码提供方式、许可证告知与其它许可义务已经满足。FFmpeg 官方说明启用 GPL 部分会使 FFmpeg 适用 GPL；mpv 的版权说明也明确其许可随 GPL-only 代码和链接库而变化。逐项来源材料现已记录，但这里不作法律意见，也不代表打包分发兼容性或 GPL/LGPL 义务审查已经完成。

公开发行前必须审查全部实际加载组件的许可证义务，明确对应源代码/源码提供方式，核对补丁和构建配置，并确认应用与组合依赖的分发条件都得到满足。不能用通用 SBOM 或 Bomu 自身的 MIT 文件代替该审查。完成该门后才允许解除 `scripts/dependencies.py` 对 Release 的保护。

之后每次变更项目许可证、依赖哈希或 GRDB revision，都必须同步更新 `Config/ThirdPartyLicenses.json` 中绑定到该文件哈希、二进制哈希或 revision 的证据，并重新运行许可证审计。构建 Release 时同一检查由 `scripts/dependencies.py embed` 自动执行；人工改动 `distributionReady` 不能绕过不完整的许可证或来源审计。

之后还要用 Developer ID 签名、公证并在干净系统检查 Gatekeeper。当前这台开发 Mac 没有有效的代码签名身份，内部 DMG 使用 ad-hoc 签名，不能用于公证或浏览器下载验收。C12 官网下载与 C13 Sparkle feed 应使用经核验的发行包。

## 上游参考

- [IINA dependency build scripts](https://github.com/iina/deps-buildscripts)：构建分层与来源版本清单的说明。五个曾有差异的本地运行库已替换为固定 Release 附件原件；IINA 网站 endpoint 与镜像的历史比较记录仍保留在差异报告中，但不再作为本项目运行库来源。
- [IINA 1.5.0 专用依赖发布 tag 与 arm64 包](https://github.com/iina/deps-buildscripts/releases/tag/iina-1.5.0-release)：该归档和版本化站点文件的内容比较结果均见 [`iina-1.5.0-deps-comparison-2026-10-14.json`](iina-1.5.0-deps-comparison-2026-10-14.json)。这份报告记录替换前的比较：站点文件逐架构规范化后为 43/44，Release 包为 38/44；当前 Bomu 依赖以锁定 Release 文件替换了五项差异库。
- [IINA 1.5.0 依赖构建提交](https://github.com/iina/deps-buildscripts/commit/f86d54276547df6d14104583ea604af67433f1e1) 的 [`versions.env`](https://github.com/iina/deps-buildscripts/blob/f86d54276547df6d14104583ea604af67433f1e1/versions.env)：锁定 FFmpeg 9.0.1 与本仓库相同的源码归档 SHA，也列出了其他依赖版本与源码入口。对应的 [成功 CI 运行](https://github.com/iina/deps-buildscripts/actions/runs/35411161790) 的三份产物哈希与 Release 附件一致；但 workflow 没有将产物发布到版本化站点 endpoint。
- [IINA 1.5.0 `download_libs.sh`](https://github.com/iina/iina/blob/v1.5.0/other/download_libs.sh)：发布工程从独立 dylib 地址下载依赖，源码 tag 本身不固定二进制内容。
- [IINA 当前 universal dylib 文件清单](https://iina.io/dylibs/universal/filelist.txt)：核对当前运行库名称集合；作为动态地址，不作为版本或内容证明。
- [FFmpeg legal considerations](https://ffmpeg.org/legal.html)：FFmpeg 对 GPL 选项及源代码分发事项的说明。
- [mpv 0.41.0 copyright and license details](https://github.com/mpv-player/mpv/blob/v0.41.0/Copyright)：mpv 许可取决于构建中包含的代码和链接库。
