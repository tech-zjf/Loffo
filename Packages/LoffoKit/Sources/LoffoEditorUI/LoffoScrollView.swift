import AppKit
import SwiftUI

@MainActor final class LoffoScroller: NSScroller {
    static let thumbThickness: CGFloat = 9

    override class var isCompatibleWithOverlayScrollers: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        dirtyRect.fill(using: .copy)
        drawKnob()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let thickness = Self.thumbThickness
        let rect: NSRect
        if bounds.height > bounds.width {
            rect = NSRect(
                x: bounds.maxX - thickness,
                y: knob.minY + 1,
                width: thickness,
                height: max(0, knob.height - 2)
            )
        } else {
            rect = NSRect(
                x: knob.minX + 1,
                y: bounds.minY,
                width: max(0, knob.width - 2),
                height: thickness
            )
        }
        NSColor.secondaryLabelColor.withAlphaComponent(isHighlighted ? 0.72 : 0.48).setFill()
        NSBezierPath(roundedRect: rect, xRadius: thickness / 2, yRadius: thickness / 2).fill()
    }
}

public enum LoffoScrollMetrics {
    public static let defaultContentGutter: CGFloat = 10
}

/// Shared overlay-scrollbar styling. SwiftUI panels reserve a content gutter below; the editor
/// separately keeps TextKit content clear of its native overlay scroller.
@MainActor public enum LoffoScrollAppearance {
    public static func apply(to scroll: NSScrollView) {
        if scroll.borderType != .noBorder { scroll.borderType = .noBorder }
        if scroll.drawsBackground { scroll.drawsBackground = false }
        scroll.scrollerInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        installScroller(on: scroll, vertical: true)
        installScroller(on: scroll, vertical: false)
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
    }

    private static func installScroller(on scroll: NSScrollView, vertical: Bool) {
        let current = vertical ? scroll.verticalScroller : scroll.horizontalScroller
        guard current != nil else { return }
        if current is LoffoScroller { return }
        let scroller = LoffoScroller()
        scroller.controlSize = .regular
        if vertical {
            scroll.verticalScroller = scroller
        } else {
            scroll.horizontalScroller = scroller
        }
    }
}

public struct LoffoScrollView<Content: View>: View {
    private let content: Content
    private let onScrollView: ((NSScrollView) -> Void)?
    private let scrollbarGutter: CGFloat
    public init(
        onScrollView: ((NSScrollView) -> Void)? = nil,
        scrollbarGutter: CGFloat = LoffoScrollMetrics.defaultContentGutter,
        @ViewBuilder content: () -> Content
    ) {
        self.onScrollView = onScrollView
        self.scrollbarGutter = max(0, scrollbarGutter)
        self.content = content()
    }
    public var body: some View {
        ScrollView {
            content.padding(.trailing, scrollbarGutter)
                .background(ScrollAppearanceBinding(onScrollView: onScrollView))
        }
    }
}

private struct ScrollAppearanceBinding: NSViewRepresentable {
    let onScrollView: ((NSScrollView) -> Void)?
    func makeNSView(context: Context) -> ScrollAppearanceView {
        ScrollAppearanceView(onScrollView: onScrollView)
    }
    func updateNSView(_ view: ScrollAppearanceView, context: Context) {
        view.onScrollView = onScrollView
        view.applyAppearance()
    }
}

@MainActor private final class ScrollAppearanceView: NSView {
    var onScrollView: ((NSScrollView) -> Void)?
    private weak var scroll: NSScrollView?
    private var styleObservation: NSKeyValueObservation?
    init(onScrollView: ((NSScrollView) -> Void)?) {
        self.onScrollView = onScrollView
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyAppearance()
    }
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        applyAppearance()
    }
    override func layout() {
        super.layout()
        applyAppearance()
    }
    func applyAppearance() {
        guard let enclosing = enclosingScrollView else { return }
        if scroll !== enclosing {
            scroll = enclosing
            Task { @MainActor [weak self, weak enclosing] in
                guard let self, let enclosing, self.scroll === enclosing else { return }
                self.onScrollView?(enclosing)
            }
            // SwiftUI may reapply the system scroller style when its content changes.
            // Observe this specific scroll view; never change the user's global preference.
            styleObservation = enclosing.observe(\.scrollerStyle, options: [.new]) { [weak self] _, change in
                guard change.newValue != .overlay else { return }
                MainActor.assumeIsolated { self?.applyAppearance() }
            }
        }
        LoffoScrollAppearance.apply(to: enclosing)
    }
}
