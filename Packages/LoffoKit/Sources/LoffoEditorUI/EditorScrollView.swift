import AppKit

/// Keeps editor glyphs outside the overlay scroller while the scroller stays flush with the view edge.
@MainActor final class EditorScrollView: NSScrollView {
    override func tile() {
        super.tile()
        var frame = contentView.frame
        frame.size.width = max(0, frame.width - 20)
        contentView.frame = frame
    }
}
