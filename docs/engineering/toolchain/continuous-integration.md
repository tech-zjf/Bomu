# macOS 持续集成

`.github/workflows/macos-ci.yml` 为 push、pull request 和手动运行提供单一 arm64 macOS job。它固定选择 GitHub-hosted `xcode-27` 镜像中的 Xcode 27.0，并由 `scripts/toolchain.py` 再次核对 Xcode build、Swift 编译器与 SDK，避免 runner 标签变化静默升级工具链。

Job 安装合成媒体生成需要的 FFmpeg，运行 `scripts/dependencies.py bootstrap` 从哈希锁定的 IINA DMG 和 FFmpeg 9.0.1 源码准备 44 个运行库，再执行仓库现有 Python/无宿主 Swift 回归、Debug 应用构建、Xcode 静态分析、实际 `.app` 的 dylib 闭包检查，并编译 app-host 原生播放集成测试 target。共用的 `scripts/prepare-test-media.py` 在测试运行或 `build-dev.sh --for-testing` 时检查并生成缺失的基础合成样本与 60 项 B11 suite，再验证 manifest 和素材哈希；因此直接编译 app-host target 或在干净 CI 中构建，不依赖此前有人运行过测试来留下 `.build` 素材。无宿主测试写入 `.build/DerivedData-Tests`，app-host 编译写入 `.build/DerivedData-ForTesting`，可打包的 Debug app 保留在 `.build/DerivedData`；这样测试插件不会污染闭包检查与内部打包所用的产品。闭包检查逐一解析构建产物中的 47 个 Mach-O 镜像，防止仅凭源文件可编译就遗漏运行库或包外链接。集成测试只执行 `build-for-testing`，不启动需要桌面可见性的播放器；长时播放测试也不在 CI 运行。CI 不签名、不公证、不创建发行物，也不请求写仓库的权限。依赖在每个全新 runner 上重建；后续只有在测得构建时间后，才考虑针对锁定输入增加缓存。

所有外部 Action 均固定到完整 commit SHA；checkout 不持久化 Git 凭据。Workflow 使用 `contents: read` 最小权限并按分支取消过期运行。`xcode-27` 镜像当前仍是 GitHub 标注的 public preview，runner 本身可能更新；锁定检查会在镜像不再含精确工具链时失败，而不是用较新 Xcode 继续构建。

当前只在本地验证了 YAML 结构、脚本语法及同一组本机构建/测试命令，包括 Xcode 静态分析和 app-host 集成测试 target 编译；GitHub-hosted workflow 尚未运行，需首次 push 或手动 workflow dispatch 才能取得远端执行证据。

## 锁屏时本机逻辑测试

本机若处于锁屏状态，Xcode `test` action 可能等待无法启动的 XCTest worker。`scripts/test-dev.sh --direct-hostless` 提供等价的 hostless 验证入口：先运行同一组 Python 回归，再通过 `build-for-testing` 编译 `BomuLogicTests`，最后用 `xcrun xctest` 执行完整逻辑测试 bundle；不启动 app 或原生播放器窗口。该模式不接受测试过滤参数；需要选择用例时使用默认 Xcode test action。CI 继续采用默认 action，以保留标准 XCTest 结果记录。

2026-10-15 在屏幕锁定状态下执行 `./scripts/test-dev.sh --direct-hostless`：132 项 Python 与 94 项 XCTest 全部通过。另验证 Bash 语法，并确认该模式拒绝组合 native 参数或 XCTest 过滤参数。
