import Foundation
import XCTest

final class MediaThumbnailCacheTests: XCTestCase {
    func testGenerationConcurrencyIsBoundedAndCacheHitsReuseTheFile() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generator = TestThumbnailGenerator(delay: .milliseconds(40), data: Data("jpeg".utf8))
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"),
                                        maximumBytes: 100, generator: generator)
        let sources = try makeSourceFiles(in: directory, count: 4)

        try await withThrowingTaskGroup(of: URL.self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    try await cache.thumbnail(mediaFileID: Int64(index + 1),
                                              contentRevision: "revision-1", sourceURL: source)
                }
            }
            var results: [URL] = []
            for try await result in group { results.append(result) }
            XCTAssertEqual(results.count, 4)
        }

        let reused = try await cache.thumbnail(mediaFileID: 1, contentRevision: "revision-1",
                                               sourceURL: sources[0])
        let cached = await cache.cachedThumbnail(mediaFileID: 1, contentRevision: "revision-1")
        let callCount = await generator.callCount()
        let maximumActiveCount = await generator.maximumActiveCount()
        XCTAssertEqual(reused, cached)
        XCTAssertEqual(callCount, 4)
        XCTAssertEqual(maximumActiveCount, 2)
    }

    func testTimeoutCancelsTheActiveGenerator() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSourceFiles(in: directory, count: 1)[0]
        let generator = TestThumbnailGenerator(delay: .seconds(30), data: Data("jpeg".utf8))
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"),
                                        timeout: .milliseconds(30), generator: generator)

        do {
            _ = try await cache.thumbnail(mediaFileID: 1, contentRevision: "revision-1", sourceURL: source)
            XCTFail("A generator that exceeds the limit must time out")
        } catch MediaThumbnailError.timedOut { }

        let callCount = await generator.callCount()
        let cancelledCount = await generator.cancelledCount()
        let cached = await cache.cachedThumbnail(mediaFileID: 1, contentRevision: "revision-1")
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(cancelledCount, 1)
        XCTAssertNil(cached)
    }

    func testCacheLimitEvictsOnlyOldThumbnailFilesAndPreservesSourceMedia() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generator = TestThumbnailGenerator(delay: .zero, data: Data(repeating: 0xAB, count: 4))
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"),
                                        maximumBytes: 8, generator: generator)
        let sources = try makeSourceFiles(in: directory, count: 3)
        let originals = try sources.map { try Data(contentsOf: $0) }
        let cacheDirectory = directory.appending(path: "cache")
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        let unrelatedFile = cacheDirectory.appending(path: "do-not-delete.txt")
        try Data("preserve".utf8).write(to: unrelatedFile)

        let first = try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: sources[0])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: first.path)
        _ = try await cache.thumbnail(mediaFileID: 2, contentRevision: "r1", sourceURL: sources[1])
        let secondURL = await cache.cachedThumbnail(mediaFileID: 2, contentRevision: "r1")
        let second = try XCTUnwrap(secondURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)],
                                              ofItemAtPath: second.path)
        _ = try await cache.thumbnail(mediaFileID: 3, contentRevision: "r1", sourceURL: sources[2])

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedFile.path))
        let cachedSecond = await cache.cachedThumbnail(mediaFileID: 2, contentRevision: "r1")
        let third = await cache.cachedThumbnail(mediaFileID: 3, contentRevision: "r1")
        XCTAssertNotNil(cachedSecond)
        XCTAssertNotNil(third)
        for (source, original) in zip(sources, originals) {
            XCTAssertEqual(try Data(contentsOf: source), original)
        }
    }

    func testCacheHitRejectsSymbolicLinkWithoutTouchingItsSource() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSourceFiles(in: directory, count: 1)[0]
        let originalBytes = try Data(contentsOf: source)
        let originalDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date
        )
        let cache = MediaThumbnailCache(
            directory: directory.appending(path: "cache"),
            generator: TestThumbnailGenerator(delay: .zero, data: Data("jpeg".utf8))
        )
        let first = try await cache.thumbnail(mediaFileID: 17, contentRevision: "revision-1",
                                              sourceURL: source)
        try FileManager.default.removeItem(at: first)
        try FileManager.default.createSymbolicLink(at: first, withDestinationURL: source)

        let linkedCacheHit = await cache.cachedThumbnail(mediaFileID: 17, contentRevision: "revision-1")
        XCTAssertNil(linkedCacheHit)
        let regenerated = try await cache.thumbnail(mediaFileID: 17, contentRevision: "revision-1",
                                                    sourceURL: source)

        XCTAssertEqual(try Data(contentsOf: regenerated), Data("jpeg".utf8))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        XCTAssertEqual(
            try FileManager.default.attributesOfItem(atPath: source.path)[.modificationDate] as? Date,
            originalDate,
            "Cache lookup must not update a linked source file's modification time"
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeSourceFiles(in directory: URL, count: Int) throws -> [URL] {
        try (0..<count).map { index in
            let url = directory.appending(path: "source-\(index).mp4")
            try Data("source \(index)".utf8).write(to: url)
            return url
        }
    }
}

private actor TestThumbnailGenerator: ThumbnailFrameGenerating {
    private let delay: Duration
    private let data: Data
    private var calls = 0
    private var cancellations = 0
    private var active = 0
    private var maximumActive = 0

    init(delay: Duration, data: Data) {
        self.delay = delay
        self.data = data
    }

    func jpegData(for mediaURL: URL, maximumPixelSize: Int) async throws -> Data {
        calls += 1
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        do {
            try await Task.sleep(for: delay)
        } catch {
            cancellations += 1
            throw error
        }
        return data
    }

    func callCount() -> Int { calls }
    func cancelledCount() -> Int { cancellations }
    func maximumActiveCount() -> Int { maximumActive }
}
