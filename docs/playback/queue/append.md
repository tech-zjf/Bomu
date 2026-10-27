# 追加播放队列

R01/B06 原有 Open 替换队列语义保持；新增 File → Add to Queue…（Cmd-Shift-O）及播放器队列菜单的同名入口。系统文件面板可选择多个文件或文件夹。没有活动请求时追加后开始播放；已有请求时保持文件、位置、暂停状态和渲染会话。

## 顺序与并发合同

`OpenMediaPanel → PlayerModel.appendToQueue → beginInputResolution(.append) → MediaFileDiscovery.expand → PlaybackQueue.append`。

`PlaybackQueue` 将新批次按原有自然排序规则排列，按标准化路径去重，再加入已有队列末尾；不重排已有项目，也不改变当前索引。直接文件与递归目录展开继续使用同一个发现器；发现失败不提交部分结果，不打断当前播放。

输入事务携带 replace/append 意图和 revision。更晚的打开、手工选择队列项、停止、退出会取消旧解析任务并阻止晚结果提交。每轮仍由 PlayerModel 持有任务；不创建额外内核或视频窗口。

## 验证

2026-10-26：新增队列批次排序/标准化去重/保留选择、空队列、追加不换请求、旧输入拒绝、失败不动当前队列的行为测试。与暂停保存及完成策略合并后的无宿主回归为 221 项 XCTest（219 通过、2 项显式 APFS 跳过）、167 项 Python 通过。

真实内核 15/15 通过。新增检查在暂停的第 6 秒追加另一许可 fixture，确认保留 request ID、暂停和位置，保持单一 core/render context，退出释放资源。菜单和快捷键可见检查由协调中的 UI 任务在最终规范包上执行，不用入口存在代替内核语义测试。
