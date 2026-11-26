import Foundation
import LoffoDomain

/// Ends a window's wait on cancellation even if a provider ignores cancellation. The provider task
/// owns only the workspace and admission lease, never the window model.
@MainActor final class CancellableRead {
    private var continuation: CheckedContinuation<TextSnapshot, any Error>?
    private var task: Task<Void, Never>?

    func run(
        workspace: any WorkspaceReading, windowAdmission: WorkAdmission, appAdmission: WorkAdmission,
        root: URL, path: String,
        allowMissing: Bool
    ) async throws -> TextSnapshot {
        try Task.checkCancellation()
        let snapshot: TextSnapshot = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<TextSnapshot, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.task = Task { [weak self] in
                    let result: Result<TextSnapshot, any Error>
                    do {
                        try await windowAdmission.acquire(bytes: 1)
                        do {
                            try await appAdmission.acquire(bytes: 1)
                            let value: TextSnapshot
                            do {
                                try Task.checkCancellation()
                                value = try await workspace.read(
                                    in: root, path: path, allowMissing: allowMissing)
                                await appAdmission.release(bytes: 1)
                            } catch {
                                await appAdmission.release(bytes: 1)
                                throw error
                            }
                            await windowAdmission.release(bytes: 1)
                            result = .success(value)
                        } catch {
                            await windowAdmission.release(bytes: 1)
                            result = .failure(error)
                        }
                    } catch {
                        result = .failure(error)
                    }
                    self?.finish(result)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
        try Task.checkCancellation()
        return snapshot
    }

    private func cancel() {
        task?.cancel()
        task = nil
        let pending = continuation
        continuation = nil
        pending?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<TextSnapshot, any Error>) {
        task = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
