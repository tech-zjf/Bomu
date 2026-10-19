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
        let revised = try await cache.thumbnail(mediaFileID: 1, contentRevision: "revision-2", sourceURL: sources[0])
        XCTAssertNotEqual(revised, reused, "Different content revisions must not share artwork")
        let revisedCalls = await generator.callCount()
        XCTAssertEqual(revisedCalls, 5)
    }

    func testConcurrentRequestsForSameThumbnailDoNotEvictUnrelatedCachedMedia() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let generator = TestThumbnailGenerator(delay: .milliseconds(50), data: Data(repeating: 0xAB, count: 4))
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"),
                                        maximumBytes: 8, generator: generator)
        let sources = try makeSourceFiles(in: directory, count: 2)
        let first = try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: sources[0])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: first.path)

        let results = try await withThrowingTaskGroup(of: URL.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    try await cache.thumbnail(mediaFileID: 2, contentRevision: "r1", sourceURL: sources[1])
                }
            }
            var urls: [URL] = []
            for try await url in group { urls.append(url) }
            return urls
        }

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(Set(results).count, 1)
        let calls = await generator.callCount()
        XCTAssertEqual(calls, 2, "Concurrent requests for the same revision must share one generation")
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path),
                      "Two requests for one cache key must count its bytes only once")
        for result in results { XCTAssertEqual(try Data(contentsOf: result).count, 4) }
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

    func testCancellingOneRequestDoesNotCancelAnotherConsumer() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSourceFiles(in: directory, count: 1)[0]
        let generator = ControlledThumbnailGenerator()
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"), generator: generator)
        let first = Task {
            try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
        }
        try await waitUntil { await generator.pendingCount() == 1 }
        let survivor = Task {
            try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
        }
        first.cancel()
        do {
            _ = try await first.value
            XCTFail("A cancelled consumer must finish with cancellation")
        } catch is CancellationError { }
        await generator.release()
        let url = try await survivor.value
        XCTAssertEqual(try Data(contentsOf: url), Data("jpeg".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("source 0".utf8))
    }

    func testLastConsumerCancellationStopsGenerationAndAllowsRetry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSourceFiles(in: directory, count: 1)[0]
        let generator = ControlledThumbnailGenerator()
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"),
                                        maximumConcurrentGenerations: 1, generator: generator)
        let request = Task {
            try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
        }
        try await waitUntil { await generator.pendingCount() == 1 }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("The last consumer must not wait for the generation timeout")
        } catch is CancellationError { }
        try await waitUntil { await generator.cancelledCount() == 1 }
        let abandoned = await cache.cachedThumbnail(mediaFileID: 1, contentRevision: "r1")
        XCTAssertNil(abandoned)
        await generator.release()
        let retried = try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
        XCTAssertEqual(try Data(contentsOf: retried), Data("jpeg".utf8))
        let calls = await generator.callCount()
        XCTAssertEqual(calls, 2, "Retry must start fresh and recover the generation permit")
    }

    func testFailedSharedGenerationCanBeRetriedWithoutPoisoningTheKey() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSourceFiles(in: directory, count: 1)[0]
        let generator = TestThumbnailGenerator(delay: .milliseconds(50), data: Data(repeating: 1, count: 8))
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"),
                                        maximumBytes: 4, generator: generator)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<2 {
                group.addTask {
                    do {
                        _ = try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
                        XCTFail("Oversized generations must fail for every consumer")
                    } catch MediaThumbnailError.cacheEntryTooLarge { }
                }
            }
            try await group.waitForAll()
        }
        let sharedCalls = await generator.callCount()
        XCTAssertEqual(sharedCalls, 1)
        do {
            _ = try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
            XCTFail("A fresh attempt still enforces the byte limit")
        } catch MediaThumbnailError.cacheEntryTooLarge { }
        let calls = await generator.callCount()
        XCTAssertEqual(calls, 2)
        let cached = await cache.cachedThumbnail(mediaFileID: 1, contentRevision: "r1")
        XCTAssertNil(cached)
        XCTAssertEqual(try Data(contentsOf: source), Data("source 0".utf8))
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard clock.now < deadline else { throw MediaThumbnailError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
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

private actor ControlledThumbnailGenerator: ThumbnailFrameGenerating {
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var calls = 0
    private var cancellations = 0
    private var isReleased = false

    func jpegData(for mediaURL: URL, maximumPixelSize: Int) async throws -> Data {
        calls += 1
        let id = calls
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    cancellations += 1
                    continuation.resume(throwing: CancellationError())
                } else if isReleased {
                    continuation.resume(returning: Data("jpeg".utf8))
                } else {
                    pending[id] = continuation
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    func release() {
        isReleased = true
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations { continuation.resume(returning: Data("jpeg".utf8)) }
    }

    func pendingCount() -> Int { pending.count }
    func callCount() -> Int { calls }
    func cancelledCount() -> Int { cancellations }

    private func cancel(_ id: Int) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        cancellations += 1
        continuation.resume(throwing: CancellationError())
    }
}
