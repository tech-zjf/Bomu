import AppKit
import Foundation

/// Reconciles saved local folders at launch, after volume changes, and periodically to recover missed events.
@MainActor
final class MediaLibrarySyncCoordinator {
    private let historyStore: PlaybackHistoryStore
    private let scanner: MediaLibraryScanner
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var observers: [NSObjectProtocol] = []
    private var periodicTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var isStopping = false
    private let didReconcile: @MainActor () async -> Void

    init(historyStore: PlaybackHistoryStore,
         didReconcile: @escaping @MainActor () async -> Void = {}) {
        self.historyStore = historyStore
        scanner = MediaLibraryScanner(historyStore: historyStore)
        self.didReconcile = didReconcile
    }

    func start() {
        guard periodicTask == nil, !isStopping else { return }
        for notification in [NSWorkspace.didMountNotification,
                             NSWorkspace.didUnmountNotification] {
            observers.append(workspaceCenter.addObserver(forName: notification, object: nil, queue: .main) {
                [weak self] _ in
                Task { @MainActor [weak self] in self?.scheduleReconciliation() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleReconciliation() }
        })

        scheduleReconciliation()
        periodicTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(600)) }
                catch { return }
                self?.scheduleReconciliation()
            }
        }
    }

    func refresh() {
        scheduleReconciliation()
    }

    func stop() async {
        if let stopTask {
            await stopTask.value
            return
        }

        isStopping = true
        periodicTask?.cancel()
        periodicTask = nil
        for observer in observers {
            workspaceCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        let scanTask = self.scanTask
        self.scanTask = nil
        stopTask = Task { @MainActor in
            scanTask?.cancel()
            await scanTask?.value
        }
        await stopTask?.value
    }

    private func scheduleReconciliation() {
        guard !isStopping else { return }
        scanTask?.cancel()
        scanTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) }
            catch { return }
            await self?.reconcileMountedRoots()
        }
    }

    private func reconcileMountedRoots() async {
        let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeUUIDStringKey],
            options: []
        ) ?? []
        var mountedVolumes: [String: URL] = [:]
        for volumeURL in volumeURLs {
            let volumeID = try? volumeURL.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
            guard let volumeID, !volumeID.isEmpty else { continue }
            mountedVolumes[volumeID] = volumeURL
        }

        do {
            let roots = try await historyStore.sourceRoots(mountedVolumeIDs: Set(mountedVolumes.keys))
            for root in roots where root.isOnline {
                guard !Task.isCancelled, let volumeURL = mountedVolumes[root.volumeID] else { return }
                let folder: URL
                if root.relativePath.isEmpty {
                    folder = volumeURL
                } else {
                    folder = volumeURL.appending(path: root.relativePath, directoryHint: .isDirectory)
                }
                let isDirectory = (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                guard isDirectory else { continue }
                do {
                    for try await _ in scanner.scan(folder: folder, includingSubfolders: root.includingSubfolders) {
                        try Task.checkCancellation()
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // A partial scan is retained as evidence by the store; the next scheduled pass retries it.
                }
            }
        } catch {
            // Keep the saved source rows intact; the next mount, activation, or periodic pass retries.
        }
        guard !Task.isCancelled else { return }
        await didReconcile()
    }
}
