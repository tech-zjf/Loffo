import Foundation

/// Window intent and shared document progress are deliberately separate.
public struct PresentationStamp: Sendable, Equatable {
    public let intent: UUID
    public let contentVersion: UInt64
    public let refinement: UInt64
    public init(intent: UUID, contentVersion: UInt64, refinement: UInt64 = 0) {
        self.intent = intent
        self.contentVersion = contentVersion
        self.refinement = refinement
    }
}

public struct PublicationGate: Sendable {
    public private(set) var intent = UUID()
    public private(set) var accepted: PresentationStamp?
    public init() {}
    @discardableResult public mutating func reset() -> UUID {
        intent = UUID()
        accepted = nil
        return intent
    }
    public mutating func accept(_ stamp: PresentationStamp) -> Bool {
        guard stamp.intent == intent else { return false }
        if let accepted {
            guard
                stamp.contentVersion > accepted.contentVersion
                    || (stamp.contentVersion == accepted.contentVersion
                        && stamp.refinement > accepted.refinement)
            else { return false }
        }
        accepted = stamp
        return true
    }
}

public enum DiffKind: Sendable, Equatable { case context, added, removed }
public struct DiffLine: Sendable, Equatable {
    public let text: String
    public let kind: DiffKind
    public let oldNumber: Int?
    public let newNumber: Int?
    public init(text: String, kind: DiffKind, oldNumber: Int?, newNumber: Int?) {
        self.text = text
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffResult: Sendable {
    public let lines: [DiffLine]
    public let isCoarse: Bool
    public var added: Int { lines.reduce(0) { $0 + ($1.kind == .added ? 1 : 0) } }
    public var removed: Int { lines.reduce(0) { $0 + ($1.kind == .removed ? 1 : 0) } }
    public var text: String { lines.map(\.text).joined() }
    public init(lines: [DiffLine], isCoarse: Bool) {
        self.lines = lines
        self.isCoarse = isCoarse
    }
}

public protocol DiffComputing: Sendable {
    func compare(before: String, after: String) async throws -> DiffResult
}

public struct CodePresentation: Sendable {
    public let id: UUID
    public let text: String
    public let syntax: [SyntaxSpan]
    public let syntaxLimited: Bool
    public let diff: DiffResult?
    public let rows: [PresentedLine]?
    public let hunkStarts: [Int]
    public let sideBySide: SideBySideProjection?
    public init(
        text: String, syntax: [SyntaxSpan] = [], diff: DiffResult? = nil, rows: [PresentedLine]? = nil,
        hunkStarts: [Int] = [], sideBySide: SideBySideProjection? = nil, syntaxLimited: Bool = false,
        id: UUID = UUID()
    ) {
        self.id = id
        self.text = text
        self.syntax = syntax
        self.syntaxLimited = syntaxLimited
        self.diff = diff
        self.rows = rows
        self.hunkStarts = hunkStarts
        self.sideBySide = sideBySide
    }
}
