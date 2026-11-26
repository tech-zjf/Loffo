import Foundation
import os

/// Blocking file work stays off both MainActor and Swift's cooperative executor.
public final class BoundedIO: Sendable {
    private let queue: OperationQueue
    var operationCount: Int { queue.operationCount }
    public init(concurrency: Int = 2) {
        queue = OperationQueue()
        queue.name = "app.loffo.file-io"
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = .userInitiated
    }
    public func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let value: T = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.addOperation {
                    if cancelled.withLock({ $0 }) {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do { continuation.resume(returning: try operation()) } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
        try Task.checkCancellation()
        return value
    }
}
