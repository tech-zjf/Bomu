import Foundation
import XCTest

final class PlaybackQueueTests: XCTestCase {
    func testNaturalOrderDeduplicationAndSelection() throws {
        let urls = [
            URL(filePath: "/资料/第 10 集.mkv"),
            URL(filePath: "/资料/第 2 集.mkv"),
            URL(filePath: "/资料/第 1 集.mkv"),
            URL(filePath: "/资料/第 2 集.mkv")
        ]
        var queue = PlaybackQueue(urls: urls, startingAt: urls[0])

        XCTAssertEqual(queue.items.map(\.lastPathComponent), ["第 1 集.mkv", "第 2 集.mkv", "第 10 集.mkv"])
        XCTAssertEqual(queue.currentURL?.lastPathComponent, "第 10 集.mkv")
        XCTAssertNil(queue.nextURL)
        XCTAssertEqual(queue.goBack()?.lastPathComponent, "第 2 集.mkv")
        XCTAssertEqual(queue.advance()?.lastPathComponent, "第 10 集.mkv")
        XCTAssertNil(queue.select(-1))
        XCTAssertNil(queue.select(queue.items.count))
    }

    func testDirectoryExpansionUsesSharedMediaTypesAndSkipsUnsupportedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let nested = root.appending(path: "子目录")
        let package = root.appending(path: "影片.app")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for path in [
            root.appending(path: "第 10 集.mp4"),
            root.appending(path: "第 2 集.mp4"),
            root.appending(path: "说明.txt"),
            root.appending(path: "bonus.divx"),
            root.appending(path: "archive.mxf"),
            root.appending(path: "audio.dts"),
            nested.appending(path: "中文 文件.mkv"),
            nested.appending(path: "audio.m4b"),
            package.appending(path: "嵌套.mov"),
            root.appending(path: ".隐藏.mp4")
        ] {
            try Data().write(to: path)
        }

        let files = try MediaFileDiscovery.expand([root])
        XCTAssertEqual(
            Set(files.map(\.lastPathComponent)),
            Set(["第 2 集.mp4", "第 10 集.mp4", "中文 文件.mkv", "bonus.divx",
                 "archive.mxf", "audio.dts", "audio.m4b"])
        )
    }

    func testDirectoryExpansionStopsWhenCancelledDuringTraversal() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<10 {
            try Data().write(to: root.appending(path: "clip-\(index).mp4"))
        }

        var cancellationChecks = 0
        XCTAssertThrowsError(try MediaFileDiscovery.expand([root]) {
            cancellationChecks += 1
            if cancellationChecks == 5 { throw CancellationError() }
        }) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(cancellationChecks, 5)
    }
}
