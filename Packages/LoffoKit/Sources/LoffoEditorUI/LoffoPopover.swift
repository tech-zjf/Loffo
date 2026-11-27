import AppKit
import LoffoDesignSystem
import SwiftUI

private final class PopoverAnchorView: NSView {
    var moved: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        moved?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PopoverWindow: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct PopoverPlacement {
    let edge: Edge
    let frame: NSRect

    static func resolve(anchor: NSRect, size: NSSize, visibleFrame: NSRect, preferredEdge: Edge)
        -> PopoverPlacement
    {
        let width = min(max(1, size.width), max(1, visibleFrame.width))
        let height = min(max(1, size.height), max(1, visibleFrame.height))
        var edge = preferredEdge
        switch edge {
        case .top where anchor.minY - height < visibleFrame.minY:
            if anchor.maxY + height <= visibleFrame.maxY { edge = .bottom }
        case .bottom where anchor.maxY + height > visibleFrame.maxY:
            if anchor.minY - height >= visibleFrame.minY { edge = .top }
        case .leading where anchor.maxX + width > visibleFrame.maxX:
            if anchor.minX - width >= visibleFrame.minX { edge = .trailing }
        case .trailing where anchor.minX - width < visibleFrame.minX:
            if anchor.maxX + width <= visibleFrame.maxX { edge = .leading }
        default:
            break
        }

        let origin: NSPoint
        switch edge {
        case .top:
            origin = NSPoint(x: anchor.midX - width / 2, y: anchor.minY - height)
        case .bottom:
            origin = NSPoint(x: anchor.midX - width / 2, y: anchor.maxY)
        case .leading:
            origin = NSPoint(x: anchor.maxX, y: anchor.midY - height / 2)
        case .trailing:
            origin = NSPoint(x: anchor.minX - width, y: anchor.midY - height / 2)
        }
        let x = min(max(visibleFrame.minX, origin.x), visibleFrame.maxX - width)
        let y = min(max(visibleFrame.minY, origin.y), visibleFrame.maxY - height)
        return PopoverPlacement(edge: edge, frame: NSRect(x: x, y: y, width: width, height: height))
    }
}

private struct PopoverAnchor<Panel: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let content: () -> Panel

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PopoverAnchorView {
        let view = PopoverAnchorView()
        view.moved = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.showIfNeeded(anchor: view)
        }
        return view
    }

    func updateNSView(_ view: PopoverAnchorView, context: Context) {
        context.coordinator.binding = $isPresented
        context.coordinator.arrowEdge = arrowEdge
        context.coordinator.content = content
        context.coordinator.showIfNeeded(anchor: view)
    }

    static func dismantleNSView(_ view: PopoverAnchorView, coordinator: Coordinator) {
        view.moved = nil
        coordinator.close()
    }

    @MainActor final class Coordinator {
        var binding: Binding<Bool>?
        var arrowEdge: Edge = .top
        var content: (() -> Panel)?
        private var panel: PopoverWindow?
        private var host: NSHostingView<LoffoPopoverSurface<Panel>>?
        private var eventMonitor: Any?
        private var moveObserver: NSObjectProtocol?
        private var resizeObserver: NSObjectProtocol?
        private var scrollObserver: NSObjectProtocol?
        private var resignObserver: NSObjectProtocol?
        private var closeObserver: NSObjectProtocol?
        private weak var anchor: PopoverAnchorView?
        private weak var scrollView: NSClipView?
        private var originalPostsBoundsChangedNotifications: Bool?
        private weak var parent: NSWindow?

        func showIfNeeded(anchor: PopoverAnchorView) {
            guard binding?.wrappedValue == true, let content, let window = anchor.window else {
                close()
                return
            }
            self.anchor = anchor
            if panel == nil || parent !== window {
                close()
                parent = window
                let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? window.frame
                let maximumSize = Self.maximumPopoverSize(in: visibleFrame)
                let host = NSHostingView(
                    rootView: LoffoPopoverSurface(
                        edge: .top, maximumSize: maximumSize, content: content))
                let panel = PopoverWindow(
                    contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered,
                    defer: false)
                panel.isOpaque = false
                panel.backgroundColor = .clear
                panel.hasShadow = true
                panel.isReleasedWhenClosed = false
                panel.contentView = host
                panel.becomesKeyOnlyIfNeeded = true
                window.addChildWindow(panel, ordered: .above)
                self.host = host
                self.panel = panel
                let center = NotificationCenter.default
                moveObserver = center.addObserver(
                    forName: NSWindow.didMoveNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } }
                resizeObserver = center.addObserver(
                    forName: NSWindow.didResizeNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } }
                closeObserver = center.addObserver(
                    forName: NSWindow.willCloseNotification, object: window, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
                resignObserver = center.addObserver(
                    forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
                ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } }
                scrollView =
                    sequence(first: anchor.superview, next: { $0?.superview })
                    .compactMap { $0 as? NSClipView }
                    .first
                if let scrollView {
                    originalPostsBoundsChangedNotifications = scrollView.postsBoundsChangedNotifications
                    scrollView.postsBoundsChangedNotifications = true
                    scrollObserver = center.addObserver(
                        forName: NSView.boundsDidChangeNotification, object: scrollView, queue: .main
                    ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } }
                }
                eventMonitor = NSEvent.addLocalMonitorForEvents(
                    matching: [.leftMouseDown, .rightMouseDown, .keyDown]
                ) { [weak self] event in
                    guard let self, let panel = self.panel else { return event }
                    if event.type == .keyDown && event.keyCode == 53 {
                        self.dismiss()
                        return nil
                    }
                    if event.type != .keyDown, event.window !== panel,
                        let anchor = self.anchor, let window = anchor.window
                    {
                        let location = NSEvent.mouseLocation
                        let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
                        if !anchorRect.contains(location) { self.dismiss() }
                    }
                    return event
                }
            }
            reposition()
            panel?.orderFront(nil)
        }

        private func reposition() {
            guard let anchor, let window = anchor.window, let panel, let host, let content,
                let screen = window.screen ?? NSScreen.main
            else { return }
            let anchorRect = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
            if anchor.isHiddenOrHasHiddenAncestor {
                dismiss()
                return
            }
            if let scrollView {
                let visibleRect = window.convertToScreen(scrollView.convert(scrollView.bounds, to: nil))
                if !visibleRect.intersects(anchorRect) {
                    dismiss()
                    return
                }
            }
            let bounds = screen.visibleFrame
            var edge: Edge
            switch arrowEdge {
            case .top: edge = .top
            case .bottom: edge = .bottom
            case .leading: edge = .trailing
            case .trailing: edge = .leading
            }
            let visibleSize = screen.visibleFrame.size
            let maximumSize = Self.maximumPopoverSize(in: screen.visibleFrame)
            host.rootView = LoffoPopoverSurface(
                edge: edge, maximumSize: maximumSize, content: content)
            var size = host.fittingSize
            size.width = min(size.width, min(visibleSize.width, maximumSize.width + 5))
            size.height = min(size.height, min(visibleSize.height, maximumSize.height + 5))
            let placement = PopoverPlacement.resolve(
                anchor: anchorRect, size: size, visibleFrame: bounds, preferredEdge: edge)
            if placement.edge != edge {
                host.rootView = LoffoPopoverSurface(
                    edge: placement.edge, maximumSize: maximumSize, content: content)
            }
            panel.setFrame(placement.frame, display: true)
        }

        private static func maximumPopoverSize(in visibleFrame: NSRect) -> CGSize {
            CGSize(
                width: max(1, min(420, visibleFrame.width - 24)),
                height: max(1, min(560, visibleFrame.height - 24)))
        }

        func close() {
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            eventMonitor = nil
            let center = NotificationCenter.default
            if let moveObserver { center.removeObserver(moveObserver) }
            if let resizeObserver { center.removeObserver(resizeObserver) }
            if let scrollObserver { center.removeObserver(scrollObserver) }
            if let resignObserver { center.removeObserver(resignObserver) }
            if let closeObserver { center.removeObserver(closeObserver) }
            moveObserver = nil
            resizeObserver = nil
            scrollObserver = nil
            resignObserver = nil
            closeObserver = nil
            if let panel {
                parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            panel = nil
            host = nil
            if let scrollView, let originalPostsBoundsChangedNotifications {
                scrollView.postsBoundsChangedNotifications = originalPostsBoundsChangedNotifications
            }
            scrollView = nil
            originalPostsBoundsChangedNotifications = nil
            parent = nil
        }

        private func dismiss() {
            binding?.wrappedValue = false
            close()
        }
    }
}

extension View {
    /// Anchors an application-styled panel to the source view and constrains it to the visible screen.
    public func loffoPopover<Content: View>(
        isPresented: Binding<Bool>, arrowEdge: Edge = .top, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(PopoverAnchor(isPresented: isPresented, arrowEdge: arrowEdge, content: content))
    }
}
