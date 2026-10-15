# 媒体库辅助使用与搜索性能

## 界面访问方式

媒体库继续使用原生 `NavigationSplitView` / `NavigationStack`、`List`、`Button`、`Picker` 和 SwiftUI `.searchable`。媒体卡片的播放、收藏、观看状态与分类都有名称；目录、面包屑和密度控件沿用系统导航和分段选择器。网格/列表图标选项提供明确本地化名称，面包屑采用包含式辅助功能组以保留各层导航按钮。媒体卡片与文件列表共用辅助信息摘要，向主媒体按钮读出选中/观看状态、手工分类、续播位置、已探测技术信息及文件大小，网格卡片不再重复朗读静态详情。当前没有自定义界面动画。播放器状态面板与返回媒体库按钮读取系统“减少透明度”设置，启用后使用不透明表面。播放器控件订阅 macOS VoiceOver 状态；VoiceOver 开启时固定显示控件并保留辅助功能元素，关闭时恢复播放中闲置自动隐藏。该状态切换已编译并通过静态分析，实际 VoiceOver 导航与朗读仍需桌面走查。2026-10-15 屏幕 1 单窗口键盘走查确认正向 Tab 可依次到达侧栏及主内容控件，焦点环可见；从主滚动区的第一个按钮按 Shift+Tab 时焦点不返回侧栏，键盘验收未通过。`focusSection()` 与移除侧栏的 `.accessibilityElement(children: .contain)` 两个隔离实验均未改变结果，代码实验已撤回，根因仍待查。走查用的系统键盘导航偏好已恢复为关闭。减少动态效果/透明度的系统偏好实测、其余两种窗口尺寸和视觉对照也仍待完成。

## 万条索引搜索

XCTest `testDatabaseBackedTenThousandItemLibraryRefreshAndSearch` 在 10,000 条 SQLite 媒体索引记录上调用正式 `MediaLibraryModel.refresh()`，并验证搜索命中最后一条记录。2026-10-15，MacBook Pro / arm64 / macOS 26.7.1：将来源、媒体和目录读取合并进同一 SQLite 读事务后，包含查询、行映射和模型发布的刷新平均 177.1 ms（5 次）；已加载记录上的文件名过滤平均 7.08 ms（10 次）。XCTest 结果包：`.build/test-20261015-library-snapshot-final.xcresult`。

索引行通过单次测试事务批量写入，复用一次真实扫描建立的来源、卷和扫描记录；因此它测量的是持久化查询和模型刷新，不包含 10,000 个物理文件的扫描/元数据读取、缩略图解码、滚动帧率或十万级数据性能。界面搜索仍对已加载索引执行本地匹配。键盘反向跨滚动区、VoiceOver 朗读、减少动态效果/透明度和三种窗口尺寸仍需屏幕 1 单窗口走查，C10 尚未签结。

## 验证

2026-10-15：在屏幕 1 单一 Debug 窗口启用 macOS 键盘导航后，正向 Tab 依序到达 Library、Folders、Favorites、Search、来源、侧栏 Add Folder、Settings 和主内容 Add Folder，且焦点环可见。从主内容 Add Folder 按 Shift+Tab 时焦点保持原位；尝试将媒体库声明为 focus section、移除侧栏辅助功能容器后问题仍可复现，两个实验均已撤回。系统键盘导航开关随后确认恢复为关闭。反向跨区行为未修复，A02/C10 不得据此关闭。
2026-10-15：10k SQLite 刷新/搜索 XCTest 通过，最终快照实现下 5 次刷新均值 177.1 ms、10 次搜索均值 7.08 ms；无宿主逻辑测试与 Python 回归通过。窗口大小、VoiceOver、减少动态效果/透明度仍待屏幕 1 单窗口可见验收。
2026-10-15：为播放器控件增加 VoiceOver 启用时的常驻显示策略，并订阅辅助功能状态变化。Xcode 27 app build、app-host 测试目标编译与静态分析通过，132 项 Python / 91 项 XCTest 通过（失败/跳过均为 0）。内部 DMG 重建后 `hdiutil verify` 有效，44 个 dylib / 47 个 Mach-O 闭包通过，SHA-256 `c9845b064c1517d93a3219afb57c91ffb914779ebd715ca11fd239037fdac0d1`。桌面当前锁定；实际 VoiceOver 开关、朗读和控件聚焦未运行，三种窗口尺寸及显示辅助选项也仍待单窗口走查。
2026-10-15：网格卡片和文件列表现在共用辅助信息摘要，避免卡片重复朗读文件名，并补充观看状态、手工分类、续播位置、探测到的媒体详情与文件大小。Xcode 27 app build、静态分析、app-host 测试目标编译及 132 项 Python / 91 项 XCTest 通过（失败/跳过均为 0）；当前内部 DMG 通过镜像与 44 dylib / 47 Mach-O 闭包校验，SHA-256 `e24daff2c3469e49cafbb9a3e79fc663e39c881c74aea87df7b70d4493f01af1`。详情朗读顺序和截断效果仍需要可见 VoiceOver 验收。
2026-10-15：将媒体库 VoiceOver 摘要移入 `MediaLibraryAccessibilitySummary.swift`，共享技术属性文本独立放入 Foundation-only `MediaTechnicalMetadataText.swift`；SwiftUI presentation 层现在只负责展示。新增 hostless XCTest 验证已选中/已看/分类、探测到的媒体信息、音轨编码去重和文件大小；本地化秒数的键与占位符仍由双语目录契约测试验证。Xcode 27 全量回归通过 132 项 Python、92 项 XCTest（失败与跳过均为 0），静态分析和 app-host 测试目标编译通过。C10 的 VoiceOver 真实朗读、键盘与三种窗口尺寸仍需解锁后在屏幕 1 单窗口验收。
最终拆分后的 Xcode 27 静态分析、app-host 测试目标编译及内部包校验全部通过；DMG SHA-256：`84118d721e0daa5e235f54e3430f65d614967aee24080f84a6617268b5bf51bd`。
