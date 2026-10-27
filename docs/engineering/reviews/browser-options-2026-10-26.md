# 浏览密度与递归扫描增量复核

2026-10-26，按 requirement-code-review 技能只读复核 R06 增量。范围为 AddMediaFolderPanel、MediaLibraryModel/Scanner/SyncCoordinator、PlaybackPreferences/Archive，以及 Library/Settings 密度调用方和新增行为测试。既有全量改动不在本次窄范围合并结论中。实现合同见[浏览密度与扫描范围](../../media-library/browsing/density-and-scan-scope.md)。

## 高风险问题

未在上述增量中发现新的确定高风险缺陷。扫描关闭递归时不再登记子目录；成功结束才核对该来源成员关系，取消/失败不清除既有索引。事实保留由真实临时目录/SQLite 模型测试覆盖，不能由 UI 看见文件来替代。

## 中低风险与验证缺口

紧凑四列在最小窗口、长文件名、未知/离线属性组合下的布局，以及新 Density 菜单的全键盘/VoiceOver 路径尚未完成完整验收。不能因单窗口切换成功宣称全三尺寸通过。新增主色遗漏已通过七处显式 foreground 修正；Search 有有限截图取样，其他标题仍待逐页确认。

## 架构与产品边界

密度由安装级 PlaybackPreferences 拥有，布局选择仍为页面会话状态。Library、Folders、Settings 使用同一密度事实；归档新增可选类型化枚举，旧归档缺省舒适，非法枚举在解码阶段拒绝。扫描范围沿用来源表字段，后台复扫读取它；UI 只提交 URL 和布尔选项，无新增数据库连接或后台常驻任务。Home/收藏/搜索的既有摘要布局不因紧凑偏好改变，该边界已在规格明确。

## 回归建议与证据

独立读取 `/tmp/bomu-browser-options-hostless.log`：233 项 XCTest、2 项存储专项按入口规则跳过、0 失败。新增测试覆盖密度跨实例/归档/旧数据缺省/非法枚举，以及非递归→递归→缩小→重新扩展后 ID、收藏、42 秒历史与源文件字节保留。SyncCoordinator 确实传递 root.includingSubfolders；面板取消路径未调用 addFolder。构建和静态分析日志成功，a9f3332e 规范包身份核验通过。真实窗口证据以伴随任务的[合同记录](../../media-library/browsing/density-and-scan-scope.md)为准，不能扩展到未执行状态。

## 结论

此次增量未发现必须追加的代码修复；可保留现有实现继续验收。完整 UI 矩阵、辅助使用、真实播放/内存门槛及其余大范围改动未由本次审查关闭，不能据此宣称整个分支或 v0.0 已完成。
