import Foundation
import XCTest

final class MediaMetadataProbeTests: XCTestCase {
    func testConcurrentMetadataRequestsShareOneProbeAndCacheByRevision() async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        try Data([1, 2, 3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let loader = DelayedMetadataLoader(delay: .milliseconds(50))
        let probe = MediaMetadataProbe(loader: loader)
        let results = await withTaskGroup(of: MediaTechnicalMetadata.self) { group in
            for _ in 0..<8 {
                group.addTask { await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source) }
            }
            var values: [MediaTechnicalMetadata] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0.duration == 42 })
        let initialCalls = await loader.calls
        XCTAssertEqual(initialCalls, 1)
        _ = await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
        let cachedCalls = await loader.calls
        XCTAssertEqual(cachedCalls, 1)
        _ = await probe.metadata(mediaFileID: 1, contentRevision: "r2", sourceURL: source)
        let revisedCalls = await loader.calls
        XCTAssertEqual(revisedCalls, 2)
    }

    func testMetadataTimeoutCancelsWorkerAndReturnsPermitForRetry() async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        try Data([1, 2, 3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let loader = DelayedMetadataLoader(delay: .seconds(30))
        let probe = MediaMetadataProbe(timeout: .milliseconds(20), sharedPermits: AsyncPermitPool(limit: 1), loader: loader)
        let result = await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
        XCTAssertNil(result.duration)
        let cached = await probe.cachedMetadata(mediaFileID: 1, contentRevision: "r1")
        XCTAssertNil(cached, "Timeout must not become a permanent unknown cache entry")
        let cancellations = await loader.cancellations
        XCTAssertEqual(cancellations, 1)
        await loader.setDelay(.zero)
        let retry = await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
        XCTAssertEqual(retry.duration, 42)
        let calls = await loader.calls
        XCTAssertEqual(calls, 2)
    }

    func testLastMetadataConsumerCancellationStopsWorkerAndDoesNotCache() async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        try Data([1, 2, 3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let loader = DelayedMetadataLoader(delay: .seconds(30))
        let probe = MediaMetadataProbe(sharedPermits: AsyncPermitPool(limit: 1), loader: loader)
        let request = Task { await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source) }
        try await waitForLoader { await loader.calls == 1 }
        request.cancel()
        let cancelled = await request.value
        XCTAssertNil(cancelled.duration)
        try await waitForLoader { await loader.cancellations == 1 }
        let cached = await probe.cachedMetadata(mediaFileID: 1, contentRevision: "r1")
        XCTAssertNil(cached)
        await loader.setDelay(.zero)
        let retry = await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source)
        XCTAssertEqual(retry.duration, 42)
    }

    func testCancellingOneMetadataConsumerKeepsTheOtherResult() async throws {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".mp4")
        try Data([1, 2, 3]).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let loader = DelayedMetadataLoader(delay: .milliseconds(100))
        let probe = MediaMetadataProbe(loader: loader)
        let survivor = Task { await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source) }
        try await waitForLoader { await loader.calls == 1 }
        let cancelled = Task { await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: source) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        let discarded = await cancelled.value
        let kept = await survivor.value
        XCTAssertNil(discarded.duration)
        XCTAssertEqual(kept.duration, 42)
        let calls = await loader.calls
        let cancellations = await loader.cancellations
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(cancellations, 0)
    }

    private func waitForLoader(_ condition: () async -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !(await condition()) {
            guard clock.now < deadline else { throw ProbeTestError.timedOut }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    private enum ProbeTestError: Error { case timedOut }

    func testCompactMediaCardMetadataKeepsTimeDimensionsAndCodecReadable() {
        let metadata = MediaTechnicalMetadata(
            duration: 15,
            width: 960,
            height: 540,
            videoCodec: "H.264",
            audioTracks: [MediaAudioTrackMetadata(codec: "AAC")]
        )

        XCTAssertEqual(MediaTechnicalMetadataText.cardValue(metadata: metadata, isAudio: false),
                       "0:15 · 960 × 540 · H.264 · \(String(localized: "library.metadata.oneAudioTrack")) · AAC")
        XCTAssertEqual(MediaTechnicalMetadataText.durationLabel(3_661), "1:01:01")
        XCTAssertNil(MediaTechnicalMetadataText.durationLabel(.infinity))
    }

    func testUnavailableMetadataShowsUnknownWhileFileSizeRemainsAvailable() {
        let metadata = MediaTechnicalMetadata(
            duration: nil,
            width: nil,
            height: nil,
            videoCodec: nil,
            audioTracks: nil
        )
        let item = MediaLibraryItem(
            id: 1,
            sourceRootID: 1,
            volumeID: "test-volume",
            relativePath: "mpeg2-pal-program-stream.mpg",
            displayName: "mpeg2-pal-program-stream.mpg",
            byteCount: 712_704,
            contentRevision: "fixture",
            isPresent: true,
            isFavorite: false,
            isWatched: false,
            hasPlaybackHistoryConflict: false,
            manualCategory: nil,
            playbackPosition: 0,
            lastPlayedAt: nil,
            addedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertNil(MediaTechnicalMetadataText.cardValue(metadata: metadata, isAudio: false))
        XCTAssertEqual(MediaTechnicalMetadataText.cardValueOrUnknown(metadata: metadata, isAudio: false),
                       String(localized: "library.metadata.unknown"))
        XCTAssertEqual(MediaTechnicalMetadataText.cardValueOrUnknown(metadata: nil, isAudio: false),
                       String(localized: "library.metadata.unknown"))
        let fileSize = ByteCountFormatStyle().format(item.byteCount)
        XCTAssertNil(MediaTechnicalMetadataText.accessibilityValue(metadata: metadata, isAudio: false))
        XCTAssertEqual(MediaTechnicalMetadataText.value(metadata: metadata, isAudio: false),
                       String(localized: "library.metadata.unknown"))

        let summary = MediaLibraryAccessibilitySummary.value(for: item, isSelected: false, metadata: metadata)
        XCTAssertFalse(summary.contains(String(localized: "library.metadata.unknown")))
        XCTAssertTrue(summary.contains(fileSize))
    }

    func testMetadataLoadStateSeparatesLoadingFromUnavailableResults() {
        let unknown = MediaTechnicalMetadata(
            duration: nil, width: nil, height: nil, videoCodec: nil, audioTracks: nil
        )

        XCTAssertEqual(
            MediaTechnicalMetadataLoadState.loading.cardValue(isAudio: false),
            String(localized: "library.metadata.loading")
        )
        XCTAssertEqual(
            MediaTechnicalMetadataLoadState.resolved(nil).cardValue(isAudio: false),
            String(localized: "library.metadata.unknown")
        )
        XCTAssertEqual(
            MediaTechnicalMetadataLoadState.resolved(unknown).cardValue(isAudio: false),
            String(localized: "library.metadata.unknown")
        )
    }

    func testReadsRealDurationResolutionAndTrackCodecsFromLocalMedia() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let media = projectRoot.appending(path: ".build/fixtures/h264-sdr.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path), "The licensed synthetic fixture is generated by test-dev.sh")
        let probe = MediaMetadataProbe()

        let metadata = await probe.metadata(mediaFileID: 1, contentRevision: "fixture", sourceURL: media)

        XCTAssertEqual(metadata.width, 960)
        XCTAssertEqual(metadata.height, 540)
        XCTAssertEqual(metadata.videoCodec, "H.264")
        XCTAssertEqual(metadata.audioTracks, [MediaAudioTrackMetadata(codec: "AAC")])
        XCTAssertEqual(metadata.duration ?? 0, 15, accuracy: 0.1)
        XCTAssertTrue(try XCTUnwrap(MediaTechnicalMetadataText.cardValue(
            metadata: metadata, isAudio: false
        )).contains(String(localized: "library.metadata.oneAudioTrack")))
        XCTAssertTrue(try XCTUnwrap(MediaTechnicalMetadataText.cardValue(
            metadata: metadata, isAudio: false
        )).contains("AAC"))
    }

    func testPreservesEachAudioTrackCodecFromMixedCodecMedia() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let media = projectRoot.appending(path: ".build/fixtures/mixed-audio-tracks.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path), "The licensed mixed-codec fixture is generated by test-dev.sh")
        let probe = MediaMetadataProbe()

        let metadata = await probe.metadata(mediaFileID: 3, contentRevision: "mixed-audio", sourceURL: media)

        XCTAssertEqual(metadata.audioTracks, [
            MediaAudioTrackMetadata(codec: "AAC"),
            MediaAudioTrackMetadata(codec: "ALAC"),
        ])
    }

    func testReadsRealHEVCMain10MetadataFromLocalMedia() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let media = projectRoot.appending(path: ".build/fixtures/h265-main10-sdr.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.path), "The licensed synthetic HEVC fixture is generated by test-dev.sh")
        let probe = MediaMetadataProbe()

        let metadata = await probe.metadata(mediaFileID: 4, contentRevision: "hevc-main10", sourceURL: media)

        XCTAssertEqual(metadata.width, 640)
        XCTAssertEqual(metadata.height, 360)
        XCTAssertEqual(metadata.videoCodec, "HEVC")
        XCTAssertEqual(metadata.audioTracks, [MediaAudioTrackMetadata(codec: "AAC")])
        XCTAssertEqual(metadata.duration ?? 0, 15, accuracy: 0.1)
        let cardValue = try XCTUnwrap(MediaTechnicalMetadataText.cardValue(metadata: metadata, isAudio: false))
        XCTAssertTrue(cardValue.contains("HEVC"))
        XCTAssertTrue(cardValue.contains("AAC"))
    }

    func testUnreadableFileReturnsUnknownInsteadOfInventedMetadata() async throws {
        let media = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).mp4")
        try Data("not a media container".utf8).write(to: media)
        defer { try? FileManager.default.removeItem(at: media) }
        let probe = MediaMetadataProbe()

        let metadata = await probe.metadata(mediaFileID: 2, contentRevision: "invalid", sourceURL: media)

        XCTAssertNil(metadata.duration)
        XCTAssertNil(metadata.width)
        XCTAssertNil(metadata.height)
        XCTAssertNil(metadata.videoCodec)
        XCTAssertNil(metadata.audioTracks)
    }

    func testMetadataCacheIsBoundedAndEvictsLeastRecentlyUsedEntry() async throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = projectRoot.appending(path: ".build/fixtures/h264-sdr.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appending(path: "first.mp4")
        let secondURL = directory.appending(path: "second.mp4")
        try FileManager.default.copyItem(at: fixture, to: firstURL)
        try FileManager.default.copyItem(at: fixture, to: secondURL)
        let probe = MediaMetadataProbe(maximumCachedEntries: 2)

        let first = await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: firstURL)
        _ = await probe.metadata(mediaFileID: 2, contentRevision: "r1", sourceURL: secondURL)
        let cached = await probe.cachedMetadata(mediaFileID: 1, contentRevision: "r1")
        XCTAssertEqual(cached, first)
        let changedRevision = await probe.cachedMetadata(mediaFileID: 1, contentRevision: "r2")
        XCTAssertNil(changedRevision, "A revised file must not inherit facts from an earlier revision")
        _ = await probe.metadata(mediaFileID: 3, contentRevision: "r1", sourceURL: fixture)

        try Data("unreadable replacement".utf8).write(to: secondURL)
        let evicted = await probe.metadata(mediaFileID: 2, contentRevision: "r1", sourceURL: secondURL)
        XCTAssertEqual(evicted, MediaTechnicalMetadata(duration: nil, width: nil, height: nil,
                                                       videoCodec: nil, audioTracks: nil))

        try Data("unreadable replacement".utf8).write(to: firstURL)
        let retained = await probe.metadata(mediaFileID: 1, contentRevision: "r1", sourceURL: firstURL)
        XCTAssertEqual(retained, first)
    }
}

private actor DelayedMetadataLoader: MediaMetadataLoading {
    private var delay: Duration
    private(set) var calls = 0
    private(set) var cancellations = 0

    init(delay: Duration) { self.delay = delay }
    func setDelay(_ value: Duration) { delay = value }

    func loadMetadata(from url: URL) async throws -> MediaTechnicalMetadata {
        calls += 1
        do { try await Task.sleep(for: delay) }
        catch {
            cancellations += 1
            throw error
        }
        return MediaTechnicalMetadata(duration: 42, width: 640, height: 360,
                                      videoCodec: "H.264", audioTracks: [])
    }
}
