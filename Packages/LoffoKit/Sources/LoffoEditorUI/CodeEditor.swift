import AppKit
import LoffoDesignSystem
import LoffoDomain
import OSLog
import SwiftUI

public struct CodeEditor: NSViewRepresentable {
    public let presentation: CodePresentation
    public let navigation: CodeNavigation?
    public let accessibilityName: String
    public let syntaxTheme: EditorSyntaxTheme
    public init(
        presentation: CodePresentation, navigation: CodeNavigation? = nil, accessibilityName: String = "Code",
        syntaxTheme: EditorSyntaxTheme = .standard
    ) {
        self.presentation = presentation
        self.navigation = navigation
        self.accessibilityName = accessibilityName
        self.syntaxTheme = syntaxTheme
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }
    public func makeNSView(context: Context) -> NSView {
        let scroll = EditorScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        LoffoScrollAppearance.apply(to: scroll)
        scroll.wantsLayer = true
        scroll.layer?.masksToBounds = true
        let text = TrackingTextView(usingTextLayoutManager: true)
        text.setAccessibilityLabel(accessibilityName)
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticLinkDetectionEnabled = false
        text.drawsBackground = false
        text.font = EditorTypography.code
        text.textContainerInset = NSSize(width: 20, height: 4)
        text.isHorizontallyResizable = true
        // Line height is fixed; size the scroll document explicitly instead of asking TextKit
        // to lay out every paragraph to discover its height.
        text.isVerticallyResizable = false
        text.minSize = NSSize(width: 0, height: 0)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.containerSize = text.maxSize
        text.textContainer?.widthTracksTextView = false
        scroll.documentView = text
        let surface = EditorSurface(scroll: scroll, gutterWidth: presentation.diff == nil ? 48 : 118)
        context.coordinator.connect(text, surface: surface)
        return surface
    }
    public static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.disconnect()
    }
    public func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.name(accessibilityName)
        context.coordinator.submit(presentation, theme: syntaxTheme)
        context.coordinator.navigate(navigation)
    }

    @MainActor public final class Coordinator {
        private weak var textView: TrackingTextView?
        private weak var scrollView: NSScrollView?
        private weak var ruler: LineGutter?
        private weak var surface: EditorSurface?
        private var current: CodePresentation?
        private var pending: CodePresentation?
        private var syntaxIndex = SyntaxSpanIndex([])
        private var lineStarts: [Int] = [0]
        private var relocatedLine: Int?
        private var relocating = false
        private var latestRequestedID: UUID?
        private var syntaxTheme = EditorSyntaxTheme.standard
        private var applying = false
        private var decorating = false
        private var decoratedRange: NSRange?
        private var lastNavigation: UUID?
        private let signposter = OSSignposter(subsystem: "app.loffo", category: "Editor")
        private var observer: NSObjectProtocol?
        private var resizeObserver: NSObjectProtocol?

        func connect(_ text: TrackingTextView, surface: EditorSurface) {
            let scroll = surface.scroll
            let ruler = surface.gutter
            self.surface = surface
            textView = text
            scrollView = scroll
            self.ruler = ruler
            text.selectionEnded = { [weak self] in self?.drain() }
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.relocateViewport()
                    self?.decorate()
                    self?.ruler?.needsDisplay = true
                    self?.surface?.needsDisplay = true
                }
            }
            resizeObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.decorate() }
            }
        }
        fileprivate func name(_ name: String) { textView?.setAccessibilityLabel(name) }

        fileprivate func navigate(_ request: CodeNavigation?) {
            guard let request, request.id != lastNavigation, let textView, let scrollView else { return }
            lastNavigation = request.id
            var origin = scrollView.contentView.bounds.origin
            origin.y = CGFloat(request.line) * LoffoMetrics.line
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            textView.needsDisplay = true
            ruler?.needsDisplay = true
        }
        func submit(_ value: CodePresentation, theme: EditorSyntaxTheme) {
            if syntaxTheme != theme {
                syntaxTheme = theme
                decoratedRange = nil
                if current?.id == value.id { decorate() }
            }
            latestRequestedID = value.id
            if current?.id == value.id {
                pending = nil
                return
            }
            guard pending?.id != value.id else { return }
            pending = value
            drain()
        }
        private func drain() {
            guard !applying, textView?.isTrackingSelection != true, let next = pending else { return }
            pending = nil
            applying = true
            let old = current?.text ?? ""
            let scrollY = Double(scrollView?.contentView.bounds.minY ?? 0)
            Task { [weak self] in
                let (patch, restoredY, starts, index) = await Task.detached(
                    priority: .userInitiated
                ) {
                    let patch = TextPatch.between(old, next.text)
                    let anchor = ScrollAnchor.capture(text: old, y: scrollY)
                    var starts = [0]
                    var offset = 0
                    for character in next.text {
                        offset += character.utf16.count
                        if character.isNewline { starts.append(offset) }
                    }
                    return (
                        patch, anchor.restoredY(in: next.text, patch: patch), starts,
                        SyntaxSpanIndex(next.syntax)
                    )
                }.value
                guard let self else { return }
                guard self.latestRequestedID == next.id, self.textView != nil else {
                    self.applying = false
                    self.drain()
                    return
                }
                if self.textView?.isTrackingSelection == true {
                    if self.pending == nil { self.pending = next }
                    self.applying = false
                    return
                }
                self.apply(
                    next, patch: patch, restoredY: restoredY, capturedY: scrollY, starts: starts,
                    index: index)
                self.applying = false
                self.drain()
            }
        }
        private func apply(
            _ next: CodePresentation, patch: TextPatch, restoredY: Double, capturedY: Double, starts: [Int],
            index: SyntaxSpanIndex
        ) {
            let interval = signposter.beginInterval("presentationApplied")
            defer { signposter.endInterval("presentationApplied", interval) }
            guard let text = textView, let storage = text.textStorage else { return }
            let selection = text.selectedRange()
            var scroll = scrollView?.contentView.bounds.origin ?? .zero
            // If the user scrolled while a patch was computed, do not undo that input.
            if abs(Double(scroll.y) - capturedY) < 0.5 { scroll.y = CGFloat(restoredY) }
            // Establish the document extent before changing the text storage. Otherwise TextKit
            // may lay out every paragraph while the document still has its old viewport-sized frame.
            ruler?.lineCount = starts.count
            surface?.updateDocumentHeight()
            storage.beginEditing()
            let changesText = patch.range.length > 0 || !patch.replacement.isEmpty
            if changesText { storage.replaceCharacters(in: patch.range, with: patch.replacement) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = LoffoMetrics.line
            paragraph.maximumLineHeight = LoffoMetrics.line
            if changesText {
                storage.setAttributes(
                    [
                        .font: EditorTypography.code,
                        .foregroundColor: NSColor(syntaxTheme.foreground),
                        .paragraphStyle: paragraph,
                    ], range: NSRange(location: patch.range.location, length: patch.replacement.utf16.count))
            }
            text.displayRows = next.rows
            let modeChanged = (current?.diff == nil) != (next.diff == nil)
            surface?.gutterWidth = next.diff == nil ? 48 : 118
            if modeChanged { scroll.x = 0 }
            storage.endEditing()
            current = next
            syntaxIndex = index
            lineStarts = starts
            decoratedRange = nil
            relocatedLine = nil
            text.needsDisplay = true
            ruler?.diffLines = next.diff?.lines
            ruler?.displayRows = next.rows
            let newStart = patch.map(selection.location)
            let newEnd = patch.map(selection.location + selection.length)
            text.setSelectedRange(
                NSRange(
                    location: min(newStart, storage.length),
                    length: max(0, min(newEnd, storage.length) - min(newStart, storage.length))))
            if let clip = scrollView?.contentView {
                scroll = clip.constrainBoundsRect(NSRect(origin: scroll, size: clip.bounds.size)).origin
                scroll.y = max(0, min(scroll.y, text.frame.height - clip.bounds.height))
                clip.scroll(to: scroll)
            }
            if let scrollView { scrollView.reflectScrolledClipView(scrollView.contentView) }
            ruler?.needsDisplay = true
            surface?.needsDisplay = true
            relocateViewport()
            text.textLayoutManager?.textViewportLayoutController.layoutViewport()
            decorate()
        }
        private func relocateViewport() {
            guard !relocating, let text = textView, let scroll = scrollView,
                let manager = text.textLayoutManager, let content = manager.textContentManager
            else { return }
            let line = min(
                lineStarts.count - 1,
                max(
                    0,
                    Int((scroll.contentView.bounds.minY - text.textContainerInset.height) / LoffoMetrics.line)
                ))
            guard relocatedLine != line else { return }
            guard let location = content.location(content.documentRange.location, offsetBy: lineStarts[line])
            else { return }
            relocatedLine = line
            relocating = true
            defer { relocating = false }
            _ = manager.textViewportLayoutController.relocateViewport(to: location)
        }
        private func decorate() {
            guard !decorating else { return }
            decorating = true
            defer { decorating = false }
            guard let text = textView, current != nil, let scroll = scrollView,
                let storage = text.textStorage
            else { return }
            // The clip can resize before TextKit updates viewportRange. Fixed-height line starts
            // describe the new visible area immediately, including partially visible edge lines.
            let bounds = scroll.contentView.bounds
            let top = max(0, bounds.minY - text.textContainerInset.height)
            let bottom = max(0, bounds.maxY - text.textContainerInset.height)
            let first = min(lineStarts.count - 1, Int(top / LoffoMetrics.line))
            let next = min(lineStarts.count, Int(bottom / LoffoMetrics.line) + 2)
            let start = lineStarts[first]
            let end = next < lineStarts.count ? lineStarts[next] : storage.length
            let visible = NSRange(location: max(0, start), length: max(0, end - start))
            guard decoratedRange != visible else { return }
            var dirty = [visible]
            if let previous = decoratedRange {
                let shared = NSIntersectionRange(previous, visible)
                if shared.length > 0 {
                    dirty = []
                    if visible.location < shared.location {
                        dirty.append(
                            NSRange(location: visible.location, length: shared.location - visible.location))
                    }
                    if NSMaxRange(shared) < NSMaxRange(visible) {
                        dirty.append(
                            NSRange(
                                location: NSMaxRange(shared),
                                length: NSMaxRange(visible) - NSMaxRange(shared)))
                    }
                }
            }
            storage.beginEditing()
            for range in dirty where range.length > 0 {
                storage.addAttribute(.font, value: EditorTypography.code, range: range)
                storage.addAttribute(.foregroundColor, value: NSColor(syntaxTheme.foreground), range: range)
                for span in syntaxIndex.intersecting(range, storageLength: storage.length) {
                    let intersection = NSIntersectionRange(span.range, range)
                    let color = NSColor(syntaxTheme.color(for: span.kind))
                    storage.addAttribute(.foregroundColor, value: color, range: intersection)
                    if span.kind == .comment {
                        storage.addAttribute(.font, value: EditorTypography.comment, range: intersection)
                    }
                }
            }
            storage.endEditing()
            decoratedRange = visible
        }
        nonisolated fileprivate static func displayLine(_ text: String) -> String {
            text.hasSuffix("\n") ? text : text + "\n"
        }
        func disconnect() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            if let resizeObserver { NotificationCenter.default.removeObserver(resizeObserver) }
            observer = nil
            resizeObserver = nil
            pending = nil
            current = nil
            syntaxIndex = SyntaxSpanIndex([])
            lineStarts = [0]
            decoratedRange = nil
            relocatedLine = nil
            latestRequestedID = nil
            textView?.selectionEnded = nil
            textView = nil
            scrollView = nil
            ruler = nil
            surface = nil
        }
    }
}

@MainActor final class TrackingTextView: NSTextView {
    // This surface is left-aligned, unwrapped, and has fixed insets and line height. AppKit's
    // default origin lookup forces whole-document layout; the coordinator relocates the viewport
    // explicitly as the fixed-height scroll position crosses line boundaries.
    override var textContainerOrigin: NSPoint {
        NSPoint(x: textContainerInset.width, y: textContainerInset.height)
    }
    var isTrackingSelection = false
    var displayRows: [PresentedLine]?
    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string else { return super.writeSelection(to: pboard, type: type) }
        let range = selectedRange()
        guard range.length > 0, NSMaxRange(range) <= string.utf16.count else { return false }
        let copied: String
        if let displayRows {
            copied = UnifiedProjection.copy(range: range, rows: displayRows)
        } else {
            copied = (string as NSString).substring(with: range)
        }
        return pboard.setString(copied, forType: .string)
    }
    var selectionEnded: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        isTrackingSelection = true
        super.mouseDown(with: event)
        isTrackingSelection = false
        selectionEnded?()
    }
}
