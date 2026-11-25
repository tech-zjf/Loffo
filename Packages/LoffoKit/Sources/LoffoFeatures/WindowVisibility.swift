import AppKit
import SwiftUI

struct WindowVisibility: NSViewRepresentable {
    let changed: @MainActor (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView(changed: changed) }
    func updateNSView(_ view: VisibilityView, context: Context) {}
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.disconnect() }
}

@MainActor final class VisibilityView: NSView {
    private let changed: @MainActor (Bool) -> Void
    private var observation: NSObjectProtocol?
    init(changed: @escaping @MainActor (Bool) -> Void) {
        self.changed = changed
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        disconnect()
        guard let window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        observation = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification,
            object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        Task { @MainActor [weak self] in self?.publish() }
    }
    private func publish() { changed(window?.occlusionState.contains(.visible) == true) }
    func disconnect() {
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil
    }
}
