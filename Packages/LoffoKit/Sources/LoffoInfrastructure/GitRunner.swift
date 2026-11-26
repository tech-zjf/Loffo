import Foundation
import LoffoDocument
import LoffoDomain
import os

public struct CommandOutput: Sendable {
    public let status: Int32
    public let data: Data
    public let error: String
}

/// Small, bounded plumbing commands only. Both output streams are drained concurrently.
/// Work runs on a dedicated two-operation queue, never on the UI/cooperative executor.
public final class GitRunner: Sendable {
    private let executable: URL
    private let environmentOverride: [String: String]?
    private let timeoutNanoseconds: UInt64
    private let work = BoundedIO(concurrency: 2)
    public init(executable: URL) {
        self.executable = executable
        environmentOverride = nil
        timeoutNanoseconds = IsolatedGitProcess.defaultTimeoutNanoseconds
    }
    init(
        executable: URL, environment: [String: String]?,
        timeoutNanoseconds: UInt64 = IsolatedGitProcess.defaultTimeoutNanoseconds
    ) {
        self.executable = executable
        environmentOverride = environment
        self.timeoutNanoseconds = timeoutNanoseconds
    }

    public func run(_ arguments: [String], at root: URL, limit: Int = 4 * 1024 * 1024) async throws
        -> CommandOutput
    {
        let executable = executable
        let inheritedEnvironment = environmentOverride ?? ProcessInfo.processInfo.environment
        let timeoutNanoseconds = timeoutNanoseconds
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await work.run {
                if cancellation.withLock({ $0 }) { throw CancellationError() }
                let processArguments =
                    [
                        "--no-lazy-fetch", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c",
                        "core.fsmonitor=false", "-c", "color.ui=false",
                    ] + arguments
                var environment = inheritedEnvironment.filter { !$0.key.hasPrefix("GIT_") }
                environment["GIT_NO_LAZY_FETCH"] = "1"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["LC_ALL"] = "C"
                return try IsolatedGitProcess.run(
                    executable: executable, root: root, arguments: processArguments, environment: environment,
                    limit: limit, timeoutNanoseconds: timeoutNanoseconds,
                    isCancelled: { cancellation.withLock { $0 } })
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }
}
