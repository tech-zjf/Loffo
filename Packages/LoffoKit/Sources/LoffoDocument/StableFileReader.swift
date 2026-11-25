import Foundation
import LoffoDomain

/// A bounded observation, not a filesystem transaction. Watch events drive subsequent reads.
enum StableFileReader {
    static func read(_ url: URL, limit: Int) throws -> Data {
        for _ in 0..<3 {
            // Do not follow a final-component symlink swapped in between validation and open.
            let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
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
            guard fstat(descriptor, &after) == 0, lstat(url.path, &currentPath) == 0 else { continue }
            if sameContentMetadata(before, after), after.st_dev == currentPath.st_dev,
                after.st_ino == currentPath.st_ino, data.count == Int(after.st_size)
            {
                return data
            }
        }
        throw WorkspaceFailure.unavailable(
            "The file is changing during reading. Waiting for the next update.")
    }

    private static func sameContentMetadata(_ a: stat, _ b: stat) -> Bool {
        a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec
            && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec
            && a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec
            && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
