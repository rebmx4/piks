import Foundation

/// Bound expensive media operations without blocking the UI or an executor thread.
public actor MediaWorkGate {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Void, Error> }
    private let limit: Int
    private var active = Set<UUID>()
    private var waiters: [Waiter] = []
    public init(limit: Int = 1) { self.limit = max(1, limit) }

    public func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        let id = try await acquire()
        defer { release(id) }
        try Task.checkCancellation()
        return try await operation()
    }
    private func acquire() async throws -> UUID {
        try Task.checkCancellation()
        let id = UUID()
        if active.count < limit { active.insert(id); return id }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append(Waiter(id: id, continuation: continuation)) }
            }
        }, onCancel: { Task { await self.cancelWaiting(id) } })
        return id
    }
    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func release(_ id: UUID) {
        guard active.remove(id) != nil else { return }
        if !waiters.isEmpty {
            let next = waiters.removeFirst()
            active.insert(next.id); next.continuation.resume()
        }
    }
}
