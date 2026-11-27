import Foundation

public struct PresentedLine: Sendable, Equatable {
    public let line: DiffLine?
    public let heading: String?
    public let isPlaceholder: Bool
    public var text: String {
        guard let line else { return "\n" }
        return line.text.hasSuffix("\n") ? line.text : line.text + "\n"
    }
    public init(line: DiffLine?, heading: String? = nil, isPlaceholder: Bool = false) {
        self.line = line
        self.heading = heading
        self.isPlaceholder = isPlaceholder
    }
}

/// A layout projection, independent of the complete comparison and its statistics.
public struct UnifiedProjection: Sendable {
    public let rows: [PresentedLine]
    public let text: String
    public let syntax: [SyntaxSpan]
    public let hunkStarts: [Int]

    public init(result: DiffResult, syntax: [SyntaxSpan] = [], context: Int = 3, expanded: Bool = false) {
        self.init(result: result, syntax: syntax, context: context, expanded: expanded, check: {})
    }

    public static func cancellable(
        result: DiffResult, syntax: [SyntaxSpan] = [], context: Int = 3, expanded: Bool = false
    ) throws -> Self {
        try Self(result: result, syntax: syntax, context: context, expanded: expanded) {
            try Task.checkCancellation()
        }
    }

    private init<E: Error>(
        result: DiffResult, syntax: [SyntaxSpan], context: Int, expanded: Bool,
        check: () throws(E) -> Void
    ) throws(E) {
        try check()
        let lines = result.lines
        var hasChanges = false
        var included = Set<Int>()
        var rawHunkStarts: [Int] = []
        var lastHunkEnd = -1
        for index in lines.indices {
            if index.isMultiple(of: 1_024) { try check() }
            guard lines[index].kind != .context else { continue }
            hasChanges = true
            let lower = max(0, index - context)
            let upper = min(lines.count - 1, index + context)
            if lower > lastHunkEnd + 1 { rawHunkStarts.append(lower) }
            lastHunkEnd = max(lastHunkEnd, upper)
        }
        let rawHunkStartSet = Set(rawHunkStarts)
        if expanded || !hasChanges {
            included.formUnion(lines.indices)
        } else {
            for index in lines.indices {
                if index.isMultiple(of: 1_024) { try check() }
                guard lines[index].kind != .context else { continue }
                included.formUnion(max(0, index - context)...min(lines.count - 1, index + context))
            }
        }
        var rows: [PresentedLine] = []
        var spans: [SyntaxSpan] = []
        var rawOffset = 0
        var displayOffset = 0
        var previous = -2
        var hunkStarts: [Int] = []
        let ordered = syntax.sorted { $0.range.location < $1.range.location }
        try check()
        var cursor = 0
        var text = ""
        for index in lines.indices {
            if index.isMultiple(of: 1_024) { try check() }
            let line = lines[index]
            let display = line.text.hasSuffix("\n") ? line.text : line.text + "\n"
            let length = display.utf16.count
            defer { rawOffset += length }
            guard included.contains(index) else { continue }
            if index != previous + 1 && !expanded && hasChanges {
                hunkStarts.append(rows.count)
                rows.append(
                    PresentedLine(line: nil, heading: "@@ −\(line.oldNumber ?? 0) +\(line.newNumber ?? 0) @@")
                )
                text += "\n"
                displayOffset += 1
            }
            if expanded && rawHunkStartSet.contains(index) { hunkStarts.append(rows.count) }
            rows.append(PresentedLine(line: line))
            text += display
            while cursor < ordered.count && NSMaxRange(ordered[cursor].range) <= rawOffset {
                if cursor.isMultiple(of: 1_024) { try check() }
                cursor += 1
            }
            var spanIndex = cursor
            while spanIndex < ordered.count && ordered[spanIndex].range.location < rawOffset + length {
                if spanIndex.isMultiple(of: 1_024) { try check() }
                let range = NSIntersectionRange(
                    ordered[spanIndex].range, NSRange(location: rawOffset, length: length))
                if range.length > 0 {
                    spans.append(
                        SyntaxSpan(
                            range: NSRange(
                                location: displayOffset + range.location - rawOffset,
                                length: range.length), kind: ordered[spanIndex].kind))
                }
                spanIndex += 1
            }
            displayOffset += length
            previous = index
        }
        self.rows = rows
        self.text = text
        self.syntax = spans
        self.hunkStarts = hunkStarts
    }

    public static func copy(range: NSRange, rows: [PresentedLine]) -> String {
        var offset = 0
        var output = ""
        for row in rows {
            let text = row.text as NSString
            let intersection = NSIntersectionRange(range, NSRange(location: offset, length: text.length))
            if row.line != nil, intersection.length > 0 {
                output += text.substring(
                    with: NSRange(location: intersection.location - offset, length: intersection.length))
            }
            offset += text.length
        }
        return output
    }
}
