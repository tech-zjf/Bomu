# 工具链升级调用链

本图对应用户授权的 Xcode 27 升级、实际构建和回归。正式运行库缓存保持原始固定版本；候选库只存在于独立实验及应用中。

## 版本固定、构建与单窗口验证

从用户选定新版工具链开始，经过版本与构建参数校验、真实测试和独立候选应用运行，最终归档成功或失败证据。程序日志与用户实际观感分别记录。

```mermaid
sequenceDiagram
    participant User as 用户
    participant Dev as 开发者
    participant Lock as Dependencies.lock.json
    participant Check as toolchain.py
    participant Build as build-dev.sh / test-dev.sh
    participant Host as Bomu / MPVIntegrationTests
    participant Candidate as verify-seek-candidate.py / verify-seek-lifecycle.py
    participant Prepare as prepare-seek-candidate-app.py
    participant Window as WindowLifecycleBenchmark
    participant Evidence as 本地原始报告与归档 JSON
    User->>Dev: 选择 Xcode 27.0 并要求完整回归
    Dev->>Check: 读取已选工具链
    Check->>Check: 读取 Xcode / Swift / SDK 实际版本与 build
    Check-->>Dev: 返回实测版本
    Dev->>Lock: 更新工具链字段，保留运行库与头文件身份
    Build->>Check: 脚本入口及各 target 检查实际构建参数
    alt 版本或构建设置不匹配
        Check-->>Build: 明确失败，不自动放宽约束
    else 全部匹配
        Build->>Build: 构建正式应用、运行 Python 与无宿主 Swift 测试
        Build->>Host: 执行全部 5 项真实内核测试
        Host->>Host: 借用唯一窗口内容，保持屏幕，释放 engine 后恢复原视图
        Host-->>Evidence: XCTest 结果与窗口身份
    end
    Candidate->>Check: 再次验证新工具链与固定依赖
    Candidate->>Candidate: 重编未修改版本和候选；清单、9 组对照与交错回归
    Candidate-->>Evidence: 原版缺陷对照、候选结果、源码与运行库 SHA
    Prepare->>Candidate: 核验新的成功实验及依赖锁身份
    Prepare->>Prepare: 构建独立应用，替换候选库、临时签名、保留 receipt
    Prepare-->>Dev: 经身份核验的应用及 receipt，尚未启动
    Dev->>Window: 按 invocation.py 的参数启动应用，指定初始 display ID
    Window->>Window: 在指定屏幕创建一个窗口，执行矩阵与生命周期检查
    Window-->>Evidence: 完成或失败状态、同屏/可见性、新帧、停止与释放记录
    Evidence-->>User: 自动回归结论；人工画面、听感与物理同步仍待独立确认
```

- 无效或不可用的指定屏幕在创建窗口前失败；窗口创建后不靠搬动、循环置前或删除断言满足要求。
- 原生 XCTest 和候选可见基准先后执行，每次一个窗口。只有无窗口的后台对照可以并行执行。
- 旧构建、旧依赖锁哈希及旧验收报告保留；新的成功结果有新的目录与校验记录，不修改历史产物。
- `prepare-seek-candidate-app.py` 只准备应用，实际启动由独立运行记录中的 `invocation.py` 执行。准备成功本身不代表播放通过。
