import Foundation
import LoffoDomain
import Testing

@testable import LoffoEditorUI

@Test func syntaxIndexFindsOverlappingSpansInOriginalPaintOrder() {
    let spans = [
        SyntaxSpan(range: NSRange(location: 20, length: 6), kind: .string),
        SyntaxSpan(range: NSRange(location: 0, length: 40), kind: .comment),
        SyntaxSpan(range: NSRange(location: 22, length: 2), kind: .keyword),
        SyntaxSpan(range: NSRange(location: 100, length: 5), kind: .number),
        SyntaxSpan(range: NSRange(location: 23, length: 300), kind: .type),
    ]
    let found = SyntaxSpanIndex(spans).intersecting(NSRange(location: 23, length: 1), storageLength: 200)
    #expect(found.map(\.kind) == [.string, .comment, .keyword])
    #expect(SyntaxSpanIndex(spans).intersecting(NSRange(location: 40, length: 1), storageLength: 200).isEmpty)
}

@Test func syntaxIndexMatchesLinearReferenceAcrossLargeFile() {
    let spans = (0..<30_000).map {
        SyntaxSpan(range: NSRange(location: $0 * 8, length: 5), kind: .keyword)
    }
    let index = SyntaxSpanIndex(spans)
    for location in stride(from: 0, through: 240_000, by: 3_997) {
        let visible = NSRange(location: location, length: 151)
        let expected = spans.filter { NSIntersectionRange($0.range, visible).length > 0 }
        #expect(index.intersecting(visible, storageLength: 240_000).map(\.range) == expected.map(\.range))
    }
}
