import Foundation
import LoffoDocument
import LoffoDomain
import os

public struct CommandOutput: Sendable {
    public let status: Int32
    public let data: Data
    public let error: String
}

/// Small, bounded plumbing commands only. Files prevent stdout/stderr pipe deadlocks.
/// Work runs on a dedicated two-operation queue, never on the UI/cooperative executor.
public final class GitRunner: Sendable {
    private let executable: URL
    private let work = BoundedIO(concurrency: 2)
    public init(executable: URL) { self.executable = executable }

    public func run(_ arguments: [String], at root: URL, limit: Int = 4 * 1024 * 1024) async throws
        -> CommandOutput
    {
        let executable = executable
        let cancellation = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            try await work.run {
                if cancellation.withLock({ $0 }) { throw CancellationError() }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "loffo-git-\(UUID())")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: directory) }
                let outputURL = directory.appendingPathComponent("stdout")
                let errorURL = directory.appendingPathComponent("stderr")
                FileManager.default.createFile(atPath: outputURL.path, contents: nil)
                FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                let output = try FileHandle(forWritingTo: outputURL)
                let error = try FileHandle(forWritingTo: errorURL)
                defer {
                    try? output.close()
                    try? error.close()
                }
                let process = Process()
                process.executableURL = executable
                process.currentDirectoryURL = root
                process.arguments =
                    [
                        "--no-lazy-fetch", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "-c",
                        "core.fsmonitor=false", "-c", "color.ui=false",
                    ] + arguments
                var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
                environment["GIT_NO_LAZY_FETCH"] = "1"
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["LC_ALL"] = "C"
                process.environment = environment
                process.standardOutput = output
                process.standardError = error
                let exited = DispatchSemaphore(value: 0)
                process.terminationHandler = { _ in exited.signal() }
                try process.run()
                let deadline = Date().addingTimeInterval(3)
                var exceeded = false
                while exited.wait(timeout: .now() + 0.025) == .timedOut {
                    let bytes = (try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    let errorBytes = (try? errorURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    if cancellation.withLock({ $0 }) || Date() > deadline || bytes > limit
                        || errorBytes > 64 * 1024
                    {
                        exceeded = true
                        process.terminate()
                        if exited.wait(timeout: .now() + 0.2) == .timedOut {
                            kill(process.processIdentifier, SIGKILL)
                            exited.wait()
                        }
                        break
                    }
                }
                if cancellation.withLock({ $0 }) { throw CancellationError() }
                if exceeded {
                    throw WorkspaceFailure.unavailable("Git exceeded the prototype's time or output budget.")
                }
                let reader = try FileHandle(forReadingFrom: outputURL)
                defer { try? reader.close() }
                let data = try reader.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit else { throw WorkspaceFailure.tooLarge }
                let errorReader = try FileHandle(forReadingFrom: errorURL)
                defer { try? errorReader.close() }
                let diagnostics = try errorReader.read(upToCount: 64 * 1024 + 1) ?? Data()
                guard diagnostics.count <= 64 * 1024 else { throw WorkspaceFailure.tooLarge }
                return CommandOutput(
                    status: process.terminationStatus, data: data,
                    error: String(decoding: diagnostics.prefix(4096), as: UTF8.self))
            }
        } onCancel: {
            cancellation.withLock { $0 = true }
        }
    }
}
