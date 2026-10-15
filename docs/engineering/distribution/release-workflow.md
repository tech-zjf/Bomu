# macOS 发行流程

公开发行使用 `python3 scripts/release.py`。脚本首先要求 `Config/Dependencies.lock.json` 明确将依赖标记为可再分发，并通过 `scripts/license_audit.py`、工具链锁和运行库哈希检查；它也要求 Git 工作区干净，避免把未提交源码混进正式包。任一前置证据缺失时，命令会在构建前停止；不得手工把 `distributionReady` 改成 `true` 来绕过许可证/来源审计。

发行机需在 Keychain 安装 Apple Developer ID Application 证书，并预先用 `xcrun notarytool store-credentials` 建立 notarytool Keychain profile。把完整身份名或完整 40 位十六进制证书 SHA-1 放入 `BOMU_SIGNING_IDENTITY`，profile 名放入 `BOMU_NOTARY_PROFILE`；这两个值只是引用，不是秘密本身。脚本按完整名称或指纹与 `security find-identity` 返回的有效身份精确比对，不接受部分名称。也可用 `--identity` 与 `--notary-profile` 显式指定。`python3 scripts/release.py --preflight-only` 不会构建或提交公证，并会并列报告许可证审计、依赖锁的发行批准状态、锁定工具链/运行库验证、Developer ID 身份和缺失的 profile；profile 的实际有效性仍由首次真实提交验证。普通发行命令继续在首个失败的信任门停止。

通过前置检查后，脚本以 arm64 Release 配置构建，使用 hardened runtime。签名前先用与内部包相同的 Mach-O 闭包检查器验证实际 Release `.app`，再按由内向外顺序签署锁定的 dylib 与主 app。它将 app 打成临时 ZIP 提交公证；Apple 不支持直接给 ZIP 装订票据，因此脚本把票据装订并验证在 ZIP 内的 `.app` 上，再运行 Gatekeeper 执行评估。随后创建有 Applications 快捷入口的 UDZO DMG，对 DMG 签名、公证、装订票据并运行 Gatekeeper 打开评估及镜像校验。输出写入带时间戳的 `.build/distribution/releases/` 目录，包含已签名 app、DMG 与发行 JSON。记录绑定源码提交和工作区是否干净、依赖锁哈希、主可执行文件及每个嵌入 dylib 的 SHA-256、公证提交 ID 和 DMG SHA-256，便于把下载包追溯到构建输入和产物。失败时停止后续步骤，不覆盖既有发行目录。

脚本实现并不代表当前可公开发行：虽然逐项许可证与来源审计已通过，组合 GPL/LGPL 运行库的公开分发义务与源码提供方案仍待审查，`distributionReady` 仍为 false，且当前机器没有可用 Developer ID 身份与经过真实公证的包。上述条件都满足后才运行真实发行流程。凭据只保存在 Keychain，不写入仓库、命令参数或发行记录。

2026-10-15：预检从首个错误即退出改为逐项执行并汇总独立阻断，仍不允许发行路径越过不满足的信任门。Bomu 项目已选 MIT 并将许可证文件哈希写入审计清单；项目和组件证据审计通过。当前预检仍报告三项阻断：依赖锁尚未批准发行、没有有效 Developer ID Application 身份、未配置公证 profile。依赖批准须等组合 GPL/LGPL 运行库的发行义务和源码提供方式审查完成后再做。

该流程遵循 Apple 的 [macOS 公证说明](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[自定义公证工作流](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow) 与 [Mac 软件打包说明](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution)。
