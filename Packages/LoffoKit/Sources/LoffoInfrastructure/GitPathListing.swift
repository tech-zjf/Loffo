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

    /// Before the first commit, index entries that still exist in the working tree are additions.
    static func initial(cached: Data, missing: Data, untracked: Data, unmerged: Data) -> FileListing {
        let missingPaths = Set(missing.split(separator: 0).map(Data.init))
        var tracked = Data()
        var invalid = false
        for record in cached.split(separator: 0) {
            guard let tab = record.firstIndex(of: 9) else {
                invalid = true
                continue
            }
            let metadata = String(decoding: record[..<tab], as: UTF8.self).split(separator: " ")
            guard metadata.count == 3, metadata[0].count == 6 else {
                invalid = true
                continue
            }
            let path = record[record.index(after: tab)...]
            guard !missingPaths.contains(Data(path)) else { continue }
            tracked.append(contentsOf: ":000000 \(metadata[0]) 0 0 A\0".utf8)
            tracked.append(contentsOf: path)
            tracked.append(0)
        }
        let listing = changes(tracked: tracked, untracked: untracked, unmerged: unmerged)
        return FileListing(
            files: listing.files, isLimited: listing.isLimited || invalid, usesGitIgnore: true)
    }

    /// Decode `git diff --raw --no-renames -z` plus the NUL-delimited untracked listing.
    static func changes(tracked: Data, untracked: Data, unmerged: Data = Data()) -> FileListing {
        let untrackedRecords = untracked.split(separator: 0)
        var files: [String: FileChangeKind] = [:]
        var modeChanges: Set<String> = []
        var unsupportedTypes: Set<String> = []
        var invalidPaths = 0
        var index = 0
        let trackedRecords = tracked.split(separator: 0)
        while index + 1 < trackedRecords.count {
            let metadata = String(decoding: trackedRecords[index], as: UTF8.self).split(separator: " ")
            let pathData = Data(trackedRecords[index + 1])
            guard metadata.count == 5, metadata[0].hasPrefix(":"),
                let path = String(data: pathData, encoding: .utf8)
            else {
                invalidPaths += 1
                index += 2
                continue
            }
            let kind: FileChangeKind
            switch metadata[4].first {
            case "A": kind = .added
            case "D": kind = .deleted
            default: kind = .modified
            }
            files[path] = kind
            if kind == .modified && metadata[0].dropFirst() != metadata[1] { modeChanges.insert(path) }
            if ["120000", "160000"].contains(String(metadata[0].dropFirst()))
                || ["120000", "160000"].contains(String(metadata[1]))
            {
                unsupportedTypes.insert(path)
            }
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
            files: ordered.prefix(20_000).map {
                ProjectFile(
                    path: $0, changeKind: files[$0], hasModeChange: modeChanges.contains($0),
                    hasUnsupportedGitType: unsupportedTypes.contains($0))
            },
            isLimited: ordered.count > 20_000 || invalidPaths > 0 || index != trackedRecords.count,
            usesGitIgnore: true)
    }
}
