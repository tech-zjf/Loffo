import AppKit
import LoffoDiff
import LoffoDocument
import LoffoDomain
import LoffoFeatures
import LoffoInfrastructure
import SwiftUI

@main struct LoffoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    private let services = Services()
    var body: some Scene {
        WindowGroup(id: "workspace") {
            WindowRoot(services: services)
        }.defaultSize(width: 1280, height: 720)
            .windowStyle(.hiddenTitleBar)
            .commands { WorkspaceCommands() }

    }
}

@MainActor private final class Services {
    let workspace: LocalWorkspace
    let syntax: SyntaxPool
    let diff: LineDiff
    let watcher = FileWatchHub()
    let readAdmission = WorkAdmission(maximumJobs: 4, maximumBytes: 4)
    let baselineAdmission = WorkAdmission(maximumJobs: 8, maximumBytes: 64 * 1_024 * 1_024)
    let processingAdmission: WorkAdmission
    let previews = PreviewCache(maximumEntries: 32, maximumBytes: 32 * 1_024 * 1_024)
    private var memoryPressure: (any DispatchSourceMemoryPressure)?
    var benchmarkWindowsOpened = false
    init() {
        let admission = WorkAdmission()
        processingAdmission = admission
        syntax = SyntaxPool(admission: admission)
        diff = LineDiff(admission: admission)
        // Use an installed executable directly; never invoke the CLT installer shim.
        let supplied = ProcessInfo.processInfo.environment["LOFFO_GIT_EXECUTABLE"]
        let candidates =
            supplied.map { [$0] } ?? [
                "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
                "/Library/Developer/CommandLineTools/usr/bin/git",
                "/opt/homebrew/bin/git", "/usr/local/bin/git",
            ]
        let path = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        workspace = LocalWorkspace(gitExecutable: path.map { URL(fileURLWithPath: $0) })
        let pressure = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in await self?.discardReconstructibleCaches() }
        }
        memoryPressure = pressure
        pressure.resume()
    }

    fileprivate func discardReconstructibleCaches() async {
        previews.removeAll()
        async let snapshots: Void = workspace.discardCachedSnapshots()
        async let tree: Void = syntax.discardCachedTrees()
        _ = await (snapshots, tree)
    }

    #if DEBUG
        fileprivate func cacheDiagnostics() async -> [String: Int] {
            let snapshotBytes = await workspace.diagnosticCachedBytes
            let treeCount = await syntax.diagnosticCachedTreeCount
            return [
                "previewBytes": previews.bytes, "snapshotBytes": snapshotBytes, "syntaxTree": treeCount,
            ]
        }
    #endif
}

private struct WindowRoot: View {
    @Environment(\.openWindow) private var openWindow
    private let services: Services
    @StateObject private var model: WorkspaceModel
    init(services: Services) {
        self.services = services
        _model = StateObject(
            wrappedValue: WorkspaceModel(
                workspace: services.workspace, syntax: services.syntax, diff: services.diff,
                observer: services.watcher, previews: services.previews,
                appReadAdmission: services.readAdmission, baselineAdmission: services.baselineAdmission,
                processingAdmission: services.processingAdmission))
    }
    var body: some View {
        WorkspaceView(model: model).background {
            if BenchmarkProbe.enabled { BenchmarkWindowBinding(model: model) }
        }.task {
            let args = ProcessInfo.processInfo.arguments
            if !services.benchmarkWindowsOpened, let count = BenchmarkProbe.requestedWindowCount {
                services.benchmarkWindowsOpened = true
                for _ in 1..<count { openWindow(id: "workspace") }
            }

            let benchmarkProject = BenchmarkProbe.register(model)
            #if DEBUG
                SmokeCapture.model = model
                SmokeCapture.simulateMemoryPressure = { [weak services] in
                    guard let services else { return [:] }
                    let before = await services.cacheDiagnostics()
                    await services.discardReconstructibleCaches()
                    let after = await services.cacheDiagnostics()
                    return ["before": before, "after": after]
                }
                if args.contains("--smoke-screenshot") { print("SMOKE args: \(args)") }
            #endif
            let suppliedProject = args.firstIndex(of: "--project").flatMap { index in
                args.count > index + 1 ? URL(fileURLWithPath: args[index + 1]) : nil
            }
            if let project = benchmarkProject ?? suppliedProject {
                await model.open(project)
                if let fileIndex = args.firstIndex(of: "--file"), args.count > fileIndex + 1 {
                    if args.contains("--diff") { model.setDiff(true) }
                    model.select(args[fileIndex + 1])
                    #if DEBUG
                        if args.contains("--smoke-screenshot") { print("SMOKE mode: \(model.showsDiff)") }
                    #endif
                }
            }
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldRestoreApplicationState(_ app: NSApplication) -> Bool {
        !ProcessInfo.processInfo.arguments.contains("--benchmark-report")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
            SmokeCapture.scheduleIfRequested()
        #endif
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
