import Foundation

public struct CodeNavigation: Sendable {
    public let id: UUID
    public let line: Int
    public init(line: Int, id: UUID = UUID()) {
        self.id = id
        self.line = max(0, line)
    }
}
