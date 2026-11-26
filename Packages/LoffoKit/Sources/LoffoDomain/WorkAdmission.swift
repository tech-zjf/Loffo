import Foundation

/// App-owned admission for heavy CPU work. Queue entries retain input references, never parsed output.
public actor WorkAdmission {
    private struct Waiter {
        let id: UUID
        let bytes: Int
        let continuation: CheckedContinuation<Void, any Error>
        var bypasses = 0
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
    public var queuedJobs: Int { waiting.count }

    public func acquire(bytes requested: Int) async throws {
        try Task.checkCancellation()
        guard requested >= 0, requested <= maximumBytes, waiting.count < 32 else {
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
        drain()
    }
    private func drain() {
        while let first = waiting.first, jobs < maximumJobs {
            let available = maximumBytes - bytes
            let index: Int
            if first.bytes <= available {
                index = 0
            } else if first.bypasses < 2,
                let fitting = waiting.indices.dropFirst().first(where: { waiting[$0].bytes <= available })
            {
                // Limit bypasses so a large request eventually gets the capacity it needs.
                waiting[0].bypasses += 1
                index = fitting
            } else {
                break
            }
            let next = waiting.remove(at: index)
            jobs += 1
            bytes += next.bytes
            next.continuation.resume()
        }
    }
}
