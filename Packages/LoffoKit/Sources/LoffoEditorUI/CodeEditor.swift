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
        text.isVerticallyResizable = true
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
        private var syntaxTheme = EditorSyntaxTheme.standard
        private var applying = false
        private var decorating = false
        private var lastNavigation: UUID?
        private let signposter = OSSignposter(subsystem: "app.loffo", category: "Editor")
        private var observer: NSObjectProtocol?

        fileprivate func connect(_ text: TrackingTextView, surface: EditorSurface) {
            let scroll = surface.scroll
            let ruler = surface.gutter
            self.surface = surface
            textView = text
            scrollView = scroll
            self.ruler = ruler
            text.selectionEnded = { [weak self] in self?.drain() }
            scroll.contentView.postsBoundsChangedNotifications = true
            observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.decorate()
                    self?.ruler?.needsDisplay = true
                    self?.surface?.needsDisplay = true
                }
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
        fileprivate func submit(_ value: CodePresentation, theme: EditorSyntaxTheme) {
            if syntaxTheme != theme {
                syntaxTheme = theme
                if current?.id == value.id { decorate() }
            }
            guard current?.id != value.id, pending?.id != value.id else { return }
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
                let (patch, restoredY, lineCount, numbers) = await Task.detached(priority: .userInitiated) {
                    let patch = TextPatch.between(old, next.text)
                    let anchor = ScrollAnchor.capture(text: old, y: scrollY)
                    let lineCount = next.text.reduce(1) { $1.isNewline ? $0 + 1 : $0 }
                    let numbers = next.diff?.lines.map {
                        ($0.kind == .added ? "+ " : $0.kind == .removed ? "− " : "  ")
                            + String($0.newNumber ?? $0.oldNumber ?? 0)
                    }
                    return (patch, anchor.restoredY(in: next.text, patch: patch), lineCount, numbers)
                }.value
                guard let self else { return }
                if self.textView?.isTrackingSelection == true {
                    if self.pending == nil { self.pending = next }
                    self.applying = false
                    return
                }
                self.apply(
                    next, patch: patch, restoredY: restoredY, capturedY: scrollY, lineCount: lineCount,
                    numbers: numbers)
                self.applying = false
                self.drain()
            }
        }
        private func apply(
            _ next: CodePresentation, patch: TextPatch, restoredY: Double, capturedY: Double, lineCount: Int,
            numbers: [String]?
        ) {
            let interval = signposter.beginInterval("presentationApplied")
            defer { signposter.endInterval("presentationApplied", interval) }
            guard let text = textView, let storage = text.textStorage else { return }
            let selection = text.selectedRange()
            var scroll = scrollView?.contentView.bounds.origin ?? .zero
            // If the user scrolled while a patch was computed, do not undo that input.
            if abs(Double(scroll.y) - capturedY) < 0.5 { scroll.y = CGFloat(restoredY) }
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
            text.textContainerInset.width = 20
            if modeChanged { scroll.x = 0 }
            storage.endEditing()
            current = next
            text.needsDisplay = true
            ruler?.numbers = numbers
            ruler?.diffLines = next.diff?.lines
            ruler?.displayRows = next.rows
            ruler?.lineCount = lineCount
            let newStart = patch.map(selection.location)
            let newEnd = patch.map(selection.location + selection.length)
            text.setSelectedRange(
                NSRange(
                    location: min(newStart, storage.length),
                    length: max(0, min(newEnd, storage.length) - min(newStart, storage.length))))
            scrollView?.contentView.scroll(to: scroll)
            if let scrollView { scrollView.reflectScrolledClipView(scrollView.contentView) }
            ruler?.needsDisplay = true
            surface?.needsDisplay = true
            text.textLayoutManager?.textViewportLayoutController.layoutViewport()
            decorate()
        }
        private func decorate() {
            guard !decorating else { return }
            decorating = true
            defer { decorating = false }
            guard let text = textView, let presentation = current,
                let manager = text.textLayoutManager, let content = manager.textContentManager,
                let viewport = manager.textViewportLayoutController.viewportRange,
                let storage = text.textStorage
            else { return }
            let start = content.offset(from: content.documentRange.location, to: viewport.location)
            let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
            let visible = NSRange(location: max(0, start), length: max(0, end - start))
            storage.beginEditing()
            storage.addAttribute(
                .font, value: EditorTypography.code,
                range: NSIntersectionRange(visible, NSRange(location: 0, length: storage.length)))
            storage.addAttribute(
                .foregroundColor, value: NSColor(syntaxTheme.foreground),
                range: NSIntersectionRange(visible, NSRange(location: 0, length: storage.length)))
            for span in presentation.syntax
            where NSIntersectionRange(span.range, visible).length > 0
                && NSMaxRange(span.range) <= storage.length
            {
                let color = NSColor(syntaxTheme.color(for: span.kind))
                storage.addAttribute(.foregroundColor, value: color, range: span.range)
                if span.kind == .comment {
                    storage.addAttribute(.font, value: EditorTypography.comment, range: span.range)
                }
            }
            storage.endEditing()
        }
        nonisolated fileprivate static func displayLine(_ text: String) -> String {
            text.hasSuffix("\n") ? text : text + "\n"
        }
        fileprivate func disconnect() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            pending = nil
            textView?.selectionEnded = nil
            textView = nil
            scrollView = nil
            ruler = nil
            surface = nil
        }
    }
}

@MainActor final class TrackingTextView: NSTextView {
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
