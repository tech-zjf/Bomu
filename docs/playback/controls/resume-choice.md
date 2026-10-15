# 媒体库续播选择

## 交互

媒体库卡片和文件夹列表的上下文菜单在存在已保存进度时显示“从上次位置继续”，并始终显示“从头播放”。卡片主播放按钮、Finder 和打开面板继续遵守全局“从上次位置继续”偏好。这样一次性播放选择不会偷偷修改全局设置。

## 状态与调用链

`MediaLibraryView` 把三个明确动作交给 `MainWindowView`：默认播放、继续、从头播放。后两者调用 `PlayerModel.continuePlayback(_:)` / `playFromBeginning(_:)`，并进入同一个 `openMedia` 生命周期。`ResumeMode` 仅控制本次请求是否应用保存位置；已保存的音轨和音量仍按播放器规则恢复。打开新请求、准备期切换和旧读取取消继续以 request ID 与任务取消保护，不重建主播放器或切换音频会话。

失败后重试仍使用该请求保存的 `ResumeMode`，不会重新读取全局偏好覆盖用户刚选择的动作。

底部当前播放栏仍指向同一个播放器实例，暂停按钮控制当前会话，显示播放器按钮切换同一主窗口的内容层。

## 验证

`PlayerModelTests.testExplicitContinueAndStartFromBeginningOverrideResumePreference` 将全局续播关闭，验证显式“继续”仍定位到 42 秒，而“从头播放”不发送恢复定位；`testRetryPreservesExplicitContinueChoiceWhenGlobalResumeIsDisabled` 验证失败重试继续保留同一选择。播放页与媒体库往返时的真实声音连续性待屏幕 1 单窗口可见验收。
