import Foundation
import LoffoDocument
import LoffoDomain

public actor LocalWorkspace: WorkspaceReading {
    private let io = BoundedIO()
    private let documents: DocumentStore
    private let git: GitRunner?
    public init(gitExecutable: URL?) {
        documents = DocumentStore(io: BoundedIO())
        git = gitExecutable.map(GitRunner.init)
    }

    public func read(_ url: URL) async throws -> TextSnapshot { try await documents.read(url) }

    public func files(in root: URL) async throws -> FileListing {
        if let git {
            let result: CommandOutput
            do {
                result = try await git.run(
                    ["ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "."], at: root)
            } catch is CancellationError { throw CancellationError() } catch {
                let listing = try await io.run { try Self.enumerate(root) }
                return FileListing(files: listing.files, isLimited: true, usesGitIgnore: false)
            }
            if result.status == 0 {
                return GitPathListing.decode(result.data)
            }
        }
        // Git missing, unsupported, or folder is not a repository: browsing still works.
        return try await io.run { try Self.enumerate(root) }
    }

    public func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput {
        guard let git else {
            throw WorkspaceFailure.unavailable(
                "Git is unavailable. Files remain readable; set LOFFO_GIT_EXECUTABLE to enable comparisons.")
        }
        try await validateComparison(in: root, path: path)
        let head = try await git.run(["rev-parse", "--verify", "HEAD^{commit}"], at: root)
        guard head.status == 0 else {
            throw WorkspaceFailure.unavailable(
                "No readable HEAD commit. Initial and untracked-file comparisons will be added later.")
        }
        let commit = String(decoding: head.data, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard commit.count >= 40, commit.allSatisfy(\.isHexDigit) else {
            throw WorkspaceFailure.unavailable("Git returned an invalid revision.")
        }
        // ls-tree resolves an immutable blob ID without executing working-tree filters.
        let tree = try await git.run(["ls-tree", "-z", commit, "--", path], at: root)
        guard tree.status == 0, let entry = tree.data.split(separator: 0).first,
            let tab = entry.firstIndex(of: 9)
        else {
            throw WorkspaceFailure.unsupportedComparison(
                "This file is not present in HEAD. Added-file comparison is not yet implemented.")
        }
        let metadata = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
        guard metadata.count == 3, metadata[1] == "blob", metadata[0] != "120000" else {
            throw WorkspaceFailure.binary
        }
        let object = String(metadata[2])
        let size = try await git.run(["cat-file", "-s", object], at: root)
        guard size.status == 0,
            let count = Int(
                String(decoding: size.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)),
            count <= 2 * 1024 * 1024
        else { throw WorkspaceFailure.tooLarge }
        let blob = try await git.run(["cat-file", "blob", object], at: root, limit: 2 * 1024 * 1024)
        guard blob.status == 0 else {
            throw WorkspaceFailure.unavailable("The baseline object is not available locally.")
        }
        let before = try TextLimits.decode(blob.data)
        // Conservatively refuse conversion cases until the full G2 matrix is verified.
        if before.contains("\r") || workingText.contains("\r") {
            throw WorkspaceFailure.unsupportedComparison(
                "CRLF/CR comparison is not yet validated. Use Files to read this document.")
        }
        return ComparisonInput(before: before, after: workingText, label: String(commit.prefix(7)))
    }

    public func changes(in root: URL) async throws -> FileListing {
        guard let git else { throw WorkspaceFailure.unavailable("Git is unavailable for this folder.") }
        // Fail closed before any worktree conversion if a filter driver is configured.
        let config = try await git.run(["config", "--null", "--get-regexp", "^filter\\."], at: root)
        guard config.status == 1 else {
            throw WorkspaceFailure.unsupportedComparison(
                "Changed-file listing is unavailable while Git filter drivers are configured. Files remain readable."
            )
        }
        let tracked = try await git.run(
            [
                "diff", "--no-ext-diff", "--no-textconv", "--name-status", "--no-renames", "-z", "HEAD",
                "--relative", "--", ".",
            ], at: root)
        guard tracked.status == 0 else {
            throw WorkspaceFailure.unavailable("A readable HEAD is required to list changes.")
        }
        let untracked = try await git.run(
            ["ls-files", "--others", "--exclude-standard", "-z", "--", "."], at: root)
        guard untracked.status == 0 else {
            throw WorkspaceFailure.unavailable("Untracked files could not be listed.")
        }
        let unmerged = try await git.run(["ls-files", "-u", "-z", "--", "."], at: root)
        guard unmerged.status == 0 else {
            throw WorkspaceFailure.unavailable("Unmerged index entries could not be listed.")
        }
        let checked = try await git.run(["config", "--null", "--get-regexp", "^filter\\."], at: root)
        guard checked.status == config.status, checked.data == config.data else {
            throw WorkspaceFailure.unsupportedComparison(
                "Git configuration changed during the scan. Reload to retry.")
        }
        return GitPathListing.changes(
            tracked: tracked.data, untracked: untracked.data, unmerged: unmerged.data)
    }

    public func history(in root: URL, path: String) async throws -> [FileCommit] {
        guard let git else { return [] }
        let result = try await git.run(
            ["log", "-3", "--format=%h%x00%ct%x00%s%x00", "HEAD", "--", path], at: root)
        guard result.status == 0 else { throw WorkspaceFailure.unavailable("File history is unavailable.") }
        let fields = result.data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        var commits: [FileCommit] = []
        // Git separates records with a newline after the trailing NUL. Empty output is valid history.
        var index = 0
        while index < fields.count {
            let id = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty && index == fields.count - 1 { break }
            guard index + 2 < fields.count, let seconds = TimeInterval(fields[index + 1]), seconds.isFinite,
                !id.isEmpty, id.allSatisfy(\.isHexDigit)
            else { throw WorkspaceFailure.unavailable("Git returned an invalid history record.") }
            commits.append(
                FileCommit(
                    id: id, subject: fields[index + 2],
                    committedAt: Date(timeIntervalSince1970: seconds)))
            index += 3
        }
        return commits
    }

    public func branch(in root: URL) async throws -> String {
        guard let git else { return "Local folder" }
        let result = try await git.run(["symbolic-ref", "--quiet", "--short", "HEAD"], at: root)
        if result.status == 1 { return "Detached HEAD" }
        guard result.status == 0 else {
            throw WorkspaceFailure.unavailable("The repository branch cannot be read.")
        }
        return String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func validateComparison(in root: URL, path: String) async throws {
        guard let git else { throw WorkspaceFailure.unavailable("Git is unavailable.") }
        let attributes = try await git.run(
            [
                "check-attr", "-z", "text", "eol", "filter", "working-tree-encoding", "ident", "diff", "--",
                path,
            ], at: root)
        guard attributes.status == 0 else {
            throw WorkspaceFailure.unavailable("This folder does not have an available Git baseline.")
        }
        let fields = attributes.data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        var attrs: [String: String] = [:]
        for offset in stride(from: 0, to: fields.count - 2, by: 3) {
            attrs[fields[offset + 1]] = fields[offset + 2]
        }
        for key in ["filter", "working-tree-encoding", "ident"] {
            if let value = attrs[key], value != "unspecified", value != "unset" {
                throw WorkspaceFailure.unsupportedAttribute(key)
            }
        }
        if attrs["diff"] == "unset" { throw WorkspaceFailure.binary }
    }

    private static func enumerate(_ root: URL) throws -> FileListing {
        // Foundation may canonicalize /var to /private/var while enumerating.
        let root = root.resolvingSymlinksInPath()
        let excluded: Set<String> = [
            ".git", ".build", "node_modules", "DerivedData", ".next", "build", "dist",
        ]
        let rootProperties = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard rootProperties.isDirectory == true else {
            throw WorkspaceFailure.unavailable("The folder cannot be read.")
        }
        var enumerationError: (any Error)?
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, error in
                    enumerationError = error
                    return false
                })
        else {
            throw WorkspaceFailure.unavailable("The folder cannot be read.")
        }
        var files: [ProjectFile] = []
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            if excluded.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if properties.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            let canonicalPath = url.resolvingSymlinksInPath().path
            if properties.isRegularFile == true, canonicalPath.hasPrefix(prefix) {
                files.append(ProjectFile(path: String(canonicalPath.dropFirst(prefix.count))))
            }
            if files.count >= 20_000 {
                return FileListing(
                    files: files.sorted { $0.path < $1.path }, isLimited: true, usesGitIgnore: false)
            }
        }
        if let enumerationError { throw enumerationError }
        return FileListing(files: files.sorted { $0.path < $1.path }, isLimited: false, usesGitIgnore: false)
    }
}
