import Foundation
import Observation

/** 数据管理操作共享生命周期；替换记录时暂停写入，导出只等待已接受的修改。 */
@MainActor @Observable
final class MediaLibraryRecordOperations {
    private let library: MediaLibraryModel
    private let sync: MediaLibrarySyncCoordinator?
    private let player: PlayerModel
    private(set) var isWorking = false
    @ObservationIgnored private var completionTask: Task<Void, Never>?
    @ObservationIgnored private var isShuttingDown = false

    init(library: MediaLibraryModel, sync: MediaLibrarySyncCoordinator?, player: PlayerModel) {
        self.library = library
        self.sync = sync
        self.player = player
    }

    func clearRecords() async throws {
        try await perform { [player] in try await player.clearLibraryRecords() }
    }

    func clearHistory() async throws {
        try await perform { [player] in try await player.clearPlaybackHistory() }
    }

    func importArchive(_ data: Data) async throws -> MediaLibraryImportResult {
        try await perform { [player] in try await player.importLibraryArchive(data) }
    }

    func excludeHistory(in folder: URL) async throws {
        try await perform(replacingRecords: false) { [library, player] in
            // The store checks privacy within each history-write transaction, so scans
            // and playback may continue while the rule and old checkpoints change.
            try await player.setHistoryExcludedFolder(folder, excluded: true)
            await library.refresh()
            player.dismissDataManagementError()
        }
    }

    func removeHistoryExclusion(_ folder: HistoryExcludedFolder) async throws {
        try await perform(replacingRecords: false) { [library, player] in
            try await player.removeHistoryExcludedFolder(folder)
            await library.refresh()
            player.dismissDataManagementError()
        }
    }

    func exportArchive(to destination: URL) async throws {
        try await perform(replacingRecords: false) { [library, player] in
            await library.waitForPendingPreferences()
            let data = try await player.exportLibraryArchive()
            // Keep ownership until the atomic file write completes, including during app quit.
            try await Task.detached(priority: .userInitiated) {
                try data.write(to: destination, options: .atomic)
            }.value
            player.dismissDataManagementError()
        }
    }

    func shutdown() async {
        isShuttingDown = true
        await completionTask?.value
    }

    private func perform<Output: Sendable>(
        replacingRecords: Bool = true,
        _ action: @MainActor @escaping () async throws -> Output
    ) async throws -> Output {
        guard !isShuttingDown else { throw CancellationError() }
        guard !isWorking else { throw RecordOperationError.busy }
        isWorking = true
        let task = Task { @MainActor [library, sync] in
            if replacingRecords {
                await library.suspendRecordWrites()
                await sync?.suspendReconciliation()
            }
            let outcome: Result<Output, Error>
            do {
                outcome = .success(try await action())
            } catch {
                outcome = .failure(error)
            }
            if replacingRecords {
                await library.resumeRecordWrites()
                sync?.resumeReconciliation()
            }
            return try outcome.get()
        }
        completionTask = Task { _ = await task.result }
        defer { isWorking = false }
        return try await task.value
    }

    private enum RecordOperationError: LocalizedError {
        case busy

        var errorDescription: String? { String(localized: "settings.data.working") }
    }
}
