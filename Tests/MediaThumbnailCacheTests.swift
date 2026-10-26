import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

final class MediaThumbnailCacheTests: XCTestCase {
    func testPresentationDecoderReadsJPEGAndRejectsInvalidOrCancelledLoads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let jpegURL = directory.appending(path: "artwork.jpg")
        let context = try XCTUnwrap(CGContext(data: nil, width: 3, height: 2,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 2))
        let source = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            jpegURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, source, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let pool = AsyncPermitPool(limit: 1)
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"),
                                        sharedPermits: pool)
        try await pool.acquire()
        let queued = Task { await cache.decodedImage(at: jpegURL) }
        try await waitUntil {
            let snapshot = await pool.snapshot()
            return snapshot.activeCount == 1 && snapshot.waitingCount == 1
        }
        queued.cancel()
        let queuedImage = await queued.value
        XCTAssertNil(queuedImage)
        try await waitUntil { await pool.snapshot().waitingCount == 0 }
        await pool.release()

        let decoded = await cache.decodedImage(at: jpegURL)
        XCTAssertEqual(decoded?.width, 3)
        XCTAssertEqual(decoded?.height, 2)
        let afterDecode = await pool.snapshot()
        XCTAssertEqual(afterDecode.activeCount, 0)

        let invalidURL = directory.appending(path: "invalid.jpg")
        try Data("invalid image".utf8).write(to: invalidURL)
        let invalid = await cache.decodedImage(at: invalidURL)
        XCTAssertNil(invalid)

        let cancelled = Task { () -> CGImage? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await MediaThumbnailImageDecoder.image(at: jpegURL)
        }
        let cancelledImage = await cancelled.value
        XCTAssertNil(cancelledImage)
    }

    func testReducedPermitBudgetWaitsForActiveWorkAndIncreaseReleasesQueue() async throws {
        let pool = AsyncPermitPool(limit: 2)
        try await pool.acquire()
        try await pool.acquire()
        await pool.setLimit(1)
        let admissions = PermitAdmissions()
        let waiting = Task {
            try await pool.acquire()
            await admissions.record()
        }
        await pool.release()
        try await Task.sleep(for: .milliseconds(20))
        let whileOverBudget = await admissions.count
        XCTAssertEqual(whileOverBudget, 0, "Shrinking the limit must drain existing work first")
        await pool.setLimit(2)
        try await waiting.value
        let admitted = await admissions.count
        XCTAssertEqual(admitted, 1, "Increasing the limit must wake queued work without another release")
        await pool.release()
        await pool.release()
    }

    func testCancelledPermitWaiterCannotBlockLaterWork() async throws {
        let pool = AsyncPermitPool(limit: 1)
        try await pool.acquire()
        let cancelled = Task { try await pool.acquire() }
        cancelled.cancel()
        do {
            try await cancelled.value
            XCTFail("A cancelled waiter must not acquire a permit")
        } catch is CancellationError { }
        await pool.release()
        try await pool.acquire()
        await pool.release()
    }

    func testCancellationRacingWithPermitAdmissionDoesNotLeakCapacity() async throws {
        let pool = AsyncPermitPool(limit: 1)
        for _ in 0..<50 {
            try await pool.acquire()
            let waiting = Task {
                do {
                    try await pool.acquire()
                    await pool.release()
                } catch is CancellationError { }
                catch { XCTFail("Permit admission failed unexpectedly: \(error)") }
            }
            try await waitUntil { await pool.snapshot().waitingCount == 1 }
            await pool.release()
            waiting.cancel()
            await waiting.value
            let settled = await pool.snapshot()
            XCTAssertEqual(settled.activeCount, 0)
            XCTAssertEqual(settled.waitingCount, 0)
        }
    }

    func testMetadataAndThumbnailsShareForegroundPlaybackBudget() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = try makeSourceFiles(in: directory, count: 1)[0]
        let pool = AsyncPermitPool(limit: 1)
        let generator = ControlledThumbnailGenerator()
        let cache = MediaThumbnailCache(directory: directory.appending(path: "cache"),
                                       sharedPermits: pool, generator: generator)
        let loader = CountingMetadataLoader()
        let probe = MediaMetadataProbe(sharedPermits: pool, loader: loader)
        let thumbnail = Task { try await cache.thumbnail(mediaFileID: 1, contentRevision: "r1", sourceURL: source) }
        try await waitUntil { await generator.pendingCount() == 1 }
        let metadata = Task { await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source) }
        try await Task.sleep(for: .milliseconds(20))
        let whileThumbnailActive = await loader.calls
        XCTAssertEqual(whileThumbnailActive, 0)
        thumbnail.cancel()
        _ = try? await thumbnail.value
        let result = await metadata.value
        XCTAssertEqual(result.duration, 42)
        let afterCancellation = await loader.calls
        XCTAssertEqual(afterCancellation, 1, "Cancelled work must return its shared permit")
    }

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

private actor PermitAdmissions {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor CountingMetadataLoader: MediaMetadataLoading {
    private(set) var calls = 0
    func loadMetadata(from url: URL) async throws -> MediaTechnicalMetadata {
        calls += 1
        return MediaTechnicalMetadata(duration: 42, width: 640, height: 360,
                                      videoCodec: "H.264", audioTracks: [])
    }
}
