import Foundation
import LoffoDomain

/// A bounded observation, not a filesystem transaction. Watch events drive subsequent reads.
enum StableFileReader {
    private struct DirectoryIdentity {
        let name: String
        let device: dev_t
        let inode: ino_t
    }
    static func read(in root: URL, path: String, limit: Int) throws -> Data {
        try read(in: root, path: path, limit: limit, afterTraversal: {})
    }

    static func read(in root: URL, path: String, limit: Int, afterTraversal: () throws -> Void) throws -> Data
    {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !path.contains("\0"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw WorkspaceFailure.unavailable("The file path is outside the opened folder.") }
        let rootDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootDescriptor >= 0 else {
            throw WorkspaceFailure.unavailable("The opened folder is no longer available.")
        }
        defer { close(rootDescriptor) }
        var directory = dup(rootDescriptor)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        var ancestors: [DirectoryIdentity] = []
        for component in parts.dropLast() {
            let next = openat(directory, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                let failure = errno
                if failure == ELOOP || failure == ENOTDIR {
                    throw WorkspaceFailure.unavailable(
                        "A parent folder is a symbolic link or is no longer a directory.")
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
            }
            var info = stat()
            guard fstat(next, &info) == 0 else {
                let failure = errno
                close(next)
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
            }
            ancestors.append(
                DirectoryIdentity(name: String(component), device: info.st_dev, inode: info.st_ino))
            close(directory)
            directory = next
        }
        guard let name = parts.last else {
            throw WorkspaceFailure.unavailable("The file path is outside the opened folder.")
        }
        try afterTraversal()
        let result: Result<Data, any Error>
        do { result = .success(try read(directory: directory, name: String(name), limit: limit)) } catch {
            result = .failure(error)
        }
        try verifyDirectoryChain(root: root, descriptor: rootDescriptor, ancestors: ancestors)
        return try result.get()
    }

    private static func verifyDirectoryChain(root: URL, descriptor: Int32, ancestors: [DirectoryIdentity])
        throws
    {
        func verifyRoot() throws {
            var opened = stat()
            var path = stat()
            guard fstat(descriptor, &opened) == 0, lstat(root.path, &path) == 0,
                opened.st_dev == path.st_dev, opened.st_ino == path.st_ino, path.st_mode & S_IFMT == S_IFDIR
            else {
                throw WorkspaceFailure.unavailable(
                    "The file is changing during reading. Waiting for the next update.")
            }
        }
        try verifyRoot()
        var parent = dup(descriptor)
        guard parent >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(parent) }
        for identity in ancestors {
            let next = openat(parent, identity.name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                throw WorkspaceFailure.unavailable(
                    "The file is changing during reading. Waiting for the next update.")
            }
            var info = stat()
            let matches =
                fstat(next, &info) == 0 && info.st_dev == identity.device && info.st_ino == identity.inode
            close(parent)
            parent = next
            guard matches else {
                throw WorkspaceFailure.unavailable(
                    "The file is changing during reading. Waiting for the next update.")
            }
        }
        try verifyRoot()
    }

    private static func read(directory: Int32, name: String, limit: Int) throws -> Data {
        for _ in 0..<3 {
            let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard descriptor >= 0 else {
                let failure = errno
                if failure == ELOOP {
                    throw WorkspaceFailure.unavailable("Symbolic links cannot be opened as files.")
                }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
            }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            defer { try? handle.close() }
            var before = stat()
            guard fstat(descriptor, &before) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            guard before.st_mode & S_IFMT == S_IFREG else {
                throw WorkspaceFailure.unavailable("Only regular files can be opened in this prototype.")
            }
            guard before.st_size <= limit else { throw WorkspaceFailure.tooLarge }
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit else { throw WorkspaceFailure.tooLarge }
            var after = stat()
            var currentPath = stat()
            guard fstat(descriptor, &after) == 0,
                fstatat(directory, name, &currentPath, AT_SYMLINK_NOFOLLOW) == 0
            else { continue }
            if sameContentMetadata(before, after), after.st_dev == currentPath.st_dev,
                after.st_ino == currentPath.st_ino, data.count == Int(after.st_size)
            {
                return data
            }
        }
        throw WorkspaceFailure.unavailable(
            "The file is changing during reading. Waiting for the next update.")
    }

    static func read(_ url: URL, limit: Int) throws -> Data {
        let directory = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard directory >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { close(directory) }
        return try read(directory: directory, name: url.lastPathComponent, limit: limit)
    }

    private static func sameContentMetadata(_ a: stat, _ b: stat) -> Bool {
        a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
