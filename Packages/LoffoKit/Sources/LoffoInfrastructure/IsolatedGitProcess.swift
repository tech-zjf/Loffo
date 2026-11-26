import Darwin
import Foundation
import LoffoDomain

/// The unreaped leader reserves its process-group ID until group cleanup has been signalled.
enum IsolatedGitProcess {
    static let defaultTimeoutNanoseconds: UInt64 = 3_000_000_000
    static func run(
        executable: URL, root: URL, arguments: [String], environment: [String: String], limit: Int,
        timeoutNanoseconds: UInt64 = defaultTimeoutNanoseconds,
        isCancelled: @Sendable () -> Bool
    ) throws -> CommandOutput {
        guard limit >= 0, limit < Int.max else { throw WorkspaceFailure.tooLarge }
        let output = Pipe()
        let error = Pipe()
        defer {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? error.fileHandleForReading.close()
            try? error.fileHandleForWriting.close()
        }
        for handle in [output.fileHandleForReading, error.fileHandleForReading] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            guard flags >= 0, fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }
        var actions: posix_spawn_file_actions_t?
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        if #available(macOS 26.0, *) {
            try checked(posix_spawn_file_actions_addchdir(&actions, root.path))
        } else {
            try checked(posix_spawn_file_actions_addchdir_np(&actions, root.path))
        }
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        for (pipe, destination) in [(output, STDOUT_FILENO), (error, STDERR_FILENO)] {
            try checked(
                posix_spawn_file_actions_adddup2(
                    &actions, pipe.fileHandleForWriting.fileDescriptor, destination))
            try checked(posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor))
            try checked(posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor))
        }
        var attributes: posix_spawnattr_t?
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
        let argumentStrings = [executable.path] + arguments
        let environmentStrings = environment.map { "\($0.key)=\($0.value)" }
        guard (argumentStrings + environmentStrings).allSatisfy({ !$0.utf8.contains(0) }) else {
            throw WorkspaceFailure.unavailable("Git received an invalid argument or environment value.")
        }
        var argv = argumentStrings.map { strdup($0) }
        var envp = environmentStrings.map { strdup($0) }
        defer {
            for argument in argv { free(argument) }
            for value in envp { free(value) }
        }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM))
        }
        argv.append(nil)
        envp.append(nil)
        var pid: pid_t = 0
        try checked(posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp))
        try? output.fileHandleForWriting.close()
        try? error.fileHandleForWriting.close()
        var stdout = Data()
        var stderr = Data()
        var outputOpen = true
        var errorOpen = true
        let start = DispatchTime.now().uptimeNanoseconds
        let (sum, overflow) = start.addingReportingOverflow(timeoutNanoseconds)
        let deadline = overflow ? UInt64.max : sum
        var exceeded = false
        var cancelled = false
        var waitError: Int32?
        var info = siginfo_t()
        while true {
            do {
                try drain(
                    output.fileHandleForReading.fileDescriptor, into: &stdout, open: &outputOpen, limit: limit
                )
                try drain(
                    error.fileHandleForReading.fileDescriptor, into: &stderr, open: &errorOpen,
                    limit: 64 * 1_024)
            } catch let error as NSError {
                waitError = Int32(error.code)
                break
            }
            cancelled = isCancelled()
            if cancelled || DispatchTime.now().uptimeNanoseconds > deadline || stdout.count > limit
                || stderr.count > 64 * 1_024
            {
                exceeded = true
                kill(-pid, SIGTERM)
                usleep(200_000)
                break
            }
            info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) != 0 {
                if errno == EINTR { continue }
                waitError = errno
                break
            }
            if info.si_pid == pid { break }
            var descriptors = [
                pollfd(
                    fd: outputOpen ? output.fileHandleForReading.fileDescriptor : -1, events: Int16(POLLIN),
                    revents: 0),
                pollfd(
                    fd: errorOpen ? error.fileHandleForReading.fileDescriptor : -1, events: Int16(POLLIN),
                    revents: 0),
            ]
            if poll(&descriptors, nfds_t(descriptors.count), 25) < 0 && errno != EINTR {
                waitError = errno
                break
            }
        }
        if waitError == ECHILD { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ECHILD)) }
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while true {
            let result = waitpid(pid, &status, 0)
            if result == pid { break }
            if result < 0 && errno == EINTR { continue }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        if cancelled || isCancelled() { throw CancellationError() }
        if let waitError { throw NSError(domain: NSPOSIXErrorDomain, code: Int(waitError)) }
        if exceeded {
            throw WorkspaceFailure.unavailable("Git exceeded the prototype's time or output budget.")
        }
        // Bytes written between the last drain and leader exit still belong to this command.
        try drain(output.fileHandleForReading.fileDescriptor, into: &stdout, open: &outputOpen, limit: limit)
        try drain(
            error.fileHandleForReading.fileDescriptor, into: &stderr, open: &errorOpen, limit: 64 * 1_024)
        guard stdout.count <= limit, stderr.count <= 64 * 1_024 else { throw WorkspaceFailure.tooLarge }
        let exitStatus = (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
        return CommandOutput(
            status: exitStatus, data: stdout, error: String(decoding: stderr.prefix(4096), as: UTF8.self))
    }

    private static func drain(_ fd: Int32, into data: inout Data, open: inout Bool, limit: Int) throws {
        guard open else { return }
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while data.count <= limit {
            let capacity = min(buffer.count, limit + 1 - data.count)
            let count = Darwin.read(fd, &buffer, capacity)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                open = false
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }

    private static func checked(_ code: Int32) throws {
        guard code == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    }
}
