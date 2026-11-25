import AppKit

/// Reserve a fixed lane for the overlay scroller without masking the scrolling content layer.
@MainActor final class EditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        var frame = contentView.frame
        frame.size.width = max(0, frame.width - 20)
        contentView.frame = frame
    }
}
