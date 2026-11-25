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
    public init(path: String, changeKind: FileChangeKind? = nil) {
        self.path = path
        self.changeKind = changeKind
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
    public init(files: [ProjectFile], isLimited: Bool, usesGitIgnore: Bool) {
        self.files = files
        self.isLimited = isLimited
        self.usesGitIgnore = usesGitIgnore
    }
}

public enum WorkspaceFailure: Error, Sendable, LocalizedError {
    case tooLarge, binary, invalidEncoding
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
        case .unavailable(let reason), .unsupportedComparison(let reason): DomainStrings.text(reason)
        case .unsupportedAttribute(let attribute):
            String(
                format: DomainStrings.text(
                    "This file uses %@. Reading is available; exact comparison is not supported by this prototype."
                ), attribute)
        }
    }
}

public enum SyntaxKind: Sendable, Hashable { case keyword, string, comment, number, type, importPath }
public struct SyntaxSpan: Sendable {
    public let range: NSRange
    public let kind: SyntaxKind
    public init(range: NSRange, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

public protocol SyntaxProviding: Sendable {
    func highlights(for snapshot: TextSnapshot) async -> [SyntaxSpan]
}

public protocol WorkspaceReading: Sendable {
    func changes(in root: URL) async throws -> FileListing
    func history(in root: URL, path: String) async throws -> [FileCommit]
    func branch(in root: URL) async throws -> String
    func validateComparison(in root: URL, path: String) async throws
    func files(in root: URL) async throws -> FileListing
    func read(_ url: URL) async throws -> TextSnapshot
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput
}

public struct ComparisonInput: Sendable {
    public let before: String
    public let after: String
    public let label: String
    public init(before: String, after: String, label: String) {
        self.before = before
        self.after = after
        self.label = label
    }
}

@MainActor public protocol ObservationLease: AnyObject { func cancel() }
@MainActor public protocol FileObserving: AnyObject {
    func observeWorkspace(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void)
        -> any ObservationLease
    func observe(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> any ObservationLease
}

extension FileObserving {
    public func observeWorkspace(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void)
        -> any ObservationLease
    {
        observe(url, onChange: onChange)
    }
}

extension WorkspaceReading {
    public func changes(in root: URL) async throws -> FileListing { try await files(in: root) }
    public func history(in root: URL, path: String) async throws -> [FileCommit] { [] }
    public func branch(in root: URL) async throws -> String { "HEAD" }
    public func validateComparison(in root: URL, path: String) async throws {}
}
