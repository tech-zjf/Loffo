import Foundation

/// One aligned row in a side-by-side diff. A missing side is a deliberate virtual blank row.
public struct AlignedDiffRow: Sendable, Equatable {
    public let before: DiffLine?
    public let after: DiffLine?

    public init(before: DiffLine?, after: DiffLine?) {
        self.before = before
        self.after = after
    }
}

public struct SideBySideColumn: Sendable {
    public let rows: [PresentedLine]
    public let text: String
    public let syntax: [SyntaxSpan]

    fileprivate init(rows: [PresentedLine], syntax: [SyntaxSpan]) {
        self.rows = rows
        text = rows.map(\.text).joined()
        self.syntax = syntax
    }
}

/// Aligns immutable comparison rows without parsing rendered unified text.
public struct SideBySideProjection: Sendable {
    public let rows: [AlignedDiffRow]
    public let before: SideBySideColumn
    public let after: SideBySideColumn
    public let hunkStarts: [Int]

    public init(result: DiffResult) {
        self.init(result: result, beforeSyntax: [], afterSyntax: [], check: {})
    }

    public init(result: DiffResult, beforeSyntax: [SyntaxSpan], afterSyntax: [SyntaxSpan]) {
        self.init(result: result, beforeSyntax: beforeSyntax, afterSyntax: afterSyntax, check: {})
    }

    public static func cancellable(result: DiffResult) throws -> Self {
        try Self(result: result, beforeSyntax: [], afterSyntax: []) { try Task.checkCancellation() }
    }

    public static func cancellable(
        result: DiffResult, beforeSyntax: [SyntaxSpan], afterSyntax: [SyntaxSpan]
    ) throws -> Self {
        try Self(result: result, beforeSyntax: beforeSyntax, afterSyntax: afterSyntax) {
            try Task.checkCancellation()
        }
    }

    private init<E: Error>(
        result: DiffResult, beforeSyntax: [SyntaxSpan], afterSyntax: [SyntaxSpan],
        check: () throws(E) -> Void
    ) throws(E) {
        let lines = result.lines
        var rows: [AlignedDiffRow] = []
        var beforeRows: [PresentedLine] = []
        var afterRows: [PresentedLine] = []
        var hunkStarts: [Int] = []
        var lastHunkEnd = -1
        var index = 0
        while index < lines.count {
            if index.isMultiple(of: 1_024) { try check() }
            let line = lines[index]
            guard line.kind != .context else {
                rows.append(AlignedDiffRow(before: line, after: line))
                beforeRows.append(PresentedLine(line: line))
                afterRows.append(PresentedLine(line: line))
                index += 1
                continue
            }

            var removed: [DiffLine] = []
            var added: [DiffLine] = []
            let lower = max(0, index - 3)
            if hunkStarts.isEmpty || lower > lastHunkEnd + 1 { hunkStarts.append(rows.count) }
            while index < lines.count, lines[index].kind != .context {
                if index.isMultiple(of: 1_024) { try check() }
                let changed = lines[index]
                switch changed.kind {
                case .removed: removed.append(changed)
                case .added: added.append(changed)
                case .context: break
                }
                index += 1
            }
            lastHunkEnd = max(lastHunkEnd, index - 1 + 3)
            for offset in 0..<max(removed.count, added.count) {
                if offset.isMultiple(of: 1_024) { try check() }
                rows.append(
                    AlignedDiffRow(
                        before: removed.indices.contains(offset) ? removed[offset] : nil,
                        after: added.indices.contains(offset) ? added[offset] : nil))
                beforeRows.append(
                    removed.indices.contains(offset)
                        ? PresentedLine(line: removed[offset])
                        : PresentedLine(line: nil, isPlaceholder: true))
                afterRows.append(
                    added.indices.contains(offset)
                        ? PresentedLine(line: added[offset])
                        : PresentedLine(line: nil, isPlaceholder: true))
            }
        }
        try check()
        let beforeColumn = SideBySideColumn(
            rows: beforeRows, syntax: try Self.project(beforeSyntax, through: beforeRows, check: check))
        let afterColumn = SideBySideColumn(
            rows: afterRows, syntax: try Self.project(afterSyntax, through: afterRows, check: check))
        self.rows = rows
        self.before = beforeColumn
        self.after = afterColumn
        self.hunkStarts = hunkStarts
    }

    private static func project<E: Error>(
        _ source: [SyntaxSpan], through rows: [PresentedLine], check: () throws(E) -> Void
    ) throws(E) -> [SyntaxSpan] {
        let spans = source.sorted { $0.range.location < $1.range.location }
        var cursor = 0
        var sourceOffset = 0
        var displayOffset = 0
        var output: [SyntaxSpan] = []
        for (rowIndex, row) in rows.enumerated() {
            if rowIndex.isMultiple(of: 1_024) { try check() }
            guard let line = row.line else {
                displayOffset += row.text.utf16.count
                continue
            }
            let length = line.text.utf16.count
            while cursor < spans.count && NSMaxRange(spans[cursor].range) <= sourceOffset {
                cursor += 1
            }
            var index = cursor
            while index < spans.count && spans[index].range.location < sourceOffset + length {
                if index.isMultiple(of: 1_024) { try check() }
                let intersection = NSIntersectionRange(
                    spans[index].range, NSRange(location: sourceOffset, length: length))
                if intersection.length > 0 {
                    output.append(
                        SyntaxSpan(
                            range: NSRange(
                                location: displayOffset + intersection.location - sourceOffset,
                                length: intersection.length), kind: spans[index].kind))
                }
                index += 1
            }
            cursor = index
            sourceOffset += length
            displayOffset += row.text.utf16.count
        }
        return output
    }
}
