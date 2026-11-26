import Foundation
import LoffoDomain

/// Keep the shared CPU reservation until detached work has actually exited, including on cancellation.
struct ProjectionWork: Sendable {
    let admission: WorkAdmission

    func run<T: Sendable>(bytes: Int, operation: @escaping @Sendable () throws -> T) async throws -> T {
        try await admission.acquire(bytes: bytes)
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        let result = await withTaskCancellationHandler {
            await task.result
        } onCancel: {
            task.cancel()
        }
        await admission.release(bytes: bytes)
        try Task.checkCancellation()
        return try result.get()
    }
}
