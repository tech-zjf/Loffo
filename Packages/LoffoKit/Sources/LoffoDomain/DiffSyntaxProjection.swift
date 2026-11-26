import Foundation

/// Project source UTF-16 spans into the visible unified text; gutter markers never enter the text.
public enum DiffSyntaxProjection {
    public static func spans(result: DiffResult, before: [SyntaxSpan], after: [SyntaxSpan]) -> [SyntaxSpan] {
        spans(result: result, before: before, after: after, check: {})
    }

    public static func cancellableSpans(
        result: DiffResult, before: [SyntaxSpan], after: [SyntaxSpan]
    ) throws -> [SyntaxSpan] {
        try spans(result: result, before: before, after: after) { try Task.checkCancellation() }
    }

    private static func spans<E: Error>(
        result: DiffResult, before: [SyntaxSpan], after: [SyntaxSpan], check: () throws(E) -> Void
    ) throws(E) -> [SyntaxSpan] {
        try check()
        let old = before.sorted { $0.range.location < $1.range.location }
        let new = after.sorted { $0.range.location < $1.range.location }
        var oldIndex = 0
        var newIndex = 0
        var oldOffset = 0
        var newOffset = 0
        var displayOffset = 0
        var output: [SyntaxSpan] = []
        for (lineIndex, line) in result.lines.enumerated() {
            if lineIndex.isMultiple(of: 1_024) { try check() }
            let length = line.text.utf16.count
            let sourceOffset = line.kind == .removed ? oldOffset : newOffset
            let source = line.kind == .removed ? old : new
            var index = line.kind == .removed ? oldIndex : newIndex
            while index < source.count && NSMaxRange(source[index].range) <= sourceOffset {
                if index.isMultiple(of: 1_024) { try check() }
                index += 1
            }
            if line.kind == .removed { oldIndex = index } else { newIndex = index }
            while index < source.count && source[index].range.location < sourceOffset + length {
                if index.isMultiple(of: 1_024) { try check() }
                let intersection = NSIntersectionRange(
                    source[index].range, NSRange(location: sourceOffset, length: length))
                if intersection.length > 0 {
                    output.append(
                        SyntaxSpan(
                            range: NSRange(
                                location: displayOffset + intersection.location - sourceOffset,
                                length: intersection.length), kind: source[index].kind))
                }
                index += 1
            }
            if line.kind != .added { oldOffset += length }
            if line.kind != .removed { newOffset += length }
            displayOffset += length + (line.text.hasSuffix("\n") ? 0 : 1)
        }
        return output
    }
}
