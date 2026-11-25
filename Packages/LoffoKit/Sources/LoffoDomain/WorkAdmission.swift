import Foundation

/// App-owned admission for heavy CPU work. Queue entries retain input references, never parsed output.
public actor WorkAdmission {
    private struct Waiter {
        let id: UUID
        let bytes: Int
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let maximumJobs: Int
    private let maximumBytes: Int
    private var jobs = 0
    private var bytes = 0
    private var waiting: [Waiter] = []

    public init(maximumJobs: Int = 2, maximumBytes: Int = 64 * 1024 * 1024) {
        self.maximumJobs = max(1, maximumJobs)
        self.maximumBytes = max(1, maximumBytes)
    }
    public var activeJobs: Int { jobs }
    public var admittedBytes: Int { bytes }

    public func acquire(bytes requested: Int) async throws {
        try Task.checkCancellation()
        guard requested <= maximumBytes, waiting.count < 32 else {
            throw WorkspaceFailure.unavailable(
                "The shared processing budget is full. Retry after other work finishes.")
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiting.append(Waiter(id: id, bytes: requested, continuation: continuation))
                drain()
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        // Once admitted, the caller owns release even if cancellation raced with admission.
    }
    public func release(bytes released: Int) {
        jobs -= 1
        bytes -= released
        drain()
    }
    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }
    private func drain() {
        while let next = waiting.first, jobs < maximumJobs, bytes + next.bytes <= maximumBytes {
            waiting.removeFirst()
            jobs += 1
            bytes += next.bytes
            next.continuation.resume()
        }
    }
}
