import Foundation

public struct PresentedLine: Sendable {
    public let line: DiffLine?
    public let heading: String?
    public var text: String {
        guard let line else { return "\n" }
        return line.text.hasSuffix("\n") ? line.text : line.text + "\n"
    }
    public init(line: DiffLine?, heading: String? = nil) {
        self.line = line
        self.heading = heading
    }
}

/// A layout projection, independent of the complete comparison and its statistics.
public struct UnifiedProjection: Sendable {
    public let rows: [PresentedLine]
    public let text: String
    public let syntax: [SyntaxSpan]
    public let hunkStarts: [Int]

    public init(result: DiffResult, syntax: [SyntaxSpan] = [], context: Int = 3, expanded: Bool = false) {
        let lines = result.lines
        let hasChanges = result.added + result.removed > 0
        var included = Set<Int>()
        var rawHunkStarts: [Int] = []
        var lastHunkEnd = -1
        for index in lines.indices where lines[index].kind != .context {
            let lower = max(0, index - context)
            let upper = min(lines.count - 1, index + context)
            if lower > lastHunkEnd + 1 { rawHunkStarts.append(lower) }
            lastHunkEnd = max(lastHunkEnd, upper)
        }
        let rawHunkStartSet = Set(rawHunkStarts)
        if expanded || !hasChanges {
            included.formUnion(lines.indices)
        } else {
            for index in lines.indices where lines[index].kind != .context {
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
        var cursor = 0
        for index in lines.indices {
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
                displayOffset += 1
            }
            if expanded && rawHunkStartSet.contains(index) { hunkStarts.append(rows.count) }
            rows.append(PresentedLine(line: line))
            while cursor < ordered.count && NSMaxRange(ordered[cursor].range) <= rawOffset { cursor += 1 }
            var spanIndex = cursor
            while spanIndex < ordered.count && ordered[spanIndex].range.location < rawOffset + length {
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
        text = rows.map(\.text).joined()
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
