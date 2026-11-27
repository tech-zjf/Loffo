import AppKit
import LoffoDomain
import SwiftUI
import Testing

@testable import LoffoEditorUI

@Test @MainActor func diffBackgroundReachesEditorEdgeAndLeavesNumberColumnsNeutral() async throws {
    _ = NSApplication.shared
    let result = DiffResult(
        lines: [
            DiffLine(text: "old\n", kind: .removed, oldNumber: 1, newNumber: nil),
            DiffLine(text: "old again\n", kind: .removed, oldNumber: 2, newNumber: nil),
            DiffLine(text: "new\n", kind: .added, oldNumber: nil, newNumber: 1),
            DiffLine(text: "same\n", kind: .context, oldNumber: 3, newNumber: 2),
        ], isCoarse: false)
    let projection = UnifiedProjection(result: result)
    let host = NSHostingView(
        rootView: CodeEditor(
            presentation: CodePresentation(
                text: projection.text, diff: result, rows: projection.rows)))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 180),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    for _ in 0..<100 {
        host.layoutSubtreeIfNeeded()
        if descendants(host).compactMap({ $0 as? NSTextView }).first?.string == projection.text { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let surface = try #require(descendants(host).compactMap { $0 as? EditorSurface }.first)
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(surface.bitmapImageRepForCachingDisplay(in: surface.bounds))
    surface.cacheDisplay(in: surface.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / surface.bounds.width
    func color(_ x: CGFloat, _ y: CGFloat) throws -> NSColor {
        try #require(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    }
    #expect(try color(10, 31) == color(10, 91), "Old/new line-number columns keep the neutral paper color")
    #expect(try color(98, 31) != color(10, 31), "Deletion tint begins at the sign column")
    #expect(try color(350, 31) == color(98, 31), "Sign and code backgrounds form one continuous row")
    #expect(try color(498, 31) == color(350, 31), "Diff tint reaches the edge under the overlay scroller")
    #expect(try color(498, 31) != color(498, 91), "The right edge follows the row's diff state")
}

@Test @MainActor func viewportDecorationIsIdenticalForFullAndTiledRedraw() throws {
    let rows = [
        PresentedLine(line: nil, heading: "@@ −1 +1 @@"),
        PresentedLine(line: DiffLine(text: "old\n", kind: .removed, oldNumber: 1, newNumber: nil)),
        PresentedLine(line: DiffLine(text: "old again\n", kind: .removed, oldNumber: 2, newNumber: nil)),
        PresentedLine(line: DiffLine(text: "new\n", kind: .added, oldNumber: nil, newNumber: 1)),
        PresentedLine(line: nil, heading: "@@ −20 +20 @@"),
        PresentedLine(line: DiffLine(text: "last\n", kind: .added, oldNumber: nil, newNumber: 20)),
    ]
    let bounds = NSRect(x: 0, y: 0, width: 500, height: 160)
    func render(_ dirtyRects: [NSRect], scrollY: CGFloat = 0) throws -> NSBitmapImageRep {
        let bitmap = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 500, pixelsHigh: 160, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 32))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.translateBy(x: 0, y: 160)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSColor.white.setFill()
        bounds.fill()
        for rect in dirtyRects {
            NSGraphicsContext.saveGraphicsState()
            rect.clip()
            DiffDecoration.draw(
                rows: rows, lines: nil, viewport: bounds, dirty: rect,
                scrollY: scrollY, gutterWidth: 118)
            NSGraphicsContext.restoreGraphicsState()
        }
        return bitmap
    }
    let tiles = stride(from: 0, to: 160, by: 17).flatMap { y in
        stride(from: 0, to: 500, by: 73).map { x in
            NSRect(x: x, y: y, width: min(73, 500 - x), height: min(17, 160 - y))
        }
    }
    for scrollY: CGFloat in [0, 13, 40] {
        let full = try render([bounds], scrollY: scrollY)
        let tiled = try render(tiles, scrollY: scrollY)
        #expect(
            full.representation(using: .png, properties: [:])
                == tiled.representation(using: .png, properties: [:]))
    }
    let full = try render([bounds])
    func color(_ x: Int, _ y: Int) throws -> NSColor {
        try #require(full.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }
    #expect(try color(96, 24) != color(96, 44), "Only the top of a deletion block is rounded")
    #expect(try color(96, 44) == color(350, 44), "Adjacent deleted rows join without a seam")
}
