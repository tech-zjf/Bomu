# Debug 构建身份

`./scripts/build-dev.sh` 在调用 Xcode 前，由 `scripts/build_identity.py capture` 记录工程输入的逐文件 SHA-256。Xcode 成功后，`finalize` 重新读取同一输入集合；任何新增、删除或内容变化都使构建命令失败，不为该包生成身份收据。成功时读取规范 Debug `Bomu.app` 的 Info.plist、可执行文件与全部包内文件，写入同目录的 `Bomu.build-identity.json`。收据包含源码摘要、各输入哈希、应用版本/Build、语言资源列表、包文件哈希与包摘要。构建前清理旧收据，避免失败后误用旧证明。

```mermaid
sequenceDiagram
    participant Script as build-dev.sh
    participant Identity as build_identity.py
    participant Xcode as xcodebuild
    Script->>Identity: capture 当前输入
    Script->>Xcode: Bomu Debug build
    Xcode-->>Script: 构建成功
    Script->>Identity: finalize 同一输入 + Bomu.app
    Identity->>Identity: 比对前后输入 / 摘要包内文件
    Identity-->>Script: Bomu.build-identity.json
```

输入覆盖 `Sources`、`Config`、工程文件、构建脚本、基准工具源码、SwiftPM `Package.resolved` 与依赖锁；忽略 `.build` 输出、测试日志与文档。收据是本地 Debug 验收的追溯材料，不替代签名、公证、供应链证明或发布包验证。`--analyze` 与 `--for-testing` 不生成规范应用收据。未来可见 UI 验收在启动前执行：

```sh
python3 scripts/build_identity.py verify --receipt .build/DerivedData/Build/Products/Debug/Bomu.build-identity.json
```

命令比对当前源码、规范 Debug 包内全部文件、版本和语言资源；其中任何一项变化都要重新构建并取得新收据。随后从收据记录的规范路径启动包，仍需按单窗口约束做可见检查。

`Tests/test_build_identity.py` 验证源码在构建途中改变时拒绝生成、应用字节改变时包摘要随之改变，以及缺少声明可执行文件时明确失败。实际收据中的哈希和本轮构建结果记录在 [当前进度](../roadmap/progress.md)；锁屏期间不据此宣称 UI 已验收。
