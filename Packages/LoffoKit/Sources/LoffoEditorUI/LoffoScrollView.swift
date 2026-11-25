import AppKit
import SwiftUI

/// Shared by SwiftUI panels and the native editor; no persistent track or reserved scrollbar gutter.
@MainActor public enum LoffoScrollAppearance {
    public static func apply(to scroll: NSScrollView) {
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        if scroll.borderType != .noBorder { scroll.borderType = .noBorder }
        if scroll.drawsBackground { scroll.drawsBackground = false }
    }
}

public struct LoffoScrollView<Content: View>: View {
    private let content: Content
    private let onScrollView: ((NSScrollView) -> Void)?
    public init(
        onScrollView: ((NSScrollView) -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.onScrollView = onScrollView
        self.content = content()
    }
    public var body: some View {
        ScrollView {
            content.background(ScrollAppearanceBinding(onScrollView: onScrollView))
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
        Task { @MainActor [weak view] in view?.applyAppearance() }
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
                Task { @MainActor [weak self] in self?.applyAppearance() }
            }
        }
        LoffoScrollAppearance.apply(to: enclosing)
    }
}
