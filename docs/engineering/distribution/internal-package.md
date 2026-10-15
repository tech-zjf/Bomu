# 内部开发安装包

使用 `./scripts/package-internal-dev.sh` 生成 `.build/distribution/internal/Bomu-<版本>-internal-arm64.dmg`。流程先执行锁定工具链和依赖校验，再构建 Debug app、复制到暂存目录、核对 arm64 下每个 Mach-O 的动态库闭包、对 app 做 ad-hoc 签名，最后生成并校验只读压缩 DMG。包内带 44 个依赖锁定的 dylib，运行时依赖全部解析到 app 内或 macOS 系统库。

这条路径用于内部开发者安装和依赖闭包检查，不是公开发行包。它没有 Developer ID 签名、公证、自动更新、干净系统运行记录或其他 Mac 上的安装证据；Gatekeeper 下载验收需要后续 C11。当前已在生成的 DMG 上验证镜像校验和、arm64 动态库闭包、app 代码签名结构和 `Info.plist`。

2026-10-15 在五个运行库切换到固定 IINA Release 附件后，使用锁定 Xcode 27.0 / Swift 6.4 重建 `Bomu-0.0.1-internal-arm64.dmg`。`hdiutil verify` 通过，DMG SHA-256 为 `79b27e58fc3b899ffd431565d1317880fc5f74d9df28544312c24c3692dc6a1b`。打包前依赖哈希检查通过；只读挂载最终镜像后，44 个锁定 dylib 与 47 个 Mach-O 依赖闭包检查通过，ad-hoc 签名验证通过。签名后的 Mach-O 文件包含新增签名数据，不能直接用未签名锁定文件的原始 SHA 比对；打包脚本先验证原始二进制哈希，再执行签名。本机验证仍不代表另一台无 Homebrew Mac 的安装启动验收。

2026-10-15 在原生关闭路径补齐 CGL context 与 pixel format 释放后重建内部包。Debug build、44 个锁定 dylib / 47 个 Mach-O 依赖闭包、ad-hoc 签名验证和 `hdiutil verify` 均通过；最新 DMG SHA-256 为 `32f97932ecce7599793ad0068b37bc77e01a245d731242f826cc2e160f9bc366`。真实 app-host 原生测试 10/10 已通过。跨 Mac 安装启动仍未验证。

2026-10-15 修复并发 shutdown 可能重复关闭播放内核的问题后重建内部包。锁定工具链、44 个 dylib / 47 个 Mach-O 依赖闭包、ad-hoc 签名和 `hdiutil verify` 均通过；最新 DMG SHA-256 为 `3b99ff6efc75d1b434ed98e8377dfbf570ae9cbac33cdb92a7f8d063be62029b`。app-host 原生测试仍为 10/10 通过，跨 Mac 安装启动尚未验证。

2026-10-15 修复测试与产品构建共用 DerivedData 的污染问题后，重新执行完整内部打包脚本。普通 app 维持在 `.build/DerivedData`，测试构建进入独立目录；最新 DMG 的 44 个 dylib / 47 个 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify` 均通过，SHA-256 为 `56d2269fcbfb3c18f06bb12df029ca97deaa5001160e7a160edf76ada3678899`。这轮没有启动 app-host 测试或播放器窗口；跨 Mac 安装启动仍未验证。

2026-10-15 加入“重播始终从头开始”行为后重新打包，确保 DMG 与当前源码一致。内部打包脚本再次完成 Debug 构建、44 dylib / 47 Mach-O 闭包、ad-hoc 签名和 DMG 镜像校验；最新 SHA-256 为 `4249179015be28787443ad037787425cf122d691fc8ed7e2cbe48e9e2cd89b68`。跨 Mac 安装启动仍未验证。

2026-10-15 将数据库启动故障与播放器启动解耦后重建内部包。数据库不可用时显示媒体库故障状态并保留单文件打开入口，仍允许播放器引擎独立启动。Debug build、44 dylib / 47 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify` 均通过；最新 DMG SHA-256 为 `317f442cece9edc7f57ed9be9b19eae564da09639039ce4bcd2250b0c5533534`。当前包没有跨 Mac 安装启动验收。

2026-10-15 禁用媒体库不可用时的文件夹入库操作后重新生成包。完整内部包脚本通过，44 dylib / 47 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify` 均通过；最新 DMG SHA-256 为 `0bd7b4c734dcb7611931cf020a1e2749dd8f7ed10ba7c0a76c0de3a26274fbbc`。跨 Mac 安装启动仍未验证。

2026-10-15 修复 CAOpenGLLayer 回调与 renderer teardown 对 CGL context 的无锁竞态后重新构建。Debug app 与 app-host test target 均编译通过；44 dylib / 47 Mach-O 闭包、ad-hoc 签名及 DMG 镜像校验通过。字幕同步菜单随后加入当前偏移显示和归零动作，完整测试后再生成最新内部包，SHA-256 为 `873ec24c7c6b24656bb5b60ab0dbd25e9d0e53a9f878c643aed406163b237486`。迟到 Core Animation 回调与 shutdown 交错的实际宿主测试仍待解锁后运行。
2026-10-15 媒体库文件夹列表新增真实媒体属性摘要，并与卡片共用同一格式化实现；列表媒体按钮的辅助功能值也读出该摘要。最新版 Debug app 与 app-host target 编译通过，完整 hostless 回归为 126 项 Python / 79 项 XCTest；44 dylib / 47 Mach-O 闭包、ad-hoc 签名和 DMG 镜像校验通过。最新 SHA-256 为 `5b9005372e57baa8de0db189f39709e05cc80ee2b251982eda0db218cf7e06f0`。另一台 Mac 安装验收仍待执行。
2026-10-15 C10 大库路径再增加元数据缓存上限：最多 2,048 条，以最近访问排序淘汰。LRU 行为用缓存容量 2 和替换源文件验证；完整 hostless 回归 126 项 Python、80 项 XCTest 全通过，失败与跳过均为 0，Debug app 与 app-host test target 编译通过。内部 DMG 的 44 dylib / 47 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify` 通过，最新 SHA-256 为 `dcb3c56fe064b8599f6a05568196acd2cee6f5c25b5c2bb382b13abffad51974`。

2026-10-15 C02/C03 渐进扫描验收与 C04 缓存符号链接保护完成后，重新生成当前源码对应的内部 DMG。Debug build、44 个锁定 dylib / 47 个 Mach-O 闭包、ad-hoc 签名与 `hdiutil verify` 均通过；全量回归为 126 项 Python、84 项 XCTest，失败/跳过均为 0。最新 SHA-256：`8f42546c6a5ebe090d6dcefd9f480cb8c5f641ba1cc07296681a2e3d0ed29c4d`。桌面锁定期间未做播放器可见验收；DMG 仍是内部开发包，不含公证或跨机安装证据。

2026-10-15 将媒体库主导航、缩略图卡片、文件列表行与共享属性摘要拆分到职责明确的 SwiftUI 文件后，重新构建当前源码 DMG。Debug app 和 app-host test target 编译通过；全量回归 126 项 Python / 84 项 XCTest 通过；44 dylib / 47 Mach-O 运行时闭包、ad-hoc 签名和镜像校验通过。最新 SHA-256：`b7b44c7f87a57b4927051739859ef3d87d312f45b2ba87097df255ca3c1d1ec3`。可见 UI 验收仍待屏幕 1 单窗口进行。

2026-10-15 补入移动媒体后重新加载卡片缩略图与列表属性的路径变更任务身份后，重新构建当前源码 DMG。Xcode 27 Debug 构建、44 dylib / 47 Mach-O 依赖闭包、ad-hoc 签名和镜像校验通过；最新 SHA-256：`c1e656193f855fb6c64e0d515b6ca1f92b79a5b2b1d01f330cf862a2f696008f`。文件移动 UI 的实时刷新仍待屏幕 1 单窗口验收。

2026-10-15 将来源列表滚动状态与子目录状态隔离后重建当前源码 DMG。Xcode 27 Debug 构建、44 dylib / 47 Mach-O 依赖闭包、ad-hoc 签名和镜像校验通过；最新 SHA-256：`9fedbf9c5f004d0965c302506316a74b1166ab6fb42f4cf91a0f9ada43b749c4`。实际侧栏切换和滚动恢复仍需屏幕 1 单窗口走查。


安装时在 Finder 中将 Bomu 拖到 Applications。卸载时退出 Bomu 后移除应用；用户数据库与媒体文件不在 DMG 内。测试素材、源码和依赖缓存仍由 `.gitignore` 排除。

`scripts/package_internal.py` 独立检查 `@rpath`、`@loader_path`、`@executable_path` 依赖是否落在 bundle，且只允许链接 macOS 系统库作为外部依赖。`@rpath` 只按当前 Mach-O 和主可执行文件实际声明的 `LC_RPATH` 搜索，不把 Frameworks 目录当作隐式搜索路径。检查会解析符号链接的最终目标，锁定的每个 dylib 和每项内部依赖都必须实际位于 `.app/Contents` 中，避免包外链接伪装成已随包携带。架构从 `ARCHS=arm64` 得出；该脚本不会接受 x86_64 切片替代，也不把 ad-hoc 签名描述成发布签名。

2026-10-15 复查发现，旧检查器会在没有匹配 `LC_RPATH` 时额外尝试 `Contents/Frameworks` 和 `Contents/MacOS`，可能把无效的 `@rpath` 依赖误报为闭包通过。现在删除隐式路径回退，并增加缺少运行路径时拒绝、由主程序运行路径正确解析时接受的行为测试。修正后，锁定构建中的 44 个 dylib / 47 个 Mach-O 镜像闭包检查通过。

2026-10-15 媒体库复查修复快速更换来源目录后已取消的扫描仍可能开始，以及跨来源去重被失效成员遮挡的问题。当前源码的 Debug build、44 dylib / 47 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify` 均通过；完整无宿主回归为 128 项 Python / 86 项 XCTest，app-host test target 只编译、没有在锁屏桌面启动。最新内部 DMG SHA-256：`d2e3d2de3de0883f4a5a7efe8c63819ed4495a7ad846d3eab317db74465169ca`。

2026-10-15 为本地文件身份补入有界 SHA-256 内容采样和 schema migration，并将媒体库归档升级至 v2（保留 v1 导入）。相同 inode/大小和原始纳秒 mtime 的文件改写回归通过；全量回归 128 项 Python / 88 项 XCTest 均通过，Debug app 与 app-host test target 编译成功。当前内部包运行闭包 44 个 dylib / 47 个 Mach-O、ad-hoc 签名和 `hdiutil verify` 均通过；最新 SHA-256 `f3d4c72bdd9a222ae6711c0fa461c234591401bc048e6df7381e6d1528f9ff0d`。随后将内容替换语义完善为创建新的媒体行身份，清除旧进度与媒体偏好并保留来源成员关系；新增 identity rollover 和归档 fingerprint 格式回归后，最终全量回归通过 128 项 Python / 90 项 XCTest（0 失败、0 跳过），Debug app、app-host target 和 DMG 均按最终源码重新构建。本轮仅编译 app-host 测试目标，没有启动播放器。


2026-10-15 将媒体库快照刷新纳入播放返回/停止路径，避免文件内容身份 rollover 后的旧行 ID 留在浏览界面；刷新失败会保留待重试标记。刷新结果契约新增成功/失败断言后，完整回归 128 项 Python / 91 项 XCTest 全通过（失败与跳过均为 0）。随后修复静态分析发现的 `CAOpenGLLayer` 非空 CGL 回调边界，零诊断静态分析、app-host target 编译和全量回归均通过。最新内部 DMG SHA-256：`c35f7d0ab60f86a0183976063a183a5af246c7fa17b3e8704bd3f42a89391c02`；44 个锁定 dylib / 47 个 Mach-O 闭包、ad-hoc 签名与 `hdiutil verify` 均通过。此次未启动播放器或 app-host 测试。


2026-10-15 补齐设置确认框缺失的中英文取消键，并加入中英文资源键集合和 Swift 静态引用完整性检查。完整回归 130 项 Python / 91 项 XCTest 通过，失败与跳过均为 0；app-host target 编译通过。最新内部 DMG SHA-256：`cc03571f9a78825bd0219f550523a2152b5ba1241505baf2d7f04d4070ac66d4`；44 个锁定 dylib / 47 个 Mach-O 闭包、ad-hoc 签名及 `hdiutil verify` 均通过。

2026-10-15 将媒体已播放秒数与扫描进度改为显式本地化格式化后重新构建当前源码包。随后扩充中英文格式占位符一致性检查；最终 132 项 Python、91 项 XCTest 通过（0 失败、0 跳过），app-host target 编译通过；staging 的本地化格式资源、44 dylib / 47 Mach-O 闭包、ad-hoc 签名与 `hdiutil verify` 均通过。最新 DMG SHA-256：`0b0cc35889e91c02e91413f1e42f2e2b7e8421bd7ae12eb5318d4e3d6fed0510`。此为内部开发包，未执行桌面视觉验收或跨 Mac 安装验收。

2026-10-15 为播放器控件加入 VoiceOver 状态跟随后重新生成内部包。全量回归 132 项 Python / 91 项 XCTest、app-host target 编译、静态分析、44 dylib / 47 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify` 均通过。最新 DMG SHA-256：`c9845b064c1517d93a3219afb57c91ffb914779ebd715ca11fd239037fdac0d1`。桌面锁定，VoiceOver 实际操作与跨 Mac 安装仍未验收。

2026-10-15 媒体库网格/列表改为共用完整辅助功能摘要后，Xcode 27 app build、app-host target 编译、静态分析、132 项 Python / 91 项 XCTest 和 DMG 验证均通过；44 dylib / 47 Mach-O 闭包完整。最新 SHA-256：`e24daff2c3469e49cafbb9a3e79fc663e39c881c74aea87df7b70d4493f01af1`。VoiceOver 实际朗读顺序与卡片操作仍待单窗口可见验收。

2026-10-15 将媒体库辅助功能摘要与共享技术属性格式化拆分为职责独立的源文件并加入 hostless 行为回归后，按当前源码重建内部 DMG。Xcode 27 静态分析、全量回归（132 项 Python / 92 项 XCTest，零失败与跳过）及 app-host 测试目标编译通过；打包核验 44 个锁定 dylib / 47 个 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify` 均通过。最新 SHA-256：`84118d721e0daa5e235f54e3430f65d614967aee24080f84a6617268b5bf51bd`。这是内部开发包，未含 Developer ID/公证或跨机启动证据。


2026-10-15 将媒体库来源/离线提示、目录卡片与行、面包屑等值视图移入独立 `MediaLibraryFolderViews.swift`，导航路径、密度和滚动状态继续由页面持有。Xcode 27 app build 与静态分析通过；重新生成的内部 DMG 通过 44 dylib / 47 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify`，SHA-256：`348dc59be3441d7f6cd74d7b544373f65f56197be9b9b30ff7ad96f7116a416c`。文件夹交互仍需屏幕 1 单窗口可见验收。

2026-10-15 将目录面包屑祖先路径规则移入 `MediaLibraryDirectory` 值模型，并加入根目录、嵌套目录、相似前缀路径和错误来源根的行为测试。复查真实导航链路后修复父级面包屑少退一层的问题：现在按目录身份从当前导航路径截取前缀。Xcode 27 静态分析及 app-host 测试目标编译通过；132 项 Python 回归通过，其中许可审计、打包闭包和 Release 门专项为 50 项。Xcode 的测试 action 在锁屏时未能启动 worker；单独编译最新无宿主 XCTest bundle 后直接运行，94/94 通过（含本次面包屑回归）。按当前源码重建的内部 DMG 通过 44 dylib / 47 Mach-O 闭包、ad-hoc 签名和镜像校验，SHA-256：`ec2a822000b82856fd04be7589d35fb3b37d0cdb50ef007d1f08b2c8b2cebe9d`。app-host 仍未运行，可见交互仍待同一窗口验收。

2026-10-15 对当前源码新建独立 DerivedData 执行 arm64 Debug 构建，工具链/依赖锁检查、Xcode 静态分析和全量无宿主回归（134 项 Python、95 项 XCTest，零失败/跳过）通过。重新打包后，44 个锁定 dylib / 47 个 Mach-O 闭包、ad-hoc 签名和 `hdiutil verify` 通过，DMG SHA-256 为 `6ee27ee1a3424d48c55f3c6d2a61ee89d63f8731d06e49ac702625119418bf77`。在屏幕 1 单一 Bomu 窗口中从只读挂载的 DMG 启动，成功显示媒体库首页并正常退出。该机启动证据不能替代“没有 Homebrew 的测试 Mac”验收，B12 仍进行中。

2026-10-15 移除空状态整块底板和文件夹列表外框，并将首页布局间距对齐到当前 token 后重建包。Xcode 27 静态分析通过；完整 hostless 回归 134 项 Python、96 项 XCTest 通过；44 个锁定 dylib / 47 个 Mach-O 闭包、ad-hoc 签名与 `hdiutil verify` 均通过。DMG SHA-256：`4fae51b636dc8a1eece99606dd3737df70c7d4004dd1fbdb9f89ca357d8881d4`。本轮没有完成可见 UI 对照或跨 Mac 安装启动验收。

2026-10-15 按最新 UI 圆角 token 再次重建内部包。`./scripts/package-internal-dev.sh` 的 Xcode 27 Debug build、44 个锁定 dylib / 47 个 Mach-O 依赖闭包、ad-hoc 签名及 `hdiutil verify` 通过；只读挂载 DMG 后再次检查依赖闭包与 `codesign --verify --deep --strict`，均通过。DMG SHA-256：`c9ac97c5faea402acbc16a52f9f53b131a74debd93d92bf873a7186bcd21511f`。未在无 Homebrew 的另一台 Mac 安装启动，B12 仍未完成。

2026-10-15 将媒体库导航标题传递为 SwiftUI 本地化键后，重新构建当前源码内部包。锁定工具链校验、44 个 dylib / 47 个 Mach-O 依赖闭包、ad-hoc 签名验证和 `hdiutil verify` 均通过；DMG SHA-256：`15a81159fbaba04d054cdb516b21d41d74ce3e99a36c103c9d00ab17089946e0`。随后将最终 DMG 只读挂载，重查依赖闭包、`codesign --verify --deep --strict` 和 `CFBundleLocalizations = ["en"]`，全部通过。跨 Mac 安装启动仍未验证。
