# 重播

重播是用户明确要求从当前曲目开头开始，必须覆盖全局“从上次位置继续”偏好。结束页按钮调用 `PlayerModel.replay()`；结束状态下的播放/暂停快捷意图也转为同一操作。模型以 `.beginning` 恢复意图重新打开当前 URL，沿用现有播放队列，不通过普通 `open` 重置队列，也不恢复历史位置。音量和曲目偏好仍照常恢复。

## 调用链

`PlayerScreen` 重播按钮 → `PlayerModel.replay()` → `openMedia(_:resumeMode: .beginning)` → `restoreAndOpen(_:)` → 加载后的首个快照只在有恢复位置时发出定位请求。

## 验证

`PlayerModelTests.testReplayStartsAtBeginningEvenWhenResumePreferenceIsEnabled` 预置 42 秒历史位置和双文件队列，先确认普通打开会应用续播位置，再模拟播放结束并触发重播，断言第二次播放不再请求该历史位置且队列内容/索引未变。该用例与全量逻辑测试在无应用宿主下执行；最新全量结果为 126 项 Python、79 项 XCTest，失败与跳过均为 0。
