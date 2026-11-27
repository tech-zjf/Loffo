import Foundation

public struct FileCommit: Identifiable, Sendable {
    public let id: String
    public let subject: String
    public let committedAt: Date?
    public init(id: String, subject: String, committedAt: Date? = nil) {
        self.id = id
        self.subject = subject
        self.committedAt = committedAt
    }
}

/// One bounded page of local repository history, read against a fixed HEAD revision.
public struct RepositoryHistoryPage: Sendable {
    public let revision: String?
    public let commits: [FileCommit]
    public let nextOffset: Int
    public let hasMore: Bool

    public init(revision: String?, commits: [FileCommit], nextOffset: Int, hasMore: Bool) {
        self.revision = revision
        self.commits = commits
        self.nextOffset = nextOffset
        self.hasMore = hasMore
    }
}
