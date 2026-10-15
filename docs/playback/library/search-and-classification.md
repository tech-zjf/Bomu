# 搜索、收藏、观看状态与手工分类

## 数据模型

收藏、已看和手工分类属于 `media_file_preferences`，通过媒体文件稳定 ID 关联；播放进度仍属于 `playback_history`。分类字段由独立 GRDB migration 添加，并限制为 `movie`、`series`、`personal` 或 `NULL`。NULL 表示用户尚未分类，读取时不会根据文件名猜类型，也不会替换原始文件名。

`PlaybackHistoryStore.libraryItems(in:)` 将偏好映射为 `MediaLibraryItem`。`MediaLibraryModel` 提供本机已索引记录的搜索结果；库页和搜索页可以按观看状态及分类筛选。媒体卡片上下文菜单可切换收藏、切换已看、设定分类或清除分类。所有写入只更新数据库，不触碰来源媒体。

## 搜索规模

当前已索引列表在内存中按文件名执行 `localizedStandardContains`，十万级及以上性能尚未承诺。1 万条回归用例验证搜索能找到最后一条记录；C10 会在目标 Mac 上补充耗时与交互测量，再决定是否将查询下推到 SQLite。UI 的文本变更由 SwiftUI searchable 绑定驱动，不额外持有重复查询副本。

## 验证

- `PlaybackHistoryStoreTests.testLibraryPreferencesAndPlaybackPositionPersistForIndexedItems` 验证收藏/已看可撤销、分类可持久化并可清除。
- `PlaybackHistoryStoreTests.testConcurrentFavoriteAndWatchedTogglesApplyEveryClick` 并发提交双切换，验证每次点击都在 SQLite 当前值上生效且最终回到原状态；界面不再用可能过期的列表快照计算写入值。
- `MediaLibraryScannerTests.testSearchFindsLastMatchInTenThousandIndexedItems` 验证一万条规模下末尾记录可命中。
- Xcode 27.0 回归复跑：69 项 Python 与 62 项无宿主 Swift 测试通过，Debug 构建通过。C07 的快速连点模型测试通过；实际点击与辅助功能路径待屏幕 1 单窗口验收。
- 2026-10-14 无宿主逻辑测试 50 项通过，Python 回归 56 项通过，正式 Debug 构建通过。
- 分类与观看状态过滤的可见操作仍待屏幕 1 单窗口验收。
