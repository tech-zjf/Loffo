import Foundation
import Testing

@testable import LoffoEditorUI

@Test func textPatchPreservesUnicodeAndSelectionOffsets() {
    let inputs = ["", "😃", "😄", "a\n👨‍👩‍👦 é中文\n", "a\n👨‍👩‍👧 é中文\n", "hello"]
    for before in inputs {
        for after in inputs {
            let patch = TextPatch.between(before, after)
            #expect(
                (before as NSString).replacingCharacters(in: patch.range, with: patch.replacement) == after)
            #expect(patch.map(before.utf16.count) <= after.utf16.count)
        }
    }
}

@Test func scrollAnchorTracksInsertionAboveViewport() {
    let before = (0..<100).map { "line \($0)\n" }.joined()
    let after = "new A\nnew B\n" + before
    let anchor = ScrollAnchor.capture(text: before, y: 404)
    let patch = TextPatch.between(before, after)
    #expect(anchor.restoredY(in: after, patch: patch) == 444)
}

@Test func canonicalUnicodePatchChangesCodeUnits() {
    let before = "let a = '\u{e9}'"
    let after = "let a = 'e\u{301}'"
    let patch = TextPatch.between(before, after)
    let actual = (before as NSString).replacingCharacters(in: patch.range, with: patch.replacement)
    #expect(Array(actual.utf8) == Array(after.utf8))
}
