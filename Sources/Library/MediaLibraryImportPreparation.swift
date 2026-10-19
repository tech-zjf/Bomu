import Foundation
import Observation

/// Settings owns preparation; application-owned record operations own confirmed imports.
@MainActor @Observable
final class MediaLibraryImportPreparation {
    struct Prepared {
        let data: Data
        let preview: MediaLibraryImportPreview
    }

    enum Phase {
        case idle
        case reading
        case ready(Prepared)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    private let read: @Sendable (URL) async throws -> Data

    init(read: @escaping @Sendable (URL) async throws -> Data = MediaLibraryArchive.readForImport) {
        self.read = read
    }

    var prepared: Prepared? {
        guard case .ready(let prepared) = phase else { return nil }
        return prepared
    }

    @discardableResult
    func prepare(from url: URL,
                 preview: @escaping @MainActor (Data) async throws -> MediaLibraryImportPreview) -> Task<Void, Never> {
        cancel()
        phase = .reading
        let generation = generation
        let read = read
        let preparation = Task { [weak self] in
            let result: Result<Prepared, Error>
            do {
                let data = try await read(url)
                try Task.checkCancellation()
                let summary = try await preview(data)
                try Task.checkCancellation()
                result = .success(Prepared(data: data, preview: summary))
            } catch {
                result = .failure(error)
            }
            self?.finish(result, generation: generation)
        }
        task = preparation
        return preparation
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func finish(_ result: Result<Prepared, Error>, generation: UUID) {
        guard self.generation == generation else { return }
        task = nil
        switch result {
        case .success(let prepared): phase = .ready(prepared)
        case .failure(is CancellationError): phase = .idle
        case .failure(let error): phase = .failed(error.localizedDescription)
        }
    }
}
