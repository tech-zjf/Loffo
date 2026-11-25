import Foundation
import LoffoDomain

/// Git paths are byte strings. Invalid UTF-8 must make the listing explicitly incomplete.
enum GitPathListing {
    static func decode(_ data: Data) -> FileListing {
        let records = data.split(separator: 0)
        let paths = records.compactMap { String(data: Data($0), encoding: .utf8) }
        let unique = Set(paths).sorted()
        return FileListing(
            files: unique.prefix(20_000).map { ProjectFile(path: $0) },
            isLimited: unique.count > 20_000 || paths.count != records.count, usesGitIgnore: true)
    }

    /// Decode `git diff --name-status --no-renames -z` plus the NUL-delimited untracked listing.
    static func changes(tracked: Data, untracked: Data, unmerged: Data = Data()) -> FileListing {
        let untrackedRecords = untracked.split(separator: 0)
        var files: [String: FileChangeKind] = [:]
        var invalidPaths = 0
        var index = 0
        let trackedRecords = tracked.split(separator: 0)
        while index + 1 < trackedRecords.count {
            let status = String(decoding: trackedRecords[index], as: UTF8.self)
            let pathData = Data(trackedRecords[index + 1])
            guard let path = String(data: pathData, encoding: .utf8) else {
                invalidPaths += 1
                index += 2
                continue
            }
            let kind: FileChangeKind
            switch status.first {
            case "A": kind = .added
            case "D": kind = .deleted
            default: kind = .modified
            }
            files[path] = kind
            index += 2
        }
        for record in untrackedRecords {
            guard let path = String(data: Data(record), encoding: .utf8) else {
                invalidPaths += 1
                continue
            }
            files[path] = .untracked
        }
        let unmergedRecords = unmerged.split(separator: 0)
        for record in unmergedRecords {
            guard let separator = record.firstIndex(of: 9),
                let path = String(data: Data(record[record.index(after: separator)...]), encoding: .utf8)
            else {
                invalidPaths += 1
                continue
            }
            files[path] = .conflicted
        }
        let ordered = files.keys.sorted()
        return FileListing(
            files: ordered.prefix(20_000).map { ProjectFile(path: $0, changeKind: files[$0]) },
            isLimited: ordered.count > 20_000 || invalidPaths > 0,
            usesGitIgnore: true)
    }
}
