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
