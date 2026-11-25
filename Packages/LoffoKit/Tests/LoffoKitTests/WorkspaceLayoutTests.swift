import AppKit
import LoffoDiff
import LoffoDocument
import LoffoDomain
import LoffoInfrastructure
import SwiftUI
import Testing

@testable import LoffoEditorUI
@testable import LoffoFeatures

@Test @MainActor func narrowWorkspaceKeepsNativeTextAndGutterInsideTheirColumn() async throws {
    _ = NSApplication.shared
    let folder = try TemporaryFolder()
    let path =
        (0..<18).map { "level-\($0)" }.joined(separator: "/")
        + "/邮件-مرحبا-very-long-transactional-email-handler.ts"
    let model = WorkspaceModel(
        workspace: LayoutWorkspace(path: path), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    await model.open(folder.url)
    model.setDiff(true)
    model.select(path)
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 960, height: 540),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
        model.close()
        window.close()
    }
    for _ in 0..<100 where model.presentation == nil || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.presentation?.diff != nil)
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let text = try #require(viewDescendants(host).compactMap { $0 as? NSTextView }.first)
    #expect(text.accessibilityLabel() == path)
    let surface = try #require(text.enclosingScrollView?.superview as? EditorSurface)
    #expect(surface.convert(surface.bounds, to: host).minX >= 348)
    let before = try sidebarBitmap(host)
    model.setDiff(false)
    for _ in 0..<100 where model.presentation?.diff != nil || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let readingText = try #require(viewDescendants(host).compactMap { $0 as? NSTextView }.first)
    #expect(readingText.accessibilityLabel() == path)
    #expect(readingText.string.utf8.elementsEqual("export const greeting = \"你好 👩🏽‍💻 مرحبا\";\n".utf8))
    let readingSurface = try #require(readingText.enclosingScrollView?.superview as? EditorSurface)
    #expect(readingSurface.convert(readingSurface.bounds, to: host).minX >= 348)
    let readingScroll = try #require(readingText.enclosingScrollView)
    #expect(readingSurface.gutter.frame.maxX <= readingScroll.frame.minX)
    model.setDiff(true)
    for _ in 0..<100 where model.presentation?.diff == nil || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    #expect(try sidebarBitmap(host) == before, "Changes rows must not reuse directory-tree rendering")
}

@Test @MainActor func switchingFromTreeToChangesMatchesFreshChangesRows() async throws {
    _ = NSApplication.shared
    let folder = try TemporaryFolder()
    let model = WorkspaceModel(
        workspace: LayoutWorkspace(path: "src/email/send.ts"), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    await model.open(folder.url)
    model.select("src/email/send.ts")
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 1280, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
        model.close()
        window.close()
    }
    for _ in 0..<100 where model.presentation == nil || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    model.setDiff(true)
    for _ in 0..<100 where model.presentation?.diff == nil || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let switched = try sidebarBitmap(host)

    let freshModel = WorkspaceModel(
        workspace: LayoutWorkspace(path: "src/email/send.ts"), syntax: TreeSyntax(),
        diff: LineDiff(), observer: FileWatchHub())
    await freshModel.open(folder.url)
    freshModel.select("src/email/send.ts")
    freshModel.setDiff(true)
    let freshHost = NSHostingView(rootView: WorkspaceView(model: freshModel))
    let freshWindow = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 1280, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false)
    freshWindow.isReleasedWhenClosed = false
    freshWindow.contentView = freshHost
    freshWindow.orderBack(nil)
    defer {
        freshModel.close()
        freshWindow.close()
    }
    for _ in 0..<100 where freshModel.presentation?.diff == nil || freshModel.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    freshHost.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
    let fresh = try sidebarBitmap(freshHost)
    try fresh.write(to: URL(fileURLWithPath: "/private/tmp/sidebar-fresh.png"))
    #expect(switched == fresh, "Changing modes must render the same rows as a fresh Changes view")
}

@Test @MainActor func everyWorkspaceScrollSurfaceUsesBorderlessOverlayIndicators() async throws {
    _ = NSApplication.shared
    let folder = try TemporaryFolder()
    let model = WorkspaceModel(
        workspace: LayoutWorkspace(path: "src/email/send.ts"), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    await model.open(folder.url)
    model.select("src/email/send.ts")
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 1280, height: 720),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
        model.close()
        window.close()
    }
    for diff in [false, true, false] {
        model.setDiff(diff)
        for _ in 0..<100 where model.presentation == nil || model.isUpdating {
            try await Task.sleep(for: .milliseconds(10))
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let scrolls = viewDescendants(host).compactMap { $0 as? NSScrollView }
        #expect(scrolls.count == (diff ? 3 : 2))
        for scroll in scrolls {
            #expect(
                scroll.scrollerStyle == .overlay,
                "diff=\(diff), frame=\(scroll.frame), type=\(type(of: scroll))")
            #expect(scroll.borderType == .noBorder)
            #expect(!scroll.drawsBackground)
            // SwiftUI-owned panel scroll views must restore the overlay style immediately.
            if scroll.documentView is NSTextView == false {
                scroll.scrollerStyle = .legacy
                #expect(scroll.scrollerStyle == .overlay)
            }
        }
    }
}

@Test @MainActor func localWorkspaceChromeShowsProjectNameWithoutAccountOrParentFolder() async throws {
    _ = NSApplication.shared
    let model = WorkspaceModel(
        workspace: LayoutWorkspace(path: "scripts/check-localization-coverage.py"), syntax: TreeSyntax(),
        diff: LineDiff(), observer: FileWatchHub())
    await model.open(URL(fileURLWithPath: "/tmp/mine-project/Loffo", isDirectory: true))
    defer { model.close() }
    let view = WorkspaceView(model: model)
    #expect(view.projectDisplayName == "Loffo")
    #expect(view.projectDisplayName != "mine-project")
    #expect(model.fileListingWarning == nil)
}

@Test @MainActor func changesHeaderKeepsBranchAndWatchStatusVisible() async throws {
    _ = NSApplication.shared
    let folder = try TemporaryFolder()
    let model = WorkspaceModel(
        workspace: LayoutWorkspace(path: "src/email/send.ts"), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    await model.open(folder.url)
    model.select("src/email/send.ts")
    model.setDiff(true)
    let host = NSHostingView(rootView: WorkspaceView(model: model))
    let window = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 1280, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer {
        model.close()
        window.close()
    }
    for _ in 0..<100 where model.presentation == nil || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    host.layoutSubtreeIfNeeded()
    try await Task.sleep(for: .milliseconds(100))
    let area = NSRect(x: 470, y: 28, width: 520, height: 48)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: area))
    host.cacheDisplay(in: area, to: bitmap)
    var visibleInk = 0
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            if color.redComponent < 0.86 || color.greenComponent < 0.86 || color.blueComponent < 0.86 {
                visibleInk += 1
            }
        }
    }
    #expect(visibleInk > 250, "Diff header must retain branch and Watching files metadata")
}

@MainActor private func sidebarBitmap(_ host: NSView) throws -> Data {
    let area = NSRect(x: 88, y: 145, width: 236, height: 55)
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: area))
    host.cacheDisplay(in: area, to: bitmap)
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@MainActor private func viewDescendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(viewDescendants)
}

private struct LayoutWorkspace: WorkspaceReading {
    let path: String
    func files(in root: URL) -> FileListing {
        .init(files: [ProjectFile(path: path)], isLimited: false, usesGitIgnore: true)
    }
    func read(_ url: URL) -> TextSnapshot {
        .init(url: url, version: 1, text: "export const greeting = \"你好 👩🏽‍💻 مرحبا\";\n")
    }
    func baseline(in root: URL, path: String, workingText: String) -> ComparisonInput {
        .init(before: "", after: workingText, label: "fixture")
    }
}
