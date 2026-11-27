import AppKit
import LoffoDesignSystem
import LoffoDiff
import LoffoDocument
import LoffoDomain
import LoffoInfrastructure
import SwiftUI
import Testing

@testable import LoffoEditorUI
@testable import LoffoFeatures

@Test func sidebarBrandAndActionsClearTheNativeTitlebarControls() {
    let logoTop = LoffoMetrics.railTopInset + (LoffoMetrics.header - LoffoMetrics.brandMark)
    let logoBottom = LoffoMetrics.railTopInset + LoffoMetrics.header
    let firstActionTop = logoBottom + LoffoMetrics.brandBottomSpacing + 10

    #expect(logoTop == 32)
    #expect(logoBottom == 60)
    #expect(firstActionTop == 80)
    #expect(LoffoScrollMetrics.defaultContentGutter == 10)
}

@Test func sidebarResizeWaitsAtMinimumBeforeCollapsing() {
    let minimum = SidebarResize.minimumWidth
    let startWidth: CGFloat = 284
    let atMinimum = SidebarResize.resolve(
        startWidth: startWidth, translation: minimum - startWidth, maximumWidth: 440)
    let beforeThreshold = SidebarResize.resolve(
        startWidth: startWidth,
        translation: minimum - startWidth - SidebarResize.collapseDragThreshold + 1,
        maximumWidth: 440)
    let atThreshold = SidebarResize.resolve(
        startWidth: startWidth,
        translation: minimum - startWidth - SidebarResize.collapseDragThreshold,
        maximumWidth: 440)

    #expect(atMinimum.width == minimum && !atMinimum.isCollapsed)
    #expect(beforeThreshold.width == minimum && !beforeThreshold.isCollapsed)
    #expect(atThreshold.width == 0 && atThreshold.isCollapsed)
}

@Test @MainActor func quickOpenKeyboardSelectionScrollsTheLazyResultsList() async throws {
    _ = NSApplication.shared
    let files = (0..<10_000).map { ProjectFile(path: String(format: "Sources/File%05d.swift", $0)) }
    let observed = QuickOpenTestObservation()
    let host = NSHostingView(rootView: QuickOpenTestHost(files: files, observed: observed))
    let window = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 1280, height: 720),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    defer { window.close() }

    for _ in 0..<20 { try await Task.sleep(for: .milliseconds(10)) }
    let field = try #require(viewDescendants(host).compactMap { $0 as? NSTextField }.first)
    #expect(window.makeFirstResponder(field))
    for _ in 0..<30 {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F701}",
                charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125))
        window.sendEvent(event)
        try await Task.sleep(for: .milliseconds(10))
    }
    try await Task.sleep(for: .milliseconds(100))
    host.layoutSubtreeIfNeeded()
    let scroll = try #require(
        viewDescendants(host).compactMap { $0 as? NSScrollView }
            .first(where: { $0.contentView.bounds.height > 100 }))
    let metrics = "clip=\(scroll.contentView.bounds), document=\(scroll.documentView?.bounds ?? .zero)"
    #expect(
        scroll.contentView.bounds.minY > 0,
        "Down-arrow navigation must scroll past the first row; \(metrics)")
    let selectedRowTop = CGFloat(30 * 32)
    #expect(
        scroll.contentView.bounds.minY <= selectedRowTop
            && scroll.contentView.bounds.maxY >= selectedRowTop + 30,
        "The keyboard-selected row must remain visible; row=\(selectedRowTop), clip=\(scroll.contentView.bounds)"
    )
    let returnEvent = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    window.sendEvent(returnEvent)
    #expect(observed.openedPath == "Sources/File00030.swift")
}

@Test func popoverPlacementFlipsAndRemainsInsideVisibleDisplay() {
    let visible = NSRect(x: 100, y: 80, width: 1280, height: 720)
    let anchor = NSRect(x: 1320, y: 90, width: 30, height: 30)
    let placement = PopoverPlacement.resolve(
        anchor: anchor, size: NSSize(width: 360, height: 300), visibleFrame: visible,
        preferredEdge: .leading)
    #expect(placement.edge == .trailing)
    #expect(visible.contains(placement.frame))
    #expect(placement.frame.maxX <= anchor.minX)
}

@Test @MainActor func popoverSurfaceFittingSizeIsBoundedForLargeContent() {
    _ = NSApplication.shared
    let surface = LoffoPopoverSurface(maximumSize: CGSize(width: 380, height: 480)) {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(0..<200, id: \.self) { index in
                Text("A very long outline symbol name \(index)")
            }
        }
        .frame(width: 380)
    }
    let size = NSHostingView(rootView: surface).fittingSize
    #expect(size.width <= 385)
    #expect(size.height <= 485)
}

@Test @MainActor func longOutlineSymbolsStayInsideTheirFixedPopoverColumn() {
    _ = NSApplication.shared
    let row = OutlineSymbolRow(name: String(repeating: "VeryLongNestedSymbolName.", count: 40))
    let host = NSHostingView(rootView: row)
    host.frame = NSRect(x: 0, y: 0, width: 324, height: 24)
    host.layoutSubtreeIfNeeded()

    #expect(host.fittingSize.width <= 324)
}

@Test @MainActor func pathTooltipCardFitsShortAndLongPaths() {
    _ = NSApplication.shared
    for path in ["Packages/LoffoKit/Package.resolved", String(repeating: "long-segment/", count: 100)] {
        let host = NSHostingView(rootView: PathTooltipCard(text: path))
        let size = host.fittingSize
        #expect(size.width >= 100 && size.width <= 320)
        #expect(size.height >= 30 && size.height <= 174)
    }
}

@Test @MainActor func workspaceKeepsNativeWindowControlsVisible() throws {
    _ = NSApplication.shared
    let window = NSWindow(
        contentRect: NSRect(x: 50, y: 50, width: 960, height: 540),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = VisibilityView { _ in }
    window.contentView = view
    defer { window.close() }
    for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        let button = try #require(window.standardWindowButton(type))
        #expect(!button.isHidden)
        #expect(button.isEnabled)
    }
}

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
    try await waitForChangesSidebar(model, host: host)
    let text = try #require(viewDescendants(host).compactMap { $0 as? NSTextView }.first)
    #expect(text.accessibilityLabel() == path)
    let surface = try #require(text.enclosingScrollView?.superview as? EditorSurface)
    let diffFrame = surface.convert(surface.bounds, to: host)
    #expect(diffFrame.minX >= 348)
    #expect(
        host.bounds.maxX - diffFrame.maxX <= 24,
        "Changes Diff should use the workspace width without a right-side detail panel")
    model.setDiff(false)
    for _ in 0..<100 where model.presentation?.diff != nil || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    host.layoutSubtreeIfNeeded()
    let expected = "export const greeting = \"你好 👩🏽‍💻 مرحبا\";\n"
    for _ in 0..<200 {
        if viewDescendants(host).compactMap({ $0 as? NSTextView }).first?.string == expected { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    let readingText = try #require(viewDescendants(host).compactMap { $0 as? NSTextView }.first)
    #expect(readingText.accessibilityLabel() == path)
    #expect(readingText.string.utf8.elementsEqual(expected.utf8))
    let readingSurface = try #require(readingText.enclosingScrollView?.superview as? EditorSurface)
    #expect(readingSurface.convert(readingSurface.bounds, to: host).minX >= 348)
    let readingScroll = try #require(readingText.enclosingScrollView)
    #expect(readingSurface.gutter.frame.maxX <= readingScroll.frame.minX)
    model.setDiff(true)
    for _ in 0..<100 where model.presentation?.diff == nil || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    try await waitForChangesSidebar(model, host: host)
    host.layoutSubtreeIfNeeded()
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
    try await waitForChangesSidebar(model, host: host)
    host.layoutSubtreeIfNeeded()
    let switched = try sidebarBitmap(host)

    let freshModel = WorkspaceModel(
        workspace: LayoutWorkspace(path: "src/email/send.ts"), syntax: TreeSyntax(),
        diff: LineDiff(), observer: FileWatchHub())
    await freshModel.open(folder.url)
    freshModel.select("src/email/send.ts")
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
    for _ in 0..<100 where freshModel.presentation == nil || freshModel.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    freshModel.setDiff(true)
    for _ in 0..<100 where freshModel.presentation?.diff == nil || freshModel.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    try await waitForChangesSidebar(freshModel, host: freshHost)
    freshHost.layoutSubtreeIfNeeded()
    let fresh = try sidebarBitmap(freshHost)
    #expect(switched == fresh, "Changing modes must render the same rows as a fresh Changes view")
}

@MainActor private func waitForChangesSidebar(_ model: WorkspaceModel, host: NSView) async throws {
    for _ in 0..<300 where model.repositoryHistoryIsLoading {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.repositoryHistoryIsLoading)
    host.layoutSubtreeIfNeeded()
    host.displayIfNeeded()
    try await Task.sleep(for: .milliseconds(150))
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
        #expect(scrolls.count == 2, "The workspace has one navigation list and one code surface")
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
    let area = NSRect(x: 0, y: 0, width: 520, height: LoffoMetrics.statusBar)
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

@MainActor private struct QuickOpenTestHost: View {
    let files: [ProjectFile]
    @ObservedObject var observed: QuickOpenTestObservation
    @State private var query = "file"

    var body: some View {
        QuickOpenPanel(
            query: $query, files: files, filesRevision: UUID(),
            onOpen: { observed.openedPath = $0 }, onDismiss: {})
    }
}

@MainActor private final class QuickOpenTestObservation: ObservableObject {
    @Published var openedPath: String?
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
