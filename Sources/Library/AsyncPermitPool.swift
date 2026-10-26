import Foundation

/// Cancellation-aware FIFO admission for thumbnail and metadata workers.
actor AsyncPermitPool {
    struct Snapshot: Equatable, Sendable {
        let limit: Int
        let activeCount: Int
        let waitingCount: Int
    }

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        self.limit = max(1, limit)
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
        // Cancellation may arrive after a release has already admitted this waiter.
        // In that ordering cancelWaiter cannot find it, so return its permit here.
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    /// Existing workers finish normally when the budget shrinks. No queued work
    /// starts until the active count is below the new limit.
    func setLimit(_ limit: Int) {
        self.limit = max(1, limit)
        resumeWaitingTasks()
    }

    func snapshot() -> Snapshot {
        Snapshot(limit: limit, activeCount: activeCount, waitingCount: waiters.count)
    }

    func release() {
        precondition(activeCount > 0, "Every release must match an acquired permit")
        activeCount -= 1
        resumeWaitingTasks()
    }

    private func resumeWaitingTasks() {
        while activeCount < limit, !waiters.isEmpty {
            activeCount += 1
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
