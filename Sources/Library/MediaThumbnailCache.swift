import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

protocol ThumbnailFrameGenerating: Sendable {
    func jpegData(for mediaURL: URL, maximumPixelSize: Int) async throws -> Data
}

enum MediaThumbnailError: LocalizedError {
    case unavailableMedia
    case noVideoFrame
    case timedOut
    case cacheEntryTooLarge

    var errorDescription: String? {
        switch self {
        case .unavailableMedia: "The source media is unavailable for thumbnail generation."
        case .noVideoFrame: "The media does not contain a decodable video frame."
        case .timedOut: "Thumbnail generation exceeded its time limit."
        case .cacheEntryTooLarge: "The generated thumbnail exceeds the configured cache limit."
        }
    }
}

/// Stores bounded local JPEGs. It never writes to or removes source media.
actor MediaThumbnailCache {
    private struct Generation {
        let id: UUID
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<URL, Error>]
    }

    private var generations: [URL: Generation] = [:]
    private let directory: URL
    private let maximumBytes: Int
    private let maximumPixelSize: Int
    private let timeout: Duration
    private let permits: AsyncPermitPool
    private let generator: any ThumbnailFrameGenerating

    init(
        directory: URL,
        maximumBytes: Int = 512 * 1_024 * 1_024,
        maximumConcurrentGenerations: Int = 2,
        maximumPixelSize: Int = 640,
        timeout: Duration = .seconds(10),
        generator: any ThumbnailFrameGenerating = AVFoundationThumbnailGenerator()
    ) {
        self.directory = directory
        self.maximumBytes = max(1, maximumBytes)
        self.maximumPixelSize = max(32, maximumPixelSize)
        self.timeout = timeout
        permits = AsyncPermitPool(limit: max(1, min(2, maximumConcurrentGenerations)))
        self.generator = generator
    }

    static func applicationCache() throws -> MediaThumbnailCache {
        let cacheDirectory = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "Bomu/Thumbnails", directoryHint: .isDirectory)
        return MediaThumbnailCache(directory: cacheDirectory)
    }

    func cachedThumbnail(mediaFileID: Int64, contentRevision: String) -> URL? {
        let url = cacheURL(mediaFileID: mediaFileID, contentRevision: contentRevision)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date.now], ofItemAtPath: url.path)
        return url
    }

    func thumbnail(mediaFileID: Int64, contentRevision: String, sourceURL: URL) async throws -> URL {
        try Task.checkCancellation()
        if let existing = cachedThumbnail(mediaFileID: mediaFileID, contentRevision: contentRevision) {
            return existing
        }
        guard FileManager.default.fileExists(atPath: sourceURL.path),
              (try? sourceURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw MediaThumbnailError.unavailableMedia
        }
        let key = cacheURL(mediaFileID: mediaFileID, contentRevision: contentRevision)
        let waiterID = UUID()
        let url = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if var generation = generations[key] {
                    generation.waiters[waiterID] = continuation
                    generations[key] = generation
                    return
                }
                let generationID = UUID()
                let task = Task {
                    let result: Result<URL, Error>
                    do {
                        result = .success(try await generateAndCache(
                            mediaFileID: mediaFileID, contentRevision: contentRevision, sourceURL: sourceURL))
                    } catch {
                        result = .failure(error)
                    }
                    finishGeneration(key: key, id: generationID, result: result)
                }
                generations[key] = Generation(id: generationID, task: task,
                                               waiters: [waiterID: continuation])
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID, for: key) }
        }
        try Task.checkCancellation()
        return url
    }

    private func cancelWaiter(_ id: UUID, for key: URL) {
        guard var generation = generations[key],
              let continuation = generation.waiters.removeValue(forKey: id) else { return }
        if generation.waiters.isEmpty {
            generations[key] = nil
            generation.task.cancel()
        } else {
            generations[key] = generation
        }
        continuation.resume(throwing: CancellationError())
    }

    private func finishGeneration(key: URL, id: UUID, result: Result<URL, Error>) {
        // An abandoned worker may finish after a new request has taken ownership of this key.
        guard let generation = generations[key], generation.id == id else { return }
        generations[key] = nil
        for continuation in generation.waiters.values { continuation.resume(with: result) }
    }

    private func generateAndCache(mediaFileID: Int64, contentRevision: String, sourceURL: URL) async throws -> URL {
        try await permits.acquire()
        do {
            try Task.checkCancellation()
            if let existing = cachedThumbnail(mediaFileID: mediaFileID, contentRevision: contentRevision) {
                await permits.release()
                return existing
            }
            let jpeg = try await generateWithTimeout(sourceURL)
            try Task.checkCancellation()
            // Another request for this revision may have committed while generation
            // suspended the actor. Reuse it before reserving space or evicting entries.
            if let existing = cachedThumbnail(mediaFileID: mediaFileID, contentRevision: contentRevision) {
                await permits.release()
                return existing
            }
            guard jpeg.count <= maximumBytes else { throw MediaThumbnailError.cacheEntryTooLarge }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try evictToFit(incomingBytes: jpeg.count)
            let destination = cacheURL(mediaFileID: mediaFileID, contentRevision: contentRevision)
            try jpeg.write(to: destination, options: .atomic)
            await permits.release()
            return destination
        } catch {
            await permits.release()
            throw error
        }
    }

    private func generateWithTimeout(_ sourceURL: URL) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { [generator, maximumPixelSize] in
                try await generator.jpegData(for: sourceURL, maximumPixelSize: maximumPixelSize)
            }
            group.addTask { [timeout] in
                try await Task.sleep(for: timeout)
                throw MediaThumbnailError.timedOut
            }
            guard let data = try await group.next() else { throw MediaThumbnailError.noVideoFrame }
            group.cancelAll()
            return data
        }
    }

    private func cacheURL(mediaFileID: Int64, contentRevision: String) -> URL {
        let revisionHash = SHA256.hash(data: Data(contentRevision.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return directory.appending(path: "\(mediaFileID)-\(revisionHash).jpg")
    }

    private func evictToFit(incomingBytes: Int) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard Self.ownsCacheEntry(url) else { return nil }
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
            ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize, let modifiedAt = values.contentModificationDate else { return nil }
            return (url, size, modifiedAt)
        }.sorted { $0.2 < $1.2 }
        var remainingBytes = entries.reduce(0) { $0 + $1.1 }
        for (url, size, _) in entries where remainingBytes + incomingBytes > maximumBytes {
            try FileManager.default.removeItem(at: url)
            remainingBytes -= size
        }
    }

    /// The cache may only evict files whose complete name matches the cache's own key format.
    private static func ownsCacheEntry(_ url: URL) -> Bool {
        let parts = url.lastPathComponent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].allSatisfy(\.isNumber), parts[1].hasSuffix(".jpg") else { return false }
        let digest = parts[1].dropLast(4)
        return digest.count == 64 && digest.allSatisfy { $0.isHexDigit }
    }
}

actor AsyncPermitPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = limit
    }

    func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                }
            }
        }, onCancel: {
            Task { await self.cancelWaiter(id) }
        })
    }

    func release() {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        } else {
            activeCount -= 1
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}

private struct AVFoundationThumbnailGenerator: ThumbnailFrameGenerating {
    func jpegData(for mediaURL: URL, maximumPixelSize: Int) async throws -> Data {
        let asset = AVURLAsset(url: mediaURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { throw MediaThumbnailError.noVideoFrame }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maximumPixelSize, height: maximumPixelSize)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let captureTime = min(1.0, seconds / 10)
        let request = AVImageGenerationRequest(generator: generator)
        return try await request.generate(at: CMTime(seconds: captureTime, preferredTimescale: 600))
    }
}

/// Bridges AVAssetImageGenerator's callback API to async cancellation at one narrow boundary.
/// `lock` serializes all generator calls, the continuation, and completion state because AVFoundation's
/// callback and the task cancellation handler may run concurrently. The callback captures this request,
/// never the generator; the continuation is resumed only after releasing the lock.
private final class AVImageGenerationRequest: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let generator: AVAssetImageGenerator
    private var continuation: CheckedContinuation<Data, Error>?
    private var isFinished = false

    init(generator: AVAssetImageGenerator) {
        self.generator = generator
    }

    func generate(at time: CMTime) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(at: time, continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(at time: CMTime, continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) { [self] _, image, _, result, _ in
            guard result == .succeeded, let image,
                  let data = Self.jpegData(for: image) else {
                finish(.failure(MediaThumbnailError.noVideoFrame))
                return
            }
            finish(.success(data))
        }
        lock.unlock()
    }

    private func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        generator.cancelAllCGImageGeneration()
        lock.unlock()
        continuation?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    private static func jpegData(for image: CGImage) -> Data? {
        guard let mutableData = CFDataCreateMutable(nil, 0),
              let destination = CGImageDestinationCreateWithData(
                mutableData,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else { return nil }
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }
}
