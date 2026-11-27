import Darwin
import Foundation
import LoffoDocument
import LoffoDomain
import os

public actor LocalWorkspace: WorkspaceReading {
    private enum ScanKind: Hashable { case files, changes, observationFiles }
    private struct ScanKey: Hashable {
        let root: String
        let generation: UInt64
        let kind: ScanKind
    }
    private struct Scan {
        let id: UUID
        let task: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<FileListing, any Error>]
    }
    private struct ObservationScan {
        let id: UUID
        let task: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<[URL], any Error>]
    }
    private struct RevalidationScan {
        let key: ScanKey
        let task: Task<Void, Never>
        var subscribers: [UUID: CheckedContinuation<[URL], any Error>]
    }
    private struct ScanGenerations {
        var next: UInt64 = 0
        var fallback: UInt64 = 0
        var roots: [String: UInt64] = [:]

        mutating func invalidate(_ root: String) {
            next &+= 1
            if roots[root] == nil && roots.count >= 512 {
                roots.removeAll()
                fallback = next
            }
            roots[root] = next
        }
    }
    private nonisolated let scanGenerations = OSAllocatedUnfairLock(initialState: ScanGenerations())
    private var scans: [ScanKey: Scan] = [:]
    private var observationScans: [ScanKey: ObservationScan] = [:]
    private var pendingRevalidations: [ScanKey: UUID] = [:]
    private var revalidations: [UUID: RevalidationScan] = [:]
    private var revalidationOwners: [UUID: UUID] = [:]
    var activeScanSubscribers: Int { scans.values.reduce(0) { $0 + $1.subscribers.count } }
    var activeObservationSubscribers: Int { observationScans.values.reduce(0) { $0 + $1.subscribers.count } }
    var activeRevalidationSubscribers: Int { revalidationOwners.count }
    private let io = BoundedIO()
    private let documents: DocumentStore
    private let git: GitRunner?
    private let environmentOverride: [String: String]?
    private let revalidationDelayNanoseconds: UInt64
    public init(gitExecutable: URL?) {
        documents = DocumentStore(io: BoundedIO())
        git = gitExecutable.map(GitRunner.init)
        environmentOverride = nil
        revalidationDelayNanoseconds = 10_000_000
    }
    init(
        gitExecutable: URL?, environment: [String: String],
        gitTimeoutNanoseconds: UInt64 = IsolatedGitProcess.defaultTimeoutNanoseconds,
        revalidationDelayNanoseconds: UInt64 = 10_000_000
    ) {
        documents = DocumentStore(io: BoundedIO())
        git = gitExecutable.map {
            GitRunner(executable: $0, environment: environment, timeoutNanoseconds: gitTimeoutNanoseconds)
        }
        environmentOverride = environment
        self.revalidationDelayNanoseconds = revalidationDelayNanoseconds
    }

    public nonisolated func invalidateRepositoryScans(in root: URL) {
        let path = root.standardizedFileURL.path
        scanGenerations.withLock { $0.invalidate(path) }
    }

    nonisolated var scanGenerationEntryCount: Int { scanGenerations.withLock { $0.roots.count } }

    private func sharedScan(
        root: URL, kind: ScanKind, operation: @escaping @Sendable () async throws -> FileListing
    ) async throws -> FileListing {
        try Task.checkCancellation()
        let path = root.standardizedFileURL.path
        let generation = scanGenerations.withLock { $0.roots[path] ?? $0.fallback }
        let key = ScanKey(root: path, generation: generation, kind: kind)
        let subscriber = UUID()
        let result: FileListing = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<FileListing, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if scans[key] != nil {
                    scans[key]?.subscribers[subscriber] = continuation
                } else {
                    let id = UUID()
                    let task = Task {
                        do {
                            let listing = try await operation()
                            self.finishScan(key: key, id: id, result: .success(listing))
                        } catch {
                            self.finishScan(key: key, id: id, result: .failure(error))
                        }
                    }
                    scans[key] = Scan(id: id, task: task, subscribers: [subscriber: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelScanSubscriber(key: key, subscriber: subscriber) }
        }
        try Task.checkCancellation()
        return result
    }

    private func cancelScanSubscriber(key: ScanKey, subscriber: UUID) {
        guard let continuation = scans[key]?.subscribers.removeValue(forKey: subscriber) else { return }
        continuation.resume(throwing: CancellationError())
        if scans[key]?.subscribers.isEmpty == true { scans.removeValue(forKey: key)?.task.cancel() }
    }

    private func finishScan(key: ScanKey, id: UUID, result: Result<FileListing, any Error>) {
        guard scans[key]?.id == id, let scan = scans.removeValue(forKey: key) else { return }
        for subscriber in scan.subscribers.values { subscriber.resume(with: result) }
    }

    public func read(_ url: URL) async throws -> TextSnapshot { try await documents.read(url) }
    public func discardCachedSnapshots() async { await documents.discardCachedSnapshots() }
    #if DEBUG
        public var diagnosticCachedBytes: Int { get async { await documents.diagnosticCachedBytes } }
    #endif
    public func readDeletedOrCurrent(_ url: URL) async throws -> TextSnapshot {
        try await documents.readDeletedOrCurrent(url)
    }
    public func read(in root: URL, path: String, allowMissing: Bool) async throws -> TextSnapshot {
        try await documents.read(in: root, path: path, allowMissing: allowMissing)
    }

    public func rootIdentity(at root: URL) async throws -> WorkspaceRootIdentity? {
        try await documents.rootIdentity(at: root)
    }

    public func read(
        in root: URL, path: String, allowMissing: Bool,
        expectedRootIdentity: WorkspaceRootIdentity?
    ) async throws -> TextSnapshot {
        try await documents.read(
            in: root, path: path, allowMissing: allowMissing,
            expectedRootIdentity: expectedRootIdentity)
    }

    public func repositoryObservationRoots(in root: URL) async throws -> [URL] {
        guard let git else { return [] }
        var roots: Set<URL> = []
        // Parent .gitattributes files affect a project opened below the worktree root.
        for (index, argument) in ["--absolute-git-dir", "--git-common-dir", "--show-toplevel"].enumerated() {
            let result = try await git.run(["rev-parse", argument], at: root)
            if result.status != 0, index == 0 { return [] }
            guard result.status == 0, var path = String(data: result.data, encoding: .utf8),
                path.last == "\n"
            else { throw WorkspaceFailure.unavailable("Git metadata location is unavailable.") }
            path.removeLast()
            guard !path.isEmpty else {
                throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
            }
            let directory = URL(fileURLWithPath: root.path, isDirectory: true)
            let url = URL(fileURLWithPath: path, relativeTo: directory).standardizedFileURL
                .resolvingSymlinksInPath()
            roots.insert(url)
        }
        return roots.sorted { $0.path < $1.path }
    }

    public func repositoryObservationFiles(in root: URL) async throws -> [URL] {
        try Task.checkCancellation()
        let path = root.standardizedFileURL.path
        let generation = scanGenerations.withLock { $0.roots[path] ?? $0.fallback }
        let key = ScanKey(root: path, generation: generation, kind: .observationFiles)
        let subscriber = UUID()
        let result: [URL] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[URL], any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if observationScans[key] != nil {
                    observationScans[key]?.subscribers[subscriber] = continuation
                } else {
                    let id = UUID()
                    let task = Task {
                        do {
                            let files = try await self.discoverObservationFiles(in: root)
                            self.finishObservationScan(key: key, id: id, result: .success(files))
                        } catch {
                            self.finishObservationScan(key: key, id: id, result: .failure(error))
                        }
                    }
                    observationScans[key] = ObservationScan(
                        id: id, task: task, subscribers: [subscriber: continuation])
                }
            }
        } onCancel: {
            Task { await self.cancelObservationSubscriber(key: key, subscriber: subscriber) }
        }
        try Task.checkCancellation()
        return result
    }

    public func revalidateRepositoryObservationFiles(in root: URL) async throws -> [URL] {
        try Task.checkCancellation()
        let path = root.standardizedFileURL.path
        let generation = scanGenerations.withLock { $0.roots[path] ?? $0.fallback }
        let key = ScanKey(root: path, generation: generation, kind: .observationFiles)
        let subscriber = UUID()
        let result: [URL] = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<[URL], any Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                if let id = pendingRevalidations[key], revalidations[id] != nil {
                    revalidations[id]?.subscribers[subscriber] = continuation
                    revalidationOwners[subscriber] = id
                } else {
                    let id = UUID()
                    let task = Task {
                        do {
                            try await Task.sleep(nanoseconds: self.revalidationDelayNanoseconds)
                            self.startRevalidation(key: key, id: id)
                            let files = try await self.discoverObservationFiles(in: root)
                            self.finishRevalidation(id: id, result: .success(files))
                        } catch {
                            self.finishRevalidation(id: id, result: .failure(error))
                        }
                    }
                    pendingRevalidations[key] = id
                    revalidations[id] = RevalidationScan(
                        key: key, task: task, subscribers: [subscriber: continuation])
                    revalidationOwners[subscriber] = id
                }
            }
        } onCancel: {
            Task { await self.cancelRevalidationSubscriber(subscriber) }
        }
        try Task.checkCancellation()
        return result
    }

    private func startRevalidation(key: ScanKey, id: UUID) {
        if pendingRevalidations[key] == id { pendingRevalidations.removeValue(forKey: key) }
    }

    private func cancelRevalidationSubscriber(_ subscriber: UUID) {
        guard let id = revalidationOwners.removeValue(forKey: subscriber),
            let continuation = revalidations[id]?.subscribers.removeValue(forKey: subscriber)
        else { return }
        continuation.resume(throwing: CancellationError())
        if revalidations[id]?.subscribers.isEmpty == true, let scan = revalidations.removeValue(forKey: id) {
            if pendingRevalidations[scan.key] == id { pendingRevalidations.removeValue(forKey: scan.key) }
            scan.task.cancel()
        }
    }

    private func finishRevalidation(id: UUID, result: Result<[URL], any Error>) {
        guard let scan = revalidations.removeValue(forKey: id) else { return }
        if pendingRevalidations[scan.key] == id { pendingRevalidations.removeValue(forKey: scan.key) }
        for (subscriber, continuation) in scan.subscribers {
            revalidationOwners.removeValue(forKey: subscriber)
            continuation.resume(with: result)
        }
    }

    private func cancelObservationSubscriber(key: ScanKey, subscriber: UUID) {
        guard let continuation = observationScans[key]?.subscribers.removeValue(forKey: subscriber) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if observationScans[key]?.subscribers.isEmpty == true {
            observationScans.removeValue(forKey: key)?.task.cancel()
        }
    }

    private func finishObservationScan(key: ScanKey, id: UUID, result: Result<[URL], any Error>) {
        guard observationScans[key]?.id == id, let scan = observationScans.removeValue(forKey: key) else {
            return
        }
        for subscriber in scan.subscribers.values { subscriber.resume(with: result) }
    }

    private func discoverObservationFiles(in root: URL) async throws -> [URL] {
        guard let git else { return [] }
        let configured = try await git.run(
            ["config", "--null", "--path", "--get", "core.attributesFile"], at: root)
        guard configured.status == 0 || configured.status == 1 else {
            throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
        }
        let top = try await git.run(["rev-parse", "--show-toplevel"], at: root)
        guard top.status == 0, var topPath = String(data: top.data, encoding: .utf8), topPath.last == "\n"
        else { throw WorkspaceFailure.unavailable("Git metadata location is unavailable.") }
        topPath.removeLast()
        let base = URL(fileURLWithPath: topPath, isDirectory: true)
        var files: Set<URL> = []
        if configured.status == 0 {
            guard configured.data.last == 0,
                let path = String(data: configured.data.dropLast(), encoding: .utf8), !path.isEmpty
            else { throw WorkspaceFailure.unavailable("Git metadata location is unavailable.") }
            files.insert(URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL)
        } else {
            let environment = environmentOverride ?? ProcessInfo.processInfo.environment
            if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
                let directory = URL(fileURLWithPath: xdg, relativeTo: base).standardizedFileURL
                files.insert(directory.appendingPathComponent("git/attributes"))
            } else if let home = environment["HOME"], !home.isEmpty {
                let directory = URL(fileURLWithPath: home, relativeTo: base).standardizedFileURL
                files.insert(directory.appendingPathComponent(".config/git/attributes"))
            }
        }
        let origins = try await git.run(
            ["config", "--null", "--show-origin", "--name-only", "--list"], at: root)
        guard origins.status == 0, origins.data.isEmpty || origins.data.last == 0 else {
            throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
        }
        let fields = origins.data.split(separator: 0, omittingEmptySubsequences: false)
        guard fields.count % 2 == 1 else {
            throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
        }
        for index in stride(from: 0, to: fields.count - 1, by: 2) {
            guard let origin = String(data: fields[index], encoding: .utf8) else {
                throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
            }
            guard origin.hasPrefix("file:") else { continue }
            let source = URL(fileURLWithPath: String(origin.dropFirst(5)), relativeTo: base)
                .standardizedFileURL
            files.insert(source)
        }
        let includes = try await git.run(
            ["config", "--null", "--show-origin", "--get-regexp", "^include(if\\..*)?\\.path$"], at: root)
        guard includes.status == 0 || includes.status == 1,
            includes.data.isEmpty || includes.data.last == 0
        else { throw WorkspaceFailure.unavailable("Git metadata location is unavailable.") }
        let includeFields = includes.data.split(separator: 0, omittingEmptySubsequences: false)
        guard includeFields.count % 2 == 1 else {
            throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
        }
        for index in stride(from: 0, to: includeFields.count - 1, by: 2) {
            guard let origin = String(data: includeFields[index], encoding: .utf8) else {
                throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
            }
            guard origin.hasPrefix("file:") else { continue }
            let source = URL(fileURLWithPath: String(origin.dropFirst(5)), relativeTo: base)
                .standardizedFileURL
            guard let entry = String(data: includeFields[index + 1], encoding: .utf8),
                let newline = entry.firstIndex(of: "\n")
            else { continue }
            let key = entry[..<newline].lowercased()
            guard key == "include.path" || (key.hasPrefix("includeif.") && key.hasSuffix(".path")) else {
                continue
            }
            let path = String(entry[entry.index(after: newline)...])
            let expanded = (path as NSString).expandingTildeInPath
            let included = URL(fileURLWithPath: expanded, relativeTo: source.deletingLastPathComponent())
                .standardizedFileURL
            files.insert(included)
        }
        let configuredFiles = files
        return try await io.run {
            var candidates: Set<URL> = []
            for file in configuredFiles { candidates.formUnion(try Self.observationCandidates(file)) }
            return try Array(Set(candidates.map { try Self.existingParentObservationTarget($0) }))
                .sorted { $0.path < $1.path }
        }
    }

    /// Preserve every link and its eventual target, including targets that do not yet exist.
    private static func observationCandidates(_ file: URL) throws -> Set<URL> {
        var current = file.standardizedFileURL
        var result: Set<URL> = [current]
        var visited: Set<String> = []
        for _ in 0..<40 {
            guard visited.insert(current.path).inserted else {
                throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
            }
            let components = Array(current.pathComponents.dropFirst())
            var prefix = URL(fileURLWithPath: "/", isDirectory: true)
            var followed = false
            for (index, component) in components.enumerated() {
                prefix.appendPathComponent(component)
                var info = stat()
                if lstat(prefix.path, &info) != 0 {
                    guard errno == ENOENT else {
                        throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
                    }
                    return result
                }
                guard info.st_mode & S_IFMT == S_IFLNK else { continue }
                result.insert(prefix)
                let destination = try FileManager.default.destinationOfSymbolicLink(atPath: prefix.path)
                var resolved = URL(
                    fileURLWithPath: destination, relativeTo: prefix.deletingLastPathComponent()
                )
                .absoluteURL
                for remaining in components.dropFirst(index + 1) { resolved.appendPathComponent(remaining) }
                // Foundation maps /private/var back to /var when standardizing that directory.
                // Normalize components lexically so the same system link is not followed forever.
                var normalized: [Substring] = []
                for part in resolved.path.split(separator: "/") {
                    if part == "." { continue }
                    if part == ".." {
                        if !normalized.isEmpty { normalized.removeLast() }
                    } else {
                        normalized.append(part)
                    }
                }
                current = URL(fileURLWithPath: "/" + normalized.joined(separator: "/"))
                result.insert(current)
                followed = true
                break
            }
            if !followed { return result }
        }
        throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
    }

    /// Watch the first missing component so later directory creation advances the subscription.
    private static func existingParentObservationTarget(_ file: URL) throws -> URL {
        var target = file
        while true {
            let parent = target.deletingLastPathComponent()
            var info = stat()
            if stat(parent.path, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
                }
                return target
            }
            guard errno == ENOENT, parent.path != target.path else {
                throw WorkspaceFailure.unavailable("Git metadata location is unavailable.")
            }
            target = parent
        }
    }

    public func files(in root: URL) async throws -> FileListing {
        try await sharedScan(root: root, kind: .files) { try await self.scanFiles(in: root) }
    }

    private func scanFiles(in root: URL) async throws -> FileListing {
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
        let commit = try await Self.headRevision(git, in: root)
        guard !workingText.utf8.contains(13) else {
            throw WorkspaceFailure.unsupportedComparison(
                "CRLF/CR comparison is not yet validated. Use Files to read this document.")
        }
        if commit.hasPrefix("unborn:") {
            return ComparisonInput(before: "", after: workingText, label: "Initial", revision: commit)
        }
        // ls-tree resolves an immutable blob ID without executing working-tree filters.
        let tree = try await git.run(["ls-tree", "-z", commit, "--", path], at: root)
        guard tree.status == 0 else {
            throw WorkspaceFailure.unavailable("The baseline tree is not available locally.")
        }
        guard let entry = tree.data.split(separator: 0).first else {
            return ComparisonInput(
                before: "", after: workingText, label: String(commit.prefix(7)), revision: commit)
        }
        guard let tab = entry.firstIndex(of: 9) else {
            throw WorkspaceFailure.unavailable("Git returned an invalid baseline tree entry.")
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
            count >= 0
        else { throw WorkspaceFailure.unavailable("The baseline object is not available locally.") }
        guard count <= 2 * 1024 * 1024 else { throw WorkspaceFailure.tooLarge }
        let blob = try await git.run(["cat-file", "blob", object], at: root, limit: 2 * 1024 * 1024)
        guard blob.status == 0 else {
            throw WorkspaceFailure.unavailable("The baseline object is not available locally.")
        }
        let before = try TextLimits.decode(blob.data)
        // Conservatively refuse conversion cases until the full G2 matrix is verified.
        if before.utf8.contains(13) || workingText.utf8.contains(13) {
            throw WorkspaceFailure.unsupportedComparison(
                "CRLF/CR comparison is not yet validated. Use Files to read this document.")
        }
        return ComparisonInput(
            before: before, after: workingText, label: String(commit.prefix(7)), revision: commit)
    }

    public func changes(in root: URL) async throws -> FileListing {
        try await sharedScan(root: root, kind: .changes) { try await self.scanChanges(in: root) }
    }

    private func scanChanges(in root: URL) async throws -> FileListing {
        guard let git else { throw WorkspaceFailure.unavailable("Git is unavailable for this folder.") }
        let commit = try await Self.headRevision(git, in: root)
        // Fail closed before any worktree conversion if a filter driver is configured.
        let config = try await git.run(["config", "--null", "--get-regexp", "^filter\\."], at: root)
        guard config.status == 1 else {
            throw WorkspaceFailure.unsupportedComparison(
                "Changed-file listing is unavailable while Git filter drivers are configured. Files remain readable."
            )
        }
        let tracked: CommandOutput
        let missing: CommandOutput?
        if commit.hasPrefix("unborn:") {
            tracked = try await git.run(["ls-files", "--stage", "-z", "--", "."], at: root)
            missing = try await git.run(["ls-files", "--deleted", "-z", "--", "."], at: root)
        } else {
            tracked = try await git.run(
                [
                    "diff", "--no-ext-diff", "--no-textconv", "--raw", "--no-renames", "-z", commit,
                    "--relative", "--", ".",
                ], at: root)
            missing = nil
        }
        guard tracked.status == 0, missing?.status ?? 0 == 0 else {
            throw WorkspaceFailure.unavailable("Changed files could not be listed.")
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
        guard try await Self.headRevision(git, in: root) == commit else {
            throw WorkspaceFailure.unavailable("HEAD changed during the scan. Reload to retry.")
        }
        let listing: FileListing
        if let missing {
            listing = GitPathListing.initial(
                cached: tracked.data, missing: missing.data, untracked: untracked.data,
                unmerged: unmerged.data)
        } else {
            listing = GitPathListing.changes(
                tracked: tracked.data, untracked: untracked.data, unmerged: unmerged.data)
        }
        return FileListing(
            files: listing.files, isLimited: listing.isLimited, usesGitIgnore: listing.usesGitIgnore,
            revision: commit)
    }

    private static func headRevision(_ git: GitRunner, in root: URL) async throws -> String {
        let head = try await git.run(["rev-parse", "--verify", "HEAD^{commit}"], at: root)
        if head.status != 0 {
            let symbolic = try await git.run(["symbolic-ref", "--quiet", "HEAD"], at: root)
            guard symbolic.status == 0, var reference = String(data: symbolic.data, encoding: .utf8),
                reference.last == "\n"
            else { throw WorkspaceFailure.unavailable("No readable HEAD commit.") }
            reference.removeLast()
            guard reference.hasPrefix("refs/heads/") else {
                throw WorkspaceFailure.unavailable("No readable HEAD commit.")
            }
            let valid = try await git.run(["check-ref-format", reference], at: root)
            guard valid.status == 0 else { throw WorkspaceFailure.unavailable("No readable HEAD commit.") }
            let ref = try await git.run(["show-ref", "--verify", "--quiet", reference], at: root)
            guard ref.status == 1 else { throw WorkspaceFailure.unavailable("No readable HEAD commit.") }
            return "unborn:" + reference
        }
        let commit = String(decoding: head.data, as: UTF8.self).trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard commit.count == 40 || commit.count == 64, commit.allSatisfy(\.isHexDigit) else {
            throw WorkspaceFailure.unavailable("Git returned an invalid revision.")
        }
        return commit
    }

    public func history(in root: URL, path: String) async throws -> [FileCommit] {
        guard let git else { return [] }
        let revision = try await Self.headRevision(git, in: root)
        if revision.hasPrefix("unborn:") { return [] }
        let result = try await git.run(
            ["log", "-3", "--format=%h%x00%ct%x00%s%x00", revision, "--", path], at: root)
        guard result.status == 0 else { throw WorkspaceFailure.unavailable("File history is unavailable.") }
        guard try await Self.headRevision(git, in: root) == revision else {
            throw WorkspaceFailure.unavailable("HEAD changed during the scan. Reload to retry.")
        }
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

    public func repositoryHistory(
        in root: URL, revision expectedRevision: String?, offset: Int, limit: Int
    ) async throws -> RepositoryHistoryPage {
        guard let git else {
            return RepositoryHistoryPage(
                revision: nil, commits: [], nextOffset: offset, hasMore: false)
        }
        let pageOffset = min(max(offset, 0), 200)
        let pageLimit = min(max(limit, 1), 40)
        let head = try await Self.headRevision(git, in: root)
        guard !head.hasPrefix("unborn:") else {
            return RepositoryHistoryPage(revision: head, commits: [], nextOffset: pageOffset, hasMore: false)
        }
        if let expectedRevision, expectedRevision != head {
            throw WorkspaceFailure.unavailable("HEAD changed during the scan. Reload to retry.")
        }
        let pageRevision = expectedRevision ?? head
        let remainingBudget = 200 - pageOffset
        guard remainingBudget > 0 else {
            return RepositoryHistoryPage(
                revision: pageRevision, commits: [], nextOffset: pageOffset, hasMore: false)
        }
        let boundedPageLimit = min(pageLimit, remainingBudget)
        let output = try await git.run(
            [
                "log", "--max-count=\(boundedPageLimit + 1)", "--skip=\(pageOffset)",
                "--format=%H%x00%ct%x00%s%x00", pageRevision,
            ], at: root, limit: 128 * 1024)
        guard output.status == 0 else {
            throw WorkspaceFailure.unavailable("File history is unavailable.")
        }
        guard try await Self.headRevision(git, in: root) == pageRevision else {
            throw WorkspaceFailure.unavailable("HEAD changed during the scan. Reload to retry.")
        }
        let fields = output.data.split(separator: 0, omittingEmptySubsequences: false).map {
            String(decoding: $0, as: UTF8.self)
        }
        var commits: [FileCommit] = []
        var index = 0
        while index < fields.count {
            let id = fields[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if id.isEmpty && index == fields.count - 1 { break }
            guard index + 2 < fields.count, let seconds = TimeInterval(fields[index + 1]), seconds.isFinite,
                id.count == 40 || id.count == 64, id.allSatisfy(\.isHexDigit)
            else { throw WorkspaceFailure.unavailable("Git returned an invalid history record.") }
            commits.append(
                FileCommit(
                    id: id, subject: fields[index + 2],
                    committedAt: Date(timeIntervalSince1970: seconds)))
            index += 3
        }
        let hasMore = commits.count > boundedPageLimit && boundedPageLimit < remainingBudget
        if commits.count > boundedPageLimit { commits.removeLast() }
        return RepositoryHistoryPage(
            revision: pageRevision, commits: commits, nextOffset: pageOffset + commits.count,
            hasMore: hasMore)
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
