import AppKit
import LoffoDomain
import SwiftUI
import Testing

@testable import LoffoEditorUI

@Test @MainActor func nativeSelectionLeaseDefersRefreshAndCopiesVisibleCode() async throws {
    _ = NSApplication.shared
    let initial = "const a = 'é';\nconst b = 1;\n"
    let updated = "// inserted\nconst a = 'e\u{301}';\nconst b = 1;\n"
    let host = NSHostingView(
        rootView: CodeEditor(
            presentation: CodePresentation(
                text: initial, syntax: [SyntaxSpan(range: NSRange(location: 0, length: 5), kind: .keyword)]),
            accessibilityName: "src/邮件/long-source-name.ts"))
    let window = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 900, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var editor: TrackingTextView?
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        editor = descendants(host).compactMap { $0 as? TrackingTextView }.first
        if editor?.string == initial { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let text = try #require(editor)
    #expect(Array(text.string.utf8) == Array(initial.utf8))
    #expect(text.textLayoutManager != nil)
    #expect(text.accessibilityLabel() == "src/邮件/long-source-name.ts")
    let keywordColor =
        (text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)?
        .usingColorSpace(.sRGB)
    #expect(keywordColor != nil)
    #expect((keywordColor?.redComponent ?? 0) > 0.6)
    #expect((keywordColor?.blueComponent ?? 0) > 0.9)
    text.setSelectedRange(NSRange(location: 0, length: initial.utf16.count))
    text.isTrackingSelection = true
    host.rootView = CodeEditor(presentation: CodePresentation(text: updated))
    try await Task.sleep(for: .milliseconds(100))
    #expect(Array(text.string.utf8) == Array(initial.utf8))
    #expect(text.selectedRange().length == initial.utf16.count)
    let clipboard = NSPasteboard(name: NSPasteboard.Name("loffo-tests-\(UUID())"))
    defer { clipboard.releaseGlobally() }
    clipboard.declareTypes([.string], owner: nil)
    #expect(text.writeSelection(to: clipboard, type: .string))
    #expect(clipboard.string(forType: .string).map { Array($0.utf8) } == Array(initial.utf8))
    text.isTrackingSelection = false
    text.selectionEnded?()
    for _ in 0..<100 where !text.string.utf8.elementsEqual(updated.utf8) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Array(text.string.utf8) == Array(updated.utf8))
    #expect(NSMaxRange(text.selectedRange()) <= updated.utf16.count)
}

@Test @MainActor func diffGutterNeverOverlapsToolbarOrUnindentedCode() async throws {
    _ = NSApplication.shared
    let lines = [
        DiffLine(text: "return {\n", kind: .removed, oldNumber: 1, newNumber: nil),
        DiffLine(text: "return value\n", kind: .added, oldNumber: nil, newNumber: 1),
        DiffLine(text: "}\n", kind: .context, oldNumber: 2, newNumber: 2),
    ]
    let result = DiffResult(lines: lines, isCoarse: false)
    let projection = UnifiedProjection(result: result)
    let host = NSHostingView(
        rootView: VStack(spacing: 0) {
            Text("Toolbar").frame(height: 54)
            CodeEditor(
                presentation: CodePresentation(text: projection.text, diff: result, rows: projection.rows))
        })
    let window = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 1000, height: 600),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var editor: TrackingTextView?
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        editor = descendants(host).compactMap { $0 as? TrackingTextView }.first
        if editor?.string == projection.text { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let text = try #require(editor)
    let scroll = try #require(text.enclosingScrollView)
    let surface = try #require(scroll.superview as? EditorSurface)
    let ruler = surface.gutter
    let rulerFrame = ruler.convert(ruler.bounds, to: host)
    let editorFrame = surface.convert(surface.bounds, to: host)
    #expect(editorFrame.contains(rulerFrame))
    let viewportInWindow = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
    let first = window.convertFromScreen(
        text.firstRect(forCharacterRange: NSRange(location: 1, length: 1), actualRange: nil))
    let second = window.convertFromScreen(
        text.firstRect(forCharacterRange: NSRange(location: 10, length: 1), actualRange: nil))
    let rulerInWindow = ruler.convert(ruler.bounds, to: nil)
    // Separate clipped sibling frames must remain disjoint even during horizontal scrolling.
    #expect(abs(first.minX - rulerInWindow.maxX - 25) < 1)
    #expect(first.minX >= viewportInWindow.minX + 10)
    #expect(abs(first.minX - second.minX) < 1)
    #expect(abs(abs(first.minY - second.minY) - 20) < 1)
}

@Test @MainActor func horizontalScrollAndModeSwitchKeepGlyphsOutsideGutter() async throws {
    _ = NSApplication.shared
    let longLine = "export const value = '" + String(repeating: "content", count: 100) + "';\n"
    let result = DiffResult(
        lines: [
            DiffLine(text: longLine, kind: .removed, oldNumber: 1, newNumber: nil),
            DiffLine(text: "return value;\n", kind: .added, oldNumber: nil, newNumber: 1),
        ], isCoarse: false)
    let projection = UnifiedProjection(result: result)
    let reading = CodePresentation(text: longLine)
    let comparison = CodePresentation(text: projection.text, diff: result, rows: projection.rows)
    let host = NSHostingView(rootView: CodeEditor(presentation: reading))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if descendants(host).compactMap({ $0 as? NSTextView }).first?.string == reading.text { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let surface = try #require(descendants(host).compactMap { $0 as? EditorSurface }.first)
    let scroll = surface.scroll
    for presentation in [comparison, reading, comparison] {
        scroll.contentView.scroll(to: NSPoint(x: 240, y: 0))
        host.rootView = CodeEditor(presentation: presentation)
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if (scroll.documentView as? NSTextView)?.string == presentation.text { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        #expect(surface.gutter.frame.maxX == scroll.frame.minX)
        #expect(surface.gutter.frame.width == (presentation.diff == nil ? 48 : 118))
        #expect(scroll.frame.maxX == surface.bounds.maxX - (presentation.diff == nil ? 0 : 12))
        #expect(abs(scroll.contentView.bounds.minX) < 1)
        #expect(scroll.layer?.masksToBounds == true)
        #expect(scroll.contentView.layer?.masksToBounds == true)
        #expect(scroll.contentView.layer?.mask == nil)
        let clip = scroll.contentView.convert(scroll.contentView.bounds, to: scroll)
        let scroller = try #require(scroll.verticalScroller)
        #expect(clip.maxX <= scroller.frame.minX)
        let rulerFrame = surface.gutter.frame
        scroll.contentView.scroll(to: NSPoint(x: 180, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        host.layoutSubtreeIfNeeded()
        #expect(surface.gutter.frame == rulerFrame)
        let clipInSurface = scroll.contentView.convert(scroll.contentView.bounds, to: surface)
        #expect(clipInSurface.minX >= rulerFrame.maxX)
        // Render the hierarchy in both positions; glyphs cannot enter the ruler's clipped sibling.
        let before = try #require(surface.gutter.bitmapImageRepForCachingDisplay(in: surface.gutter.bounds))
        surface.gutter.cacheDisplay(in: surface.gutter.bounds, to: before)
        let headingArea = NSRect(x: 118, y: 4, width: surface.bounds.width - 118, height: 20)
        let headingBefore = try #require(surface.bitmapImageRepForCachingDisplay(in: headingArea))
        if presentation.diff != nil { surface.cacheDisplay(in: headingArea, to: headingBefore) }
        scroll.contentView.scroll(to: NSPoint(x: 360, y: 0))
        scroll.reflectScrolledClipView(scroll.contentView)
        let after = try #require(surface.gutter.bitmapImageRepForCachingDisplay(in: surface.gutter.bounds))
        surface.gutter.cacheDisplay(in: surface.gutter.bounds, to: after)
        if presentation.diff != nil {
            let headingAfter = try #require(surface.bitmapImageRepForCachingDisplay(in: headingArea))
            surface.cacheDisplay(in: headingArea, to: headingAfter)
            #expect(
                headingBefore.representation(using: .png, properties: [:])
                    == headingAfter.representation(using: .png, properties: [:]))
        }
        #expect(
            before.representation(using: .png, properties: [:])
                == after.representation(using: .png, properties: [:]))
    }
    host.rootView = CodeEditor(presentation: comparison, navigation: CodeNavigation(line: 1))
    try await Task.sleep(for: .milliseconds(40))
    #expect(surface.gutter.frame.maxX == scroll.frame.minX)
}

@Test @MainActor func virtualHunkHeaderNeverInheritsFirstSourceLineColor() throws {
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
    scroll.drawsBackground = false
    let surface = EditorSurface(scroll: scroll, gutterWidth: 118)
    surface.frame = NSRect(x: 0, y: 0, width: 500, height: 100)
    let window = NSWindow(contentRect: surface.bounds, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = surface
    window.orderBack(nil)
    defer { window.close() }
    func colors(_ kind: DiffKind) throws -> [NSColor] {
        let line = DiffLine(text: "value\n", kind: kind, oldNumber: 1, newNumber: 1)
        surface.gutter.diffLines = [line]
        surface.gutter.displayRows = [PresentedLine(line: nil, heading: "@@"), PresentedLine(line: line)]
        surface.needsDisplay = true
        surface.layoutSubtreeIfNeeded()
        let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
        return try [12, 32].map { y in
            try #require(
                bitmap.colorAt(x: Int(125 * scale), y: Int(CGFloat(y) * scale))?.usingColorSpace(.sRGB))
        }
    }
    let added = try colors(.added)
    let removed = try colors(.removed)
    #expect(added[0] == removed[0])
    #expect(added[1] != removed[1])
}

@Test @MainActor func verticalScrollKeepsCodeVisibleAcrossTheViewport() async throws {
    _ = NSApplication.shared
    let source = (0..<150).map { "let visibleLine\($0) = \($0)\n" }.joined()
    let host = NSHostingView(rootView: CodeEditor(presentation: CodePresentation(text: source)))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    var surface: EditorSurface?
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        surface = descendants(host).compactMap { $0 as? EditorSurface }.first
        if (surface?.scroll.documentView as? NSTextView)?.string == source { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let editor = try #require(surface)
    let scroll = editor.scroll
    for offset: CGFloat in [0, 240, 480] {
        scroll.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scroll.reflectScrolledClipView(scroll.contentView)
        editor.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let area = NSRect(x: 80, y: 260, width: 300, height: 180)
        let bitmap = try #require(editor.bitmapImageRepForCachingDisplay(in: area))
        editor.cacheDisplay(in: area, to: bitmap)
        var darkPixels = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.redComponent < 0.6 && color.greenComponent < 0.6 && color.blueComponent < 0.6 {
                    darkPixels += 1
                }
            }
        }
        #expect(darkPixels > 100, "Text must remain visible near the bottom after scrolling to \(offset)")
    }
}
