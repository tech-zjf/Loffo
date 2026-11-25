import Foundation

public struct CodeNavigation: Sendable {
    public let id = UUID()
    public let line: Int
    public init(line: Int) { self.line = max(0, line) }
}
