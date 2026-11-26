import AppKit
import LoffoFeatures
import SwiftUI

/// Opt-in measurement metadata only. No source text is written to the report.
/// Native text agreement is not a claim that a compositor frame has been presented.
@MainActor enum BenchmarkProbe {
    private final class Entry {
        weak var model: WorkspaceModel?
        weak var window: NSWindow?
        let project: URL?
        init(_ model: WorkspaceModel, project: URL?) {
            self.model = model
            self.project = project
        }
    }
    private static let arguments = ProcessInfo.processInfo.arguments
    static var enabled: Bool { destination != nil }
    private static let destination: URL? = {
        guard let index = arguments.firstIndex(of: "--benchmark-report"), arguments.count > index + 1,
            arguments[index + 1].hasPrefix("/")
        else { return nil }
        return URL(fileURLWithPath: arguments[index + 1])
    }()
    private static let projects: [URL] = {
        let indices = arguments.indices.filter { arguments[$0] == "--benchmark-project" }
        guard !indices.isEmpty else { return [] }
        guard indices.count <= 5,
            indices.allSatisfy({
                arguments.count > $0 + 1 && arguments[$0 + 1].hasPrefix("/")
            })
        else {
            print("BENCHMARK CONFIGURATION ERROR: use 1–5 absolute --benchmark-project paths")
            return []
        }
        return indices.map { URL(fileURLWithPath: arguments[$0 + 1]).standardizedFileURL }
    }()
    static var requestedWindowCount: Int? {
        guard enabled else { return nil }
        if !projects.isEmpty { return projects.count }
        guard let index = arguments.firstIndex(of: "--benchmark-windows"), arguments.count > index + 1,
            let count = Int(arguments[index + 1]), (1...5).contains(count)
        else { return nil }
        return count
    }
    private static var entries: [Entry] = []
    private static var scheduled = false
    private static var arrangement = "not requested"

    @discardableResult static func register(_ model: WorkspaceModel) -> URL? {
        guard let destination else { return nil }
        if let entry = entries.first(where: { $0.model === model }) { return entry.project }
        let project = entries.count < projects.count ? projects[entries.count] : nil
        entries.append(Entry(model, project: project))
        if !scheduled {
            scheduled = true
            Task {
                if arguments.contains("--benchmark-arrange") {
                    for _ in 0..<20 {
                        if entries.compactMap(\.window).count >= (requestedWindowCount ?? 1) { break }
                        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    }
                    arrangeWindows()
                }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                record(to: destination)
            }
        }
        return project
    }

    static func attach(_ model: WorkspaceModel, to window: NSWindow?) {
        register(model)
        entries.first(where: { $0.model === model })?.window = window
    }

    private static func arrangeWindows() {
        if !projects.isEmpty {
            let unrelated = entries.filter { $0.project == nil }
            for entry in unrelated { entry.window?.close() }
            entries.removeAll { $0.project == nil }
        }
        let windows = entries.compactMap(\.window)
        guard let screen = NSScreen.screens.max(by: { $0.visibleFrame.width < $1.visibleFrame.width }),
            !windows.isEmpty
        else {
            arrangement = "no windows or screens available"
            return
        }
        let area = screen.visibleFrame
        guard let frames = Self.tileFrames(for: windows.count, in: area) else {
            arrangement = "invalid: largest screen cannot fit all requested windows at minimum size"
            return
        }
        for (window, frame) in zip(windows, frames) {
            window.setFrame(frame, display: true)
            window.orderFront(nil)
        }
        windows.last?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        arrangement = "tiled on largest screen; report validates bounds and overlap"
    }

    private static func tileFrames(for count: Int, in area: NSRect) -> [NSRect]? {
        guard count > 0 else { return nil }
        let minimum = NSSize(width: 960, height: 540)
        let maximum = NSSize(width: 1280, height: 720)
        let columns = (1...count).compactMap { columnCount -> (Int, Int, CGFloat)? in
            let rowCount = (count + columnCount - 1) / columnCount
            let cellWidth = area.width / CGFloat(columnCount)
            let cellHeight = area.height / CGFloat(rowCount)
            guard cellWidth >= minimum.width, cellHeight >= minimum.height else { return nil }
            return (columnCount, rowCount, min(cellWidth, maximum.width) * min(cellHeight, maximum.height))
        }
        guard let (columnCount, rowCount, _) = columns.max(by: { $0.2 < $1.2 }) else { return nil }

        let cellWidth = area.width / CGFloat(columnCount)
        let cellHeight = area.height / CGFloat(rowCount)
        let windowWidth = min(cellWidth, maximum.width)
        let windowHeight = min(cellHeight, maximum.height)
        return (0..<count).map { index in
            let column = index % columnCount
            let row = index / columnCount
            let cellMinX = area.minX + CGFloat(column) * cellWidth
            let cellMaxY = area.maxY - CGFloat(row) * cellHeight
            return NSRect(
                x: cellMinX + (cellWidth - windowWidth) / 2,
                y: cellMaxY - cellHeight + (cellHeight - windowHeight) / 2,
                width: windowWidth, height: windowHeight)
        }
    }

    #if DEBUG
        static func captureNow(to destination: URL) {
            guard enabled else { return }
            record(
                to: destination,
                note: "On-demand observation; native readiness is not frame-presented evidence.")
        }

        static func nativeTextMatches(_ model: WorkspaceModel) -> Bool? {
            guard enabled, let view = entries.first(where: { $0.model === model })?.window?.contentView else {
                return nil
            }
            guard let text = model.presentation?.text else { return false }
            return descendants(view).compactMap { $0 as? NSTextView }.contains { $0.string == text }
        }
    #endif

    private static func record(
        to destination: URL,
        note: String =
            "One observation after a 30-second settling period; native readiness is not frame-presented evidence. Overlap sums are diagnostic, not OS-wide visible-area measurements."
    ) {
        let live = entries.filter { $0.model != nil }
        let windows = live.compactMap(\.window).filter { $0.isVisible && $0.contentView != nil }
        let reports: [[String: Any]] = live.compactMap { entry in
            guard let model = entry.model else { return nil }
            let textViews = entry.window?.contentView.map(descendants)?.compactMap { $0 as? NSTextView } ?? []
            let matches =
                model.presentation.map { presentation in
                    textViews.filter { $0.string.utf8.elementsEqual(presentation.text.utf8) }
                } ?? []
            let editor = matches.first
            let viewportHeight = editor?.enclosingScrollView?.contentView.bounds.height ?? 0
            return [
                "project": model.root?.path ?? "", "listedFiles": model.files.count,
                "selected": model.selected ?? "", "mode": model.showsDiff ? "unified" : "reading",
                "updating": model.isUpdating, "error": model.error ?? "",
                "bytes": model.presentation?.text.utf8.count ?? 0,
                "syntaxSpans": model.presentation?.syntax.count ?? 0,
                "coarse": model.presentation?.diff?.isCoarse ?? false,
                "windowNumber": entry.window?.windowNumber ?? -1,
                "nativeTextMatches": matches.count,
                "textKit2": !matches.isEmpty && matches.allSatisfy { $0.textLayoutManager != nil },
                "textViewHeight": editor?.frame.height ?? 0,
                "viewportHeight": viewportHeight,
                "documentViewportHeightRatio": viewportHeight > 0
                    ? (editor?.frame.height ?? 0) / viewportHeight : 0,
                "verticallyResizable": editor?.isVerticallyResizable ?? false,
            ]
        }
        let windowReports: [[String: Any]] = windows.map { window in
            let overlap = windows.filter { $0 !== window }.reduce(CGFloat.zero) {
                let intersection = window.frame.intersection($1.frame)
                return $0 + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
            return [
                "number": window.windowNumber, "frame": rectangle(window.frame),
                "contentBounds": rectangle(window.contentView?.bounds ?? .zero),
                "unoccluded": window.occlusionState.contains(.visible),
                "overlapWithOtherBenchmarkWindows": overlap,
                "screenScale": window.backingScaleFactor,
            ]
        }
        let payload: [String: Any] = [
            "pid": ProcessInfo.processInfo.processIdentifier, "timestamp": Date().ISO8601Format(),
            "appActive": NSApp.isActive, "windowCount": windows.count,
            "unoccludedWindows": windows.filter { $0.occlusionState.contains(.visible) }.count,
            "distinctProjects": Set(reports.compactMap { $0["project"] as? String }).count,
            "windows": windowReports, "models": reports, "arrangement": arrangement,
            "screens": NSScreen.screens.map {
                [
                    "frame": rectangle($0.frame),
                    "visibleFrame": rectangle($0.visibleFrame), "scale": $0.backingScaleFactor,
                    "maximumFramesPerSecond": $0.maximumFramesPerSecond,
                ] as [String: Any]
            },
            "note": note,
        ]
        do {
            let data = try JSONSerialization.data(
                withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: destination, options: .atomic)
            print("BENCHMARK: \(destination.path)")
        } catch { print("BENCHMARK FAILED: \(error.localizedDescription)") }
    }

    private static func rectangle(_ rect: NSRect) -> [CGFloat] {
        [rect.minX, rect.minY, rect.width, rect.height]
    }
    private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }
}

struct BenchmarkWindowBinding: NSViewRepresentable {
    let model: WorkspaceModel
    func makeNSView(context: Context) -> BenchmarkWindowView { BenchmarkWindowView(model: model) }
    func updateNSView(_ view: BenchmarkWindowView, context: Context) {}
}

@MainActor final class BenchmarkWindowView: NSView {
    private weak var model: WorkspaceModel?
    init(model: WorkspaceModel) {
        self.model = model
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let model { BenchmarkProbe.attach(model, to: window) }
    }
}
