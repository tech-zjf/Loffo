import Foundation

/// Blocking file work stays off both MainActor and Swift's cooperative executor.
public final class BoundedIO: Sendable {
    private let queue: OperationQueue
    public init(concurrency: Int = 2) {
        queue = OperationQueue()
        queue.name = "app.loffo.file-io"
        queue.maxConcurrentOperationCount = concurrency
        queue.qualityOfService = .userInitiated
    }
    public func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value: T = try await withCheckedThrowingContinuation { continuation in
            queue.addOperation {
                do { continuation.resume(returning: try operation()) } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        try Task.checkCancellation()
        return value
    }
}
