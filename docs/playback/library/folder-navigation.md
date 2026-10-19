# 文件夹浏览与密度

## 事实来源与调用链

`MediaLibraryScanner` 把来源内媒体文件及卷相对路径写入 `media_source_files` / `media_files`，并将目录条目写入 `media_source_directories`；完整扫描才把未重新发现的文件和目录标为不存在。`PlaybackHistoryStore.librarySnapshot(mountedVolumeIDs:)` 在同一只读事务读取来源、媒体和目录；`MediaLibraryModel.childDirectories(in:)` 只挑出当前目录的直接子目录，`mediaItems(in:)` 只返回当前层级的媒体。这样空目录也能浏览，播放定位、媒体身份和文件夹浏览共享扫描器提供的事实。

`MediaLibraryView.foldersContent` 展示来源根目录并以 `NavigationStack` 推入子目录。来源列表和子目录各自保存滚动目标；目录页面提供网格/列表密度和面包屑。收藏、搜索和播放仍通过同一媒体 ID 回到播放器；源文件只读。

## 行为边界

- 离线来源在侧栏和文件夹列表中保留入口，可浏览已索引的子目录和媒体；离线媒体标明状态并禁用播放，磁盘重连后恢复入口。这里只展示上次扫描记录，不承诺反映离线磁盘上的新变化。
- 文件夹树只包含扫描器实际发现的目录；空目录会保留在目录索引中，可进入并显示空状态。
- 目录成员来自数据库快照；需要重新核对时由现有扫描器刷新。扫描失败不会将已有记录批量标记为缺失。
- 文件名中的斜线不可能成为单个路径组件；路径派生通过父目录加分隔符的边界匹配，避免 `Season 1` 错匹配 `Season 10`。
- 面包屑通过目录身份截取当前 `NavigationStack` 路径，不依赖面包屑显示下标；来源根本身是路径的第一层，因此嵌套祖先必须保留从根到目标目录的完整前缀。目标目录已不在当前路径时不改变导航。

## 验证

`MediaLibraryScannerTests.testLibraryModelBuildsNestedFoldersAndKeepsFilesAtTheirOwnLevel` 覆盖来源根、两层子目录和各层文件隔离；`testEmptyDirectoriesAreNavigableAndRemovedAfterACompleteRescan` 覆盖空目录和完整扫描回收；面包屑测试覆盖来源根、嵌套父层、当前层和不在当前路径中的陈旧目录。`testAvailableItemsExcludeMediaRemovedByCompleteScan` 验证扫描移除后的成员仍保留历史行，但不会出现在可用媒体集合。2026-10-15 Xcode 27 无宿主 XCTest bundle 共 96 项直接运行通过；Python 回归 134 项通过，Debug build 通过。此前在屏幕 1 的单个 Bomu 普通窗口内，用 `.build/fixtures` 下临时三层目录和 60 个小型损坏占位文件压出可滚动列表：验证网格/列表切换、进入两级子目录、父级与来源根面包屑返回；列表滚动到约 35% 后返回并重入，视图模式和滚动位置均恢复，列表末尾可见 sample-60.mp4。测试目录已删除；这 60 条旧数据库成员仍保留为不可用历史记录，不再显示为当前媒体。
