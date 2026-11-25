import Foundation
import LoffoDesignSystem

struct TextPatch: Sendable {
    let range: NSRange
    let replacement: String
    static func between(_ old: String, _ new: String) -> TextPatch {
        if old.utf8.elementsEqual(new.utf8) {
            return TextPatch(range: NSRange(location: 0, length: 0), replacement: "")
        }
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        var prefix = 0
        var suffix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0, prefix < a.count, (0xDC00...0xDFFF).contains(a[prefix]) { prefix -= 1 }
        while suffix < min(a.count, b.count) - prefix, a[a.count - suffix - 1] == b[b.count - suffix - 1] {
            suffix += 1
        }
        if suffix > 0, suffix < a.count, (0xDC00...0xDFFF).contains(a[a.count - suffix]) { suffix -= 1 }
        return TextPatch(
            range: NSRange(location: prefix, length: a.count - prefix - suffix),
            replacement: (new as NSString).substring(
                with: NSRange(location: prefix, length: b.count - prefix - suffix)))
    }
    func map(_ offset: Int) -> Int {
        if offset <= range.location { return offset }
        if offset >= NSMaxRange(range) { return offset + replacement.utf16.count - range.length }
        return range.location + min(offset - range.location, replacement.utf16.count)
    }
}

/// Keep the logical top line stable when external tools insert/delete lines above it.
struct ScrollAnchor: Sendable {
    let utf16Offset: Int
    let intraLine: Double
    static func capture(text: String, y: Double) -> ScrollAnchor {
        let line = max(0, Int((y - 4) / Double(LoffoMetrics.line)))
        var offset = 0
        var index = 0
        for character in text {
            if index >= line { break }
            offset += character.utf16.count
            if character.isNewline { index += 1 }
        }
        return ScrollAnchor(utf16Offset: offset, intraLine: y - Double(line) * Double(LoffoMetrics.line))
    }
    func restoredY(in text: String, patch: TextPatch) -> Double {
        let target = patch.map(utf16Offset)
        var offset = 0
        var line = 0
        for character in text {
            if offset >= target { break }
            offset += character.utf16.count
            if character.isNewline { line += 1 }
        }
        return max(0, Double(line) * Double(LoffoMetrics.line) + intraLine)
    }
}
