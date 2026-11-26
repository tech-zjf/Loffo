import Combine
import Foundation

/// Owns only the transient confirmation; the pasteboard remains the caller's responsibility.
@MainActor final class CopyPathFeedback: ObservableObject {
    @Published private(set) var isCopied = false
    private let duration: Duration
    private var resetTask: Task<Void, Never>?
    private var generation = UUID()

    init(duration: Duration = .seconds(3)) { self.duration = duration }

    func copy(_ path: String, using write: (String) -> Bool) {
        guard write(path) else {
            reset()
            return
        }
        resetTask?.cancel()
        generation = UUID()
        let current = generation
        isCopied = true
        resetTask = Task { [weak self, duration] in
            do { try await Task.sleep(for: duration) } catch { return }
            guard let self, self.generation == current else { return }
            self.isCopied = false
        }
    }

    func reset() {
        resetTask?.cancel()
        resetTask = nil
        generation = UUID()
        isCopied = false
    }
}
