#if DEBUG
    import AppKit
    import LoffoFeatures

    /// Developer-only capture of this application's own hierarchy after model and native text agree.
    @MainActor enum SmokeCapture {
        static weak var model: WorkspaceModel?
        private static var observer: NSObjectProtocol?
        static func scheduleIfRequested() {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--preview-session") {
                observer = DistributedNotificationCenter.default().addObserver(
                    forName: Notification.Name("app.loffo.debug-preview"),
                    object: String(ProcessInfo.processInfo.processIdentifier), queue: .main
                ) { notification in
                    let command = notification.userInfo?["command"] as? String
                    let destination = notification.userInfo?["destination"] as? String
                    MainActor.assumeIsolated {
                        if let command,
                            ["filter", "type-filter", "submit-filter", "escape-filter"].contains(command)
                        {
                            performInput(command, text: destination)
                        }
                        if command == "resize", let destination,
                            let window = NSApp.windows.first(where: { $0.isVisible })
                        {
                            let parts = destination.split(separator: "x").compactMap { Double($0) }
                            if parts.count == 2, (960...1920).contains(parts[0]),
                                (540...1080).contains(parts[1])
                            {
                                window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                            }
                        }
                        if command == "flash-scrollbars",
                            let view = NSApp.windows.first(where: { $0.isVisible })?.contentView
                        {
                            for scroll in descendants(view).compactMap({ $0 as? NSScrollView }) {
                                scroll.flashScrollers()
                                print(
                                    "SCROLLER: frame=\(scroll.frame) overlay=\(scroll.scrollerStyle == .overlay) borderless=\(scroll.borderType == .noBorder)"
                                )
                            }
                        }
                        if command == "diff" { model?.setDiff(true) }
                        if command == "next-change" { model?.navigateHunk(1) }
                        if command == "scroll-right" || command == "scroll-left",
                            let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                            let text = descendants(view).compactMap({ $0 as? NSTextView }).first,
                            let scroll = text.enclosingScrollView
                        {
                            var origin = scroll.contentView.bounds.origin
                            origin.x = command == "scroll-right" ? 180 : 0
                            scroll.contentView.scroll(to: origin)
                            scroll.reflectScrolledClipView(scroll.contentView)
                        }
                        if command == "files" { model?.setDiff(false) }
                        if command == "project", let destination, destination.hasPrefix("/"), let model {
                            let selected = model.selected
                            Task {
                                await model.open(URL(fileURLWithPath: destination))
                                model.setDiff(false)
                                if let selected, model.files.contains(where: { $0.path == selected }) {
                                    model.select(selected)
                                } else if let first = model.files.first {
                                    model.select(first.path)
                                }
                            }
                        }
                        if command == "select", let destination,
                            model?.files.contains(where: { $0.path == destination }) == true
                        {
                            measureSwitch(to: destination)
                        }
                        if command == "capture", let destination,
                            let view = NSApp.windows.first(where: { $0.isVisible })?.contentView
                        {
                            view.layoutSubtreeIfNeeded()
                            capture(
                                view, to: URL(fileURLWithPath: destination),
                                textViews: descendants(view).compactMap { $0 as? NSTextView })
                        }
                    }
                }
                print("PREVIEW: pid=\(ProcessInfo.processInfo.processIdentifier)")
            }
            guard let index = arguments.firstIndex(of: "--smoke-screenshot"), arguments.count > index + 1
            else { return }
            let destination = URL(fileURLWithPath: arguments[index + 1])
            Task {
                for _ in 0..<200 {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let model, !model.isUpdating, let presentation = model.presentation,
                        let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                        let view = window.contentView
                    else { continue }
                    view.layoutSubtreeIfNeeded()
                    let textViews = descendants(view).compactMap { $0 as? NSTextView }
                    guard textViews.contains(where: { $0.string.utf8.elementsEqual(presentation.text.utf8) }),
                        model.showsDiff == arguments.contains("--diff")
                    else { continue }
                    // Allow viewport layout to settle before sampling geometry.
                    try? await Task.sleep(for: .milliseconds(300))
                    capture(view, to: destination, textViews: textViews)
                    if !arguments.contains("--preview-session") { NSApp.terminate(nil) }
                    return
                }
                print("SMOKE FAILED: model/native text did not converge; error=\(model?.error ?? "none")")
                if !arguments.contains("--preview-session") { NSApp.terminate(nil) }
            }
        }
        private static func performInput(_ command: String, text: String?) {
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView
            else { return }
            if command == "filter" {
                guard
                    let event = NSEvent.keyEvent(
                        with: .keyDown, location: .zero, modifierFlags: [.command],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: "p", charactersIgnoringModifiers: "p", isARepeat: false,
                        keyCode: 35)
                else { return }
                print("INPUT: command-p handled=\(window.performKeyEquivalent(with: event))")
            } else if command == "type-filter", let text {
                guard
                    let field = descendants(view).compactMap({ $0 as? NSTextField }).first(where: {
                        $0.isEditable
                    })
                else {
                    print("INPUT FAILED: no filter field")
                    return
                }
                window.makeFirstResponder(field)
                guard let editor = field.currentEditor() as? NSTextView else { return }
                editor.insertText(
                    text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                print("INPUT: filter=\(text)")
            } else {
                let escape = command == "escape-filter"
                let character = escape ? "\u{1b}" : "\r"
                if let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: character, charactersIgnoringModifiers: character,
                    isARepeat: false, keyCode: escape ? 53 : 36)
                {
                    window.sendEvent(event)
                }
                print("INPUT: \(command)")
            }
        }

        private static func measureSwitch(to path: String) {
            guard let model else { return }
            let start = ContinuousClock.now
            model.select(path)
            let warm = model.presentation != nil
            Task {
                for _ in 0..<400 {
                    try? await Task.sleep(for: .milliseconds(5))
                    guard model.selected == path else { return }
                    guard let presentation = model.presentation,
                        let view = NSApp.windows.first(where: { $0.isVisible })?.contentView
                    else { continue }
                    view.layoutSubtreeIfNeeded()
                    let texts = descendants(view).compactMap { $0 as? NSTextView }
                    if texts.contains(where: { $0.string.utf8.elementsEqual(presentation.text.utf8) }) {
                        print("SWITCH: path=\(path) warm=\(warm) nativeTextReady=\(start.duration(to: .now))")
                        return
                    }
                }
                print("SWITCH FAILED: \(path)")
            }
        }

        private static func capture(_ view: NSView, to destination: URL, textViews: [NSTextView]) {
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            do {
                guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
                try data.write(to: destination)
                print(
                    "SMOKE: screenshot=\(destination.path) textViews=\(textViews.count) characters=\(textViews.reduce(0) { $0 + $1.string.count }) textKit2=\(textViews.allSatisfy { $0.textLayoutManager != nil }) scrollY=\(textViews.first?.enclosingScrollView?.contentView.bounds.minY ?? -1)"
                )
            } catch { print("SMOKE FAILED: \(error)") }
        }
        private static func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
    }
#endif
