import Foundation
import Observation

/// Owns one logical playback session independently of SwiftUI view identity.
@MainActor @Observable
final class PlayerModel {
    struct InputResolution: Equatable, Sendable {
        fileprivate let revision: UInt64
    }

    private(set) var state = PlaybackState()
    private(set) var queue = PlaybackQueue()
    private(set) var startupState: StartupState = .notStarted
    private(set) var persistenceError: String?
    private(set) var inputError: String?
    private(set) var historyClearError: String?
    private(set) var dataManagementError: String?
    private var pendingPause: PlaybackPauseRequest?
    @ObservationIgnored private let engine: any PlaybackEngine
    @ObservationIgnored private let historyStore: (any PlaybackHistoryPersisting)?
    @ObservationIgnored private let preferences: PlaybackPreferences
    @ObservationIgnored private var nextRequestID: UInt64 = 0
    @ObservationIgnored private var nextPauseCommandID: UInt64 = 0
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    @ObservationIgnored private var restorationTask: Task<Void, Never>?
    @ObservationIgnored private var progressTask: Task<Void, Never>?
    @ObservationIgnored private var persistenceTask: Task<Result<Void, Error>, Never>?
    @ObservationIgnored private var mediaImportTask: Task<Void, Never>?
    @ObservationIgnored private var mediaDiscoveryTask: Task<[URL], any Error>?
    @ObservationIgnored private var mediaImportID: UInt64 = 0
    @ObservationIgnored private var resumeHistory: PlaybackHistory?
    @ObservationIgnored private var resumeMode: ResumeMode = .preference
    @ObservationIgnored private var lastRequestedVolume: Double?
    @ObservationIgnored private var pendingSubtitleDelay: Double?
    @ObservationIgnored private var historySuppressedRequestID: UInt64?

    enum StartupState: Equatable {
        case notStarted
        case preparing
        case ready
        case failed(String)
        case shuttingDown
        case shutDown
    }

    private enum ResumeMode {
        case preference
        case savedCheckpoint
        case beginning
    }

    private static let minimumAutomaticNextDuration: TimeInterval = 30

    var startupError: String? {
        guard case .failed(let message) = startupState else { return nil }
        return message
    }
    var isPrepared: Bool { startupState == .ready }
    var isShuttingDown: Bool {
        startupState == .shuttingDown || startupState == .shutDown
    }
    var canOpenMedia: Bool {
        switch startupState {
        case .notStarted, .preparing, .ready: true
        case .failed, .shuttingDown, .shutDown: false
        }
    }

    var canControlPlayback: Bool { state.phase == .ready && state.snapshot != nil }
    var hasPlaybackHistoryStore: Bool { historyStore != nil }
    var hasMediaLibraryStore: Bool { historyStore is any MediaLibraryPersisting }
    var canSeek: Bool {
        guard canControlPlayback, let snapshot = state.snapshot,
              snapshot.isSeekable, let duration = snapshot.duration else { return false }
        return duration.isFinite && duration > 0
    }
    var isPaused: Bool {
        if let pendingPause { return pendingPause.isPaused }
        if let snapshot = state.snapshot { return snapshot.isPaused }
        return true
    }

    init(engine: any PlaybackEngine, historyStore: (any PlaybackHistoryPersisting)? = nil,
         preferences: PlaybackPreferences = PlaybackPreferences(), startupError: String? = nil) {
        self.engine = engine
        self.historyStore = historyStore
        self.preferences = preferences
        if let startupError { startupState = .failed(startupError) }
        engine.onEvent = { [weak self] event in self?.receive(event) }
    }

    func prepare() {
        guard startupState == .notStarted else { return }
        startupState = .preparing
        startupTask = Task { [weak self, engine] in
            do {
                try await engine.prepare()
                guard let self, self.startupState == .preparing else { return }
                self.startupState = .ready
                if let request = self.state.request { self.restoreAndOpen(request) }
            } catch {
                guard let self, self.startupState == .preparing else { return }
                self.startupState = .failed(error.localizedDescription)
            }
        }
    }

    func open(_ url: URL) {
        open(url, resumeMode: .preference)
    }

    func continuePlayback(_ url: URL) {
        open(url, resumeMode: .savedCheckpoint)
    }

    func playFromBeginning(_ url: URL) {
        open(url, resumeMode: .beginning)
    }

    func retryCurrentMedia() {
        guard canOpenMedia, case .failed = state.phase, let request = state.request else { return }
        openMedia(request.url, resumeMode: resumeMode)
    }

    private func open(_ url: URL, resumeMode: ResumeMode) {
        guard canOpenMedia else { return }
        mediaImportID += 1
        cancelPendingMediaImport()
        inputError = nil
        queue = PlaybackQueue(urls: [url], startingAt: url)
        openMedia(url, resumeMode: resumeMode)
    }

    /// Resolves file and folder inputs off the UI actor, then commits one ordered queue.
    func open(_ urls: [URL]) {
        guard !urls.isEmpty, let intent = beginInputResolution() else { return }
        open(urls, for: intent)
    }

    /// Reserves the latest user input before asynchronous providers have returned their URLs.
    func beginInputResolution() -> InputResolution? {
        guard canOpenMedia else { return nil }
        mediaImportID += 1
        cancelPendingMediaImport()
        inputError = nil
        return InputResolution(revision: mediaImportID)
    }

    /// A delayed input may commit only while it remains the most recent user choice.
    func open(_ urls: [URL], for intent: InputResolution) {
        guard canOpenMedia, intent.revision == mediaImportID else { return }
        guard !urls.isEmpty else {
            inputError = String(localized: "error.noPlayableMedia")
            return
        }
        let importID = intent.revision
        let discoveryTask = Task.detached(priority: .userInitiated) {
            try MediaFileDiscovery.expand(urls)
        }
        mediaDiscoveryTask = discoveryTask
        mediaImportTask = Task { [weak self] in
            do {
                let files = try await withTaskCancellationHandler {
                    try await discoveryTask.value
                } onCancel: {
                    discoveryTask.cancel()
                }
                guard !Task.isCancelled, let self, self.mediaImportID == importID else { return }
                self.mediaDiscoveryTask = nil
                guard !files.isEmpty else {
                    self.inputError = String(localized: "error.noPlayableMedia")
                    self.mediaImportTask = nil
                    return
                }
                self.queue = PlaybackQueue(urls: files)
                self.inputError = nil
                self.mediaImportTask = nil
                if let url = self.queue.currentURL { self.openMedia(url) }
            } catch {
                guard let self, self.mediaImportID == importID else { return }
                self.mediaDiscoveryTask = nil
                self.mediaImportTask = nil
                if !Task.isCancelled {
                    self.inputError = String(localized: "error.mediaImportFailed")
                }
            }
        }
    }

    func playQueueItem(at index: Int, requestID: UInt64) {
        guard canOpenMedia, state.request?.id == requestID, let url = queue.select(index) else { return }
        mediaImportID += 1
        cancelPendingMediaImport()
        inputError = nil
        openMedia(url)
    }

    func playNext() {
        guard canOpenMedia, let url = queue.advance() else { return }
        mediaImportID += 1
        cancelPendingMediaImport()
        openMedia(url)
    }

    func playPrevious() {
        guard canOpenMedia, let url = queue.goBack() else { return }
        mediaImportID += 1
        cancelPendingMediaImport()
        openMedia(url)
    }

    private func openMedia(_ url: URL, resumeMode: ResumeMode = .preference) {
        persistCurrentHistory()
        restorationTask?.cancel()
        lastRequestedVolume = nil
        nextRequestID += 1
        let request = PlaybackRequest(id: nextRequestID, url: url)
        self.resumeMode = resumeMode
        historySuppressedRequestID = nil
        resumeHistory = nil
        pendingPause = nil
        pendingSubtitleDelay = nil
        state.open(request)
        if isPrepared { restoreAndOpen(request) }
        prepare()
    }

    func togglePause() {
        if state.phase == .ended {
            replay()
            return
        }
        guard canControlPlayback, let request = state.request else { return }
        nextPauseCommandID += 1
        let pause = PlaybackPauseRequest(requestID: request.id,
            commandID: nextPauseCommandID, isPaused: !isPaused)
        pendingPause = pause
        engine.setPaused(pause)
    }

    func replay() {
        guard state.phase == .ended, let request = state.request else { return }
        openMedia(request.url, resumeMode: .beginning)
    }

    func seek(to seconds: Double, requestID: UInt64) {
        guard canSeek, let request = state.request, request.id == requestID,
              let duration = state.snapshot?.duration, seconds.isFinite else { return }
        engine.seek(PlaybackSeekRequest(requestID: request.id, target: .absolute(min(duration, max(0, seconds)))))
    }

    func skip(by seconds: Double) {
        guard canSeek, let request = state.request, seconds.isFinite, seconds != 0 else { return }
        engine.seek(PlaybackSeekRequest(requestID: request.id, target: .relative(seconds)))
    }

    func setVolume(_ volume: Double) {
        guard !isShuttingDown, isPrepared, volume.isFinite else { return }
        let value = min(100, max(0, volume))
        lastRequestedVolume = value
        engine.setVolume(value)
    }

    func setSpeed(_ speed: Double, requestID: UInt64) {
        guard canControlPlayback, state.request?.id == requestID, speed.isFinite else { return }
        engine.setSpeed(min(4, max(0.25, speed)))
    }

    func selectAudioTrack(_ id: Int, requestID: UInt64) {
        guard canControlPlayback, state.request?.id == requestID else { return }
        state.dismissCommandFailure()
        engine.setAudioTrack(id: id, requestID: requestID)
    }

    func selectSubtitleTrack(_ id: Int, requestID: UInt64) {
        guard canControlPlayback, state.request?.id == requestID else { return }
        state.dismissCommandFailure()
        engine.setSubtitleTrack(id: id, requestID: requestID)
    }

    func addExternalSubtitle(_ url: URL, requestID: UInt64) {
        guard canControlPlayback, state.request?.id == requestID else { return }
        state.dismissCommandFailure()
        engine.addExternalSubtitle(url, requestID: requestID)
    }

    func adjustSubtitleDelay(by seconds: Double, requestID: UInt64) {
        guard canControlPlayback, seconds.isFinite, state.request?.id == requestID else { return }
        let current = pendingSubtitleDelay ?? state.snapshot?.subtitleDelay ?? 0
        setSubtitleDelay(to: current + seconds, requestID: requestID)
    }

    func resetSubtitleDelay(requestID: UInt64) {
        guard canControlPlayback, state.request?.id == requestID else { return }
        setSubtitleDelay(to: 0, requestID: requestID)
    }

    private func setSubtitleDelay(to seconds: Double, requestID: UInt64) {
        guard seconds.isFinite else { return }
        let target = min(30, max(-30, seconds))
        pendingSubtitleDelay = target
        engine.setSubtitleDelay(target, requestID: requestID)
    }

    func dismissPersistenceError() { persistenceError = nil }
    func dismissInputError() { inputError = nil }
    func dismissCommandFailure() { state.dismissCommandFailure() }

    func reportHistoryClearError(_ error: Error) {
        if historyStore == nil {
            historyClearError = String(localized: "settings.historyUnavailable")
        } else {
            historyClearError = error.localizedDescription
        }
    }

    /// Flush the current checkpoint without stopping or reopening playback.
    func checkpointPlaybackHistory() async throws {
        guard !isShuttingDown else { throw CancellationError() }
        if let checkpoint = persistCurrentHistory() {
            try await checkpoint.value.get()
        } else {
            _ = await persistenceTask?.value
        }
    }

    func clearPlaybackHistory() async throws {
        guard let historyStore else {
            throw PlaybackHistoryError.libraryUnavailable
        }
        let requestID = state.request?.id
        let previousSuppressedRequestID = historySuppressedRequestID
        historySuppressedRequestID = requestID
        _ = await persistenceTask?.value
        do {
            try await historyStore.clearAll()
            persistenceError = nil
            historyClearError = nil
        } catch {
            if state.request?.id == requestID {
                historySuppressedRequestID = previousSuppressedRequestID
            }
            throw error
        }
    }

    func historyExcludedFolders() async throws -> [HistoryExcludedFolder] {
        guard let store = historyStore as? any MediaLibraryPersisting else {
            throw PlaybackHistoryError.libraryUnavailable
        }
        return try await store.historyExcludedFolders()
    }

    func setHistoryExcludedFolder(_ folder: URL, excluded: Bool) async throws {
        guard let store = historyStore as? any MediaLibraryPersisting else {
            throw PlaybackHistoryError.libraryUnavailable
        }
        try await store.setHistoryExcludedFolder(folder, excluded: excluded)
    }

    func removeHistoryExcludedFolder(_ folder: HistoryExcludedFolder) async throws {
        guard let store = historyStore as? any MediaLibraryPersisting else {
            throw PlaybackHistoryError.libraryUnavailable
        }
        try await store.removeHistoryExcludedFolder(folder)
    }

    func exportLibraryArchive() async throws -> Data {
        guard let store = historyStore as? any MediaLibraryPersisting else {
            throw PlaybackHistoryError.libraryUnavailable
        }
        try await checkpointPlaybackHistory()
        return try await store.exportArchive(settings: preferences.archiveSnapshot)
    }

    func previewLibraryArchive(_ data: Data) async throws -> MediaLibraryImportPreview {
        guard let store = historyStore as? any MediaLibraryPersisting else {
            throw PlaybackHistoryError.libraryUnavailable
        }
        return try await store.previewArchiveImport(data)
    }

    func importLibraryArchive(_ data: Data) async throws -> MediaLibraryImportResult {
        guard let store = historyStore as? any MediaLibraryPersisting else {
            throw PlaybackHistoryError.libraryUnavailable
        }
        let requestID = state.request?.id
        let previousSuppressedRequestID = historySuppressedRequestID
        historySuppressedRequestID = requestID
        _ = await persistenceTask?.value
        do {
            let result = try await store.importArchive(data)
            preferences.applyArchiveSettings(result.settings)
            dataManagementError = nil
            historySuppressedRequestID = nil
            persistCurrentHistory()
            return result
        } catch {
            if state.request?.id == requestID {
                historySuppressedRequestID = previousSuppressedRequestID
            }
            throw error
        }
    }

    func clearLibraryRecords() async throws {
        guard let store = historyStore as? any MediaLibraryPersisting else {
            throw PlaybackHistoryError.libraryUnavailable
        }
        let requestID = state.request?.id
        let previousSuppressedRequestID = historySuppressedRequestID
        historySuppressedRequestID = requestID
        _ = await persistenceTask?.value
        do {
            try await store.clearLibraryRecords()
            persistenceError = nil
            historyClearError = nil
            dataManagementError = nil
        } catch {
            if state.request?.id == requestID {
                historySuppressedRequestID = previousSuppressedRequestID
            }
            throw error
        }
    }

    func dismissDataManagementError() {
        dataManagementError = nil
    }

    func reportDataManagementError(_ error: Error) {
        dataManagementError = error.localizedDescription
    }

    func stop() {
        guard !isShuttingDown else { return }
        mediaImportID += 1
        cancelPendingMediaImport()
        persistCurrentHistory()
        restorationTask?.cancel()
        restorationTask = nil
        progressTask?.cancel()
        progressTask = nil
        state.stop()
        pendingPause = nil
        pendingSubtitleDelay = nil
        if isPrepared { engine.stop() }
    }

    func shutdown() async {
        if let shutdownTask { await shutdownTask.value; return }
        startupState = .shuttingDown
        let task = Task { [weak self] in
            guard let self else { return }
            await self.finishShutdown()
        }
        shutdownTask = task
        await task.value
    }

    private func finishShutdown() async {
        mediaImportID += 1
        let mediaImportTask = self.mediaImportTask
        let mediaDiscoveryTask = self.mediaDiscoveryTask
        cancelPendingMediaImport()
        await mediaImportTask?.value
        if let mediaDiscoveryTask { _ = try? await mediaDiscoveryTask.value }
        restorationTask?.cancel()
        restorationTask = nil
        progressTask?.cancel()
        await progressTask?.value
        progressTask = nil
        await persistCurrentHistoryAndWait()
        engine.onEvent = nil
        pendingPause = nil
        state.stop()
        let task = Task { [startupTask, engine] in
            // Initialization owns resources until it returns, even when the window closes early.
            await startupTask?.value
            await engine.shutdown()
        }
        await task.value
        startupState = .shutDown
    }

    private func cancelPendingMediaImport() {
        mediaImportTask?.cancel()
        mediaImportTask = nil
        mediaDiscoveryTask?.cancel()
        mediaDiscoveryTask = nil
    }

    private func receive(_ event: PlaybackEvent) {
        guard !isShuttingDown else { return }
        guard state.receive(event) else { return }
        if case .snapshot(let value) = event, value.requestID == state.request?.id,
           let lastRequestedVolume,
           let observedVolume = state.snapshot?.volume,
           abs(observedVolume - lastRequestedVolume) < 0.1 {
            self.lastRequestedVolume = nil
        }
        if case .snapshot(let value) = event, value.requestID == state.request?.id,
           let pendingSubtitleDelay,
           let observedDelay = state.snapshot?.subtitleDelay,
           abs(observedDelay - pendingSubtitleDelay) < 0.01 {
            self.pendingSubtitleDelay = nil
        }
        switch event {
        case .loaded(let requestID) where state.request?.id == requestID:
            if let resumeHistory {
                if let audioTrackID = resumeHistory.audioTrackID {
                    engine.setAudioTrack(id: audioTrackID, requestID: requestID)
                }
                if let subtitleTrackID = resumeHistory.subtitleTrackID {
                    engine.setSubtitleTrack(id: subtitleTrackID, requestID: requestID)
                }
                self.resumeHistory = nil
            }
            engine.setSpeed(preferences.defaultSpeed)
            engine.setSubtitleDelay(preferences.defaultSubtitleDelay, requestID: requestID)
            startProgressPersistence()
        case .ended(let requestID) where state.request?.id == requestID && state.phase == .ended:
            if preferences.automaticallyPlayNext, allowsAutomaticQueueAdvance,
               queue.advance() != nil, let nextURL = queue.currentURL {
                openMedia(nextURL)
            } else {
                progressTask?.cancel()
                progressTask = nil
                persistCurrentHistory()
            }
        case .failed(let requestID, _) where state.request?.id == requestID && isFailedPlayback:
            progressTask?.cancel()
            progressTask = nil
        default:
            break
        }
        guard state.phase == .ready else { pendingPause = nil; return }
        if let pendingPause, let snapshot = state.snapshot,
           snapshot.requestID == pendingPause.requestID,
           snapshot.pauseCommandID == pendingPause.commandID,
           snapshot.isPaused == pendingPause.isPaused {
            self.pendingPause = nil
        }
    }

    private var isFailedPlayback: Bool {
        if case .failed = state.phase { return true }
        return false
    }

    private var allowsAutomaticQueueAdvance: Bool {
        guard let duration = state.snapshot?.duration, duration.isFinite else { return false }
        return duration >= Self.minimumAutomaticNextDuration
    }

    private func restoreAndOpen(_ request: PlaybackRequest) {
        guard let historyStore else {
            engine.open(request, options: PlaybackOpenOptions())
            return
        }
        let pendingWrite = persistenceTask
        restorationTask?.cancel()
        restorationTask = Task { [weak self, engine] in
            do {
                _ = await pendingWrite?.value
                try Task.checkCancellation()
                let saved = try await historyStore.history(for: request.url)
                guard !Task.isCancelled, let self,
                      self.state.request?.id == request.id, self.isPrepared else { return }
                let shouldResumePosition: Bool
                switch self.resumeMode {
                case .preference: shouldResumePosition = self.preferences.resumeFromLastPosition
                case .savedCheckpoint: shouldResumePosition = true
                case .beginning: shouldResumePosition = false
                }
                let startPosition: PlaybackStartPosition?
                if shouldResumePosition, let saved {
                    startPosition = PlaybackStartPosition(seconds: saved.position)
                } else {
                    startPosition = nil
                }
                self.resumeHistory = saved
                if let saved {
                    self.lastRequestedVolume = saved.volume
                    engine.setVolume(saved.volume)
                }
                engine.open(request, options: PlaybackOpenOptions(startPosition: startPosition))
            } catch {
                guard !Task.isCancelled, let self,
                      self.state.request?.id == request.id, self.isPrepared else { return }
                if case PlaybackHistoryError.mediaFileUnavailable = error {
                    self.persistenceError = nil
                } else if case PlaybackHistoryError.ambiguousMediaIdentity = error {
                    self.historySuppressedRequestID = request.id
                    self.persistenceError = String(localized: "persistence.identityConflict")
                } else {
                    self.persistenceError = String(localized: "persistence.restoreFailed")
                }
                engine.open(request, options: PlaybackOpenOptions())
            }
        }
    }

    private func startProgressPersistence() {
        guard historyStore != nil, progressTask == nil else { return }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(5)) }
                catch { return }
                guard !Task.isCancelled, let self, !self.isShuttingDown else { return }
                self.persistCurrentHistory()
            }
        }
    }

    @discardableResult
    private func persistCurrentHistory() -> Task<Result<Void, Error>, Never>? {
        guard let historyStore, let request = state.request, let snapshot = state.snapshot,
              historySuppressedRequestID != request.id,
              snapshot.position.isFinite, snapshot.position >= 0 else { return nil }
        let position = snapshot.position
        let audioTrackID = snapshot.audioTrackID
        let subtitleTrackID = snapshot.subtitleTrackID
        let volume = lastRequestedVolume ?? min(100, max(0, snapshot.volume))
        let pendingWrite = persistenceTask
        persistenceTask = Task { [weak self, historyStore] in
            _ = await pendingWrite?.value
            do {
                try await historyStore.save(for: request.url, position: position,
                                            audioTrackID: audioTrackID,
                                            subtitleTrackID: subtitleTrackID,
                                            volume: volume, updatedAt: .now)
                self?.persistenceError = nil
                return .success(())
            } catch {
                self?.persistenceError = String(localized: "persistence.saveFailed")
                return .failure(error)
            }
        }
        return persistenceTask
    }

    private func persistCurrentHistoryAndWait() async {
        _ = await persistenceTask?.value
        guard let historyStore, let request = state.request, let snapshot = state.snapshot,
              historySuppressedRequestID != request.id,
              snapshot.position.isFinite, snapshot.position >= 0 else { return }
        do {
            try await historyStore.save(for: request.url, position: snapshot.position,
                                        audioTrackID: snapshot.audioTrackID,
                                        subtitleTrackID: snapshot.subtitleTrackID,
                                        volume: lastRequestedVolume ?? min(100, max(0, snapshot.volume)),
                                        updatedAt: .now)
            persistenceError = nil
        } catch {
            persistenceError = String(localized: "persistence.saveFailed")
        }
    }
}
