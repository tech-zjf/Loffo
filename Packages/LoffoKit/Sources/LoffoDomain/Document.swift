import Foundation

public struct TextSnapshot: Sendable, Equatable {
    public let url: URL
    public let version: UInt64
    public let text: String
    public let byteCount: Int

    public init(url: URL, version: UInt64, text: String) {
        self.url = url
        self.version = version
        self.text = text
        self.byteCount = text.utf8.count
    }
}

public struct ProjectFile: Identifiable, Sendable, Hashable {
    public var id: String { path }
    public let path: String
    public let changeKind: FileChangeKind?
    public let hasModeChange: Bool
    public let hasUnsupportedGitType: Bool
    public init(
        path: String, changeKind: FileChangeKind? = nil, hasModeChange: Bool = false,
        hasUnsupportedGitType: Bool = false
    ) {
        self.path = path
        self.changeKind = changeKind
        self.hasModeChange = hasModeChange
        self.hasUnsupportedGitType = hasUnsupportedGitType
    }
}

public enum FileChangeKind: Sendable, Hashable {
    case untracked
    case added
    case modified
    case deleted
    case renamed
    case conflicted

    public var marker: String {
        switch self {
        case .untracked: "U"
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "C"
        }
    }

    public var accessibilityLabel: String {
        switch self {
        case .untracked: "Untracked"
        case .added: "Added"
        case .modified: "Modified"
        case .deleted: "Deleted"
        case .renamed: "Renamed"
        case .conflicted: "Conflicted"
        }
    }
}

public struct FileListing: Sendable {
    public let files: [ProjectFile]
    public let isLimited: Bool
    public let usesGitIgnore: Bool
    /// Full captured commit ID for a changes listing, when the provider supports Git revisions.
    public let revision: String?
    public init(files: [ProjectFile], isLimited: Bool, usesGitIgnore: Bool, revision: String? = nil) {
        self.files = files
        self.isLimited = isLimited
        self.usesGitIgnore = usesGitIgnore
        self.revision = revision
    }
}

/// Identifies the opened workspace directory for a single running application session.
/// It is intentionally process-local and must not be persisted as a document identity.
public struct WorkspaceRootIdentity: Sendable, Hashable {
    public let device: UInt64
    public let inode: UInt64

    public init(device: UInt64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }
}

public enum WorkspaceFailure: Error, Sendable, LocalizedError {
    case tooLarge, binary, invalidEncoding, workspaceRootChanged, workspaceRootChangedWhileOpening
    case workspaceRootTemporarilyUnavailable
    case unavailable(String)
    case unsupportedComparison(String)
    case unsupportedAttribute(String)
    public var errorDescription: String? {
        switch self {
        case .tooLarge: DomainStrings.text("This file exceeds the prototype's 2 MB reading limit.")
        case .binary:
            DomainStrings.text("This is a binary file. Image and binary previews are not available yet.")
        case .invalidEncoding:
            DomainStrings.text("This file is not valid UTF-8. Its contents have not been modified.")
        case .workspaceRootChanged:
            DomainStrings.text("The opened folder changed after it was selected.")
        case .workspaceRootChangedWhileOpening:
            DomainStrings.text("The opened folder changed while it was being opened.")
        case .workspaceRootTemporarilyUnavailable:
            DomainStrings.text("The opened folder is no longer available.")
        case .unavailable(let reason), .unsupportedComparison(let reason): DomainStrings.text(reason)
        case .unsupportedAttribute(let attribute):
            String(
                format: DomainStrings.text(
                    "This file uses %@. Reading is available; exact comparison is not supported by this prototype."
                ), attribute)
        }
    }
}

public enum SyntaxKind: Sendable, Hashable {
    case keyword, string, comment, number, type, importPath, functionCall, constructor, parameter
    case property, constant, heading, markup, link, code
}
public struct SyntaxSpan: Sendable {
    public let range: NSRange
    public let kind: SyntaxKind
    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

public struct SyntaxHighlights: Sendable {
    public let spans: [SyntaxSpan]
    public let isLimited: Bool
    public init(spans: [SyntaxSpan], isLimited: Bool) {
        self.spans = spans
        self.isLimited = isLimited
    }
}

public protocol SyntaxProviding: Sendable {
    func highlights(for snapshot: TextSnapshot) async -> [SyntaxSpan]
    func highlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights
    /// A transient input must not be retained for incremental parsing after the call returns.
    func transientHighlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights
}

extension SyntaxProviding {
    public func highlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights {
        SyntaxHighlights(spans: await highlights(for: snapshot), isLimited: false)
    }

    /// Providers that retain regular inputs must override this method to release transient inputs.
    public func transientHighlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights {
        await highlightsWithStatus(for: snapshot)
    }
}

public protocol WorkspaceReading: Sendable {
    func rootIdentity(at root: URL) async throws -> WorkspaceRootIdentity?
    func invalidateRepositoryScans(in root: URL)
    func changes(in root: URL) async throws -> FileListing
    func repositoryObservationRoots(in root: URL) async throws -> [URL]
    func repositoryObservationFiles(in root: URL) async throws -> [URL]
    func revalidateRepositoryObservationFiles(in root: URL) async throws -> [URL]
    func history(in root: URL, path: String) async throws -> [FileCommit]
    func repositoryHistory(
        in root: URL, revision: String?, offset: Int, limit: Int
    ) async throws -> RepositoryHistoryPage
    func branch(in root: URL) async throws -> String
    func validateComparison(in root: URL, path: String) async throws
    func files(in root: URL) async throws -> FileListing
    func read(_ url: URL) async throws -> TextSnapshot
    func readDeletedOrCurrent(_ url: URL) async throws -> TextSnapshot
    func read(in root: URL, path: String, allowMissing: Bool) async throws -> TextSnapshot
    func read(
        in root: URL, path: String, allowMissing: Bool,
        expectedRootIdentity: WorkspaceRootIdentity?
    ) async throws -> TextSnapshot
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput
}

extension WorkspaceReading {
    public func repositoryHistory(
        in root: URL, revision: String?, offset: Int, limit: Int
    ) async throws -> RepositoryHistoryPage {
        RepositoryHistoryPage(revision: revision, commits: [], nextOffset: offset, hasMore: false)
    }
}

public struct ComparisonInput: Sendable {
    public let before: String
    public let after: String
    public let label: String
    public let revision: String?
    public init(before: String, after: String, label: String, revision: String? = nil) {
        self.before = before
        self.after = after
        self.label = label
        self.revision = revision
    }
}

@MainActor public protocol ObservationLease: AnyObject {
    var isActive: Bool { get }
    func retry() async
    func cancel()
}
/// File content events are only emitted when every event in a batch is a regular-file modification.
/// Unknown, structural, dropped or coalesced events require a full rescan.
public enum WorkspaceChange: Sendable {
    case fileContents([URL])
    case rescan
}
extension ObservationLease { public func retry() async {} }
@MainActor public protocol FileObserving: AnyObject {
    func observeWorkspace(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) async
        -> any ObservationLease
    func observe(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> any ObservationLease
    func observeWorkspaceChanges(
        _ url: URL, onChange: @escaping @MainActor @Sendable (WorkspaceChange) -> Void
    ) async -> any ObservationLease
}

extension FileObserving {
    public func observeWorkspaceChanges(
        _ url: URL, onChange: @escaping @MainActor @Sendable (WorkspaceChange) -> Void
    ) async -> any ObservationLease {
        await observeWorkspace(url) { onChange(.rescan) }
    }
    public func observeWorkspace(
        _ url: URL, onChange: @escaping @MainActor @Sendable () -> Void
    ) async -> any ObservationLease {
        observe(url, onChange: onChange)
    }
}

extension WorkspaceReading {
    public func rootIdentity(at root: URL) async throws -> WorkspaceRootIdentity? { nil }
    public func read(
        in root: URL, path: String, allowMissing: Bool,
        expectedRootIdentity: WorkspaceRootIdentity?
    ) async throws -> TextSnapshot {
        guard expectedRootIdentity == nil else {
            throw WorkspaceFailure.unavailable(
                DomainStrings.text("This workspace provider cannot verify folder identity."))
        }
        return try await read(in: root, path: path, allowMissing: allowMissing)
    }
    public func invalidateRepositoryScans(in root: URL) {}
    public func repositoryObservationRoots(in root: URL) async throws -> [URL] { [] }
    public func repositoryObservationFiles(in root: URL) async throws -> [URL] { [] }
    public func revalidateRepositoryObservationFiles(in root: URL) async throws -> [URL] {
        try await repositoryObservationFiles(in: root)
    }
    public func readDeletedOrCurrent(_ url: URL) async throws -> TextSnapshot { try await read(url) }
    public func read(in root: URL, path: String, allowMissing: Bool) async throws -> TextSnapshot {
        let url = root.appendingPathComponent(path)
        return try await allowMissing ? readDeletedOrCurrent(url) : read(url)
    }
    public func changes(in root: URL) async throws -> FileListing { try await files(in: root) }
    public func history(in root: URL, path: String) async throws -> [FileCommit] { [] }
    public func branch(in root: URL) async throws -> String { "HEAD" }
    public func validateComparison(in root: URL, path: String) async throws {}
}
