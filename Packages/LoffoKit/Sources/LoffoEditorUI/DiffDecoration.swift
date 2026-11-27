import AppKit
import LoffoDesignSystem
import LoffoDomain

/// One viewport-owned backdrop spans the sign column and text, independent of text scrolling.
/// Dirty rectangles limit work and clipping only; they never define decoration geometry.
@MainActor enum DiffDecoration {
    static func draw(
        rows: [PresentedLine]?, lines: [DiffLine]?, viewport: NSRect, dirty: NSRect,
        scrollY: CGFloat, gutterWidth: CGFloat
    ) {
        let count = rows?.count ?? lines?.count ?? 0
        let first = max(0, Int(floor((dirty.minY + scrollY - 4) / LoffoMetrics.line)))
        let last = min(count, Int(ceil((dirty.maxY + scrollY - 4) / LoffoMetrics.line)))
        guard first < last else { return }
        func rowKind(at index: Int) -> DiffKind? {
            guard (0..<count).contains(index) else { return nil }
            if let rows { return rows[index].line?.kind }
            return lines?[index].kind
        }
        for index in first..<last {
            let y = 4 + CGFloat(index) * LoffoMetrics.line - scrollY
            if let heading = rows?[index].heading {
                // The first header leaves room for Old/New labels; later headers span the gutter.
                let left: CGFloat = index == 0 ? 108 : 16
                let box = NSRect(
                    x: left, y: y, width: max(0, viewport.width - left),
                    height: LoffoMetrics.line)
                guard box.width > 0 else { continue }
                NSColor(LoffoPalette.border.opacity(0.2)).setFill()
                NSBezierPath(roundedRect: box, xRadius: 7, yRadius: 7).fill()
                NSGraphicsContext.saveGraphicsState()
                box.clip()
                (heading as NSString).draw(
                    at: NSPoint(x: gutterWidth + 14, y: y + 3),
                    withAttributes: [
                        .font: EditorTypography.gutter,
                        .foregroundColor: NSColor(LoffoPalette.secondary),
                    ])
                NSGraphicsContext.restoreGraphicsState()
            } else if let kind = rowKind(at: index), kind != .context {
                let box = NSRect(
                    x: 95, y: y, width: max(0, viewport.width - 95),
                    height: LoffoMetrics.line)
                guard box.width > 0 else { continue }
                NSColor(kind == .added ? LoffoPalette.addedBackground : LoffoPalette.removedBackground)
                    .setFill()
                // Only the first/last row of a same-kind block gets rounded outer corners.
                let top: CGFloat = rowKind(at: index - 1) == kind ? 6 : 0
                let bottom: CGFloat = rowKind(at: index + 1) == kind ? 6 : 0
                let extended = NSRect(
                    x: box.minX, y: box.minY - top, width: box.width,
                    height: box.height + top + bottom)
                NSGraphicsContext.saveGraphicsState()
                box.clip()
                NSBezierPath(roundedRect: extended, xRadius: 6, yRadius: 6).fill()
                NSGraphicsContext.restoreGraphicsState()
            }
        }
    }

}
