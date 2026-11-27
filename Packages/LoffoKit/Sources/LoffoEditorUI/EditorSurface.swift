import AppKit
import LoffoDesignSystem
import LoffoDomain

/// The gutter and scroll viewport are siblings. Horizontal scrolling can never expose glyphs
/// beneath line numbers, including after changing between reading and comparison widths.
@MainActor final class EditorSurface: NSView {
    let scroll: NSScrollView
    let gutter = LineGutter()
    var gutterWidth: CGFloat {
        didSet { needsLayout = true }
    }
    var diffSide: CodeDiffSide? {
        didSet {
            gutter.diffSide = diffSide
            needsDisplay = true
        }
    }
    override var isFlipped: Bool { true }

    init(scroll: NSScrollView, gutterWidth: CGFloat) {
        self.scroll = scroll
        self.gutterWidth = gutterWidth
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = .init()
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.masksToBounds = true
        gutter.scrollView = scroll
        gutter.wantsLayer = true
        gutter.layer?.masksToBounds = true
        addSubview(gutter)
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: NSRect) {
        NSColor(gutter.diffLines == nil ? LoffoPalette.surface : LoffoPalette.comparisonSurface).setFill()
        rect.fill()
        DiffDecoration.draw(
            rows: gutter.displayRows, lines: gutter.diffLines, viewport: bounds, dirty: rect,
            scrollY: scroll.contentView.bounds.minY, gutterWidth: gutterWidth)
    }

    override func layout() {
        super.layout()
        LoffoScrollAppearance.apply(to: scroll)
        let width = min(gutterWidth, bounds.width)
        gutter.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        scroll.frame = NSRect(
            x: width, y: 0, width: max(0, bounds.width - width), height: bounds.height)
        updateDocumentHeight()
        needsDisplay = true
    }

    func updateDocumentHeight() {
        guard let text = scroll.documentView as? NSTextView else { return }
        let lineHeight = CGFloat(max(1, gutter.lineCount)) * LoffoMetrics.line
        let height = max(scroll.contentView.bounds.height, lineHeight + 2 * text.textContainerInset.height)
        guard abs(text.frame.height - height) > 0.5 else { return }
        text.setFrameSize(NSSize(width: text.frame.width, height: height))
    }
}

@MainActor final class LineGutter: NSView {
    weak var scrollView: NSScrollView?
    override var isFlipped: Bool { true }
    var diffLines: [DiffLine]?
    var displayRows: [PresentedLine]?
    var diffSide: CodeDiffSide?
    var lineCount = 0
    override func draw(_ rect: NSRect) {
        guard let scroll = scrollView else { return }
        let top = scroll.contentView.bounds.minY
        let first = max(0, Int((top - 4) / LoffoMetrics.line))
        let last = first + Int(bounds.height / LoffoMetrics.line) + 2
        let attributes: [NSAttributedString.Key: Any] = [
            .font: EditorTypography.gutter,
            .foregroundColor: NSColor(LoffoPalette.secondary),
        ]
        for line in first...last {
            if line >= (displayRows?.count ?? diffLines?.count ?? lineCount) { break }
            let item: DiffLine?
            if let rows = displayRows {
                // A virtual heading deliberately has no source line; never fall back by raw index.
                item = rows[line].line
            } else {
                item = diffLines.flatMap { line < $0.count ? $0[line] : nil }
            }
            if displayRows?[line].heading != nil {
                guard diffSide == nil else { continue }
                if line == 0 {
                    ("Old" as NSString).draw(at: NSPoint(x: 20, y: 8 - top), withAttributes: attributes)
                    ("New" as NSString).draw(at: NSPoint(x: 58, y: 8 - top), withAttributes: attributes)
                }
                continue
            }
            if displayRows?[line].isPlaceholder == true { continue }
            if let item {
                let color =
                    item.kind == .added
                    ? LoffoPalette.added
                    : item.kind == .removed ? LoffoPalette.removed : LoffoPalette.secondary
                var style = attributes
                style[.foregroundColor] = NSColor(color)
                let y = 9 + CGFloat(line) * LoffoMetrics.line - top
                let labels: [(String, Double)]
                switch diffSide {
                case .before:
                    labels = [
                        (item.oldNumber.map(String.init) ?? "", 42.0),
                        (item.kind == .removed ? "−" : "", 64.0),
                    ]
                case .after:
                    labels = [
                        (item.newNumber.map(String.init) ?? "", 42.0),
                        (item.kind == .added ? "+" : "", 64.0),
                    ]
                case nil:
                    labels = [
                        (item.oldNumber.map(String.init) ?? "", 38.0),
                        (item.newNumber.map(String.init) ?? "", 76.0),
                        (item.kind == .added ? "+" : item.kind == .removed ? "−" : "", 112.0),
                    ]
                }
                for (value, right) in labels {
                    let label = value as NSString
                    label.draw(
                        at: NSPoint(x: right - label.size(withAttributes: style).width, y: y),
                        withAttributes: style)
                }
                continue
            }
            let label = String(line + 1) as NSString
            label.draw(
                at: NSPoint(
                    x: bounds.width - label.size(withAttributes: attributes).width - 12,
                    y: 9 + CGFloat(line) * LoffoMetrics.line - top), withAttributes: attributes)
        }
    }
}
