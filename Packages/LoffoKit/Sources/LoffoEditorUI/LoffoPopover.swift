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
                let host = NSHostingView(rootView: LoffoPopoverSurface(edge: .top, content: content))
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
            host.rootView = LoffoPopoverSurface(edge: edge, content: content)
            var size = host.fittingSize
            switch edge {
            case .top where anchorRect.minY - size.height < bounds.minY: edge = .bottom
            case .bottom where anchorRect.maxY + size.height > bounds.maxY: edge = .top
            case .leading where anchorRect.maxX + size.width > bounds.maxX: edge = .trailing
            case .trailing where anchorRect.minX - size.width < bounds.minX: edge = .leading
            default: break
            }
            host.rootView = LoffoPopoverSurface(edge: edge, content: content)
            size = host.fittingSize
            let origin: NSPoint
            switch edge {
            case .top:
                origin = NSPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.minY - size.height)
            case .bottom:
                origin = NSPoint(x: anchorRect.midX - size.width / 2, y: anchorRect.maxY)
            case .leading:
                origin = NSPoint(x: anchorRect.maxX, y: anchorRect.midY - size.height / 2)
            case .trailing:
                origin = NSPoint(x: anchorRect.minX - size.width, y: anchorRect.midY - size.height / 2)
            }
            let x = min(max(bounds.minX, origin.x), max(bounds.minX, bounds.maxX - size.width))
            let y = min(max(bounds.minY, origin.y), max(bounds.minY, bounds.maxY - size.height))
            panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
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
