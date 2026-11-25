import AppKit
import Foundation
import LoffoDiff
import LoffoDocument
import LoffoDomain
import LoffoEditorUI
import SwiftUI
import Testing

@testable import LoffoFeatures
@testable import LoffoInfrastructure

@Test func gitBaselineIsLiteralAndDoesNotRunFilters() async throws {
    let fixture = try GitFixture()
    let path = "file [1].ts"
    let file = fixture.folder.url.appendingPathComponent(path)
    try "const value = 1;\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "--", path])
    try fixture.run(["commit", "-m", "fixture"])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let result = try await workspace.baseline(
        in: fixture.folder.url, path: path, workingText: "const value = 2;\n")
    #expect(result.before == "const value = 1;\n")
    #expect(result.after == "const value = 2;\n")
    try "*.ts filter=fixture\n".write(
        to: fixture.folder.url.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    try fixture.run(["config", "filter.fixture.clean", "touch filter-was-run; cat"])
    try fixture.run(["config", "filter.fixture.required", "true"])
    let listing = try await workspace.files(in: fixture.folder.url)
    #expect(listing.files.contains { $0.path == path })
    await #expect(throws: WorkspaceFailure.self) {
        try await workspace.baseline(in: fixture.folder.url, path: path, workingText: "changed")
    }
    #expect(
        !FileManager.default.fileExists(
            atPath: fixture.folder.url.appendingPathComponent("filter-was-run").path))
}

@Test @MainActor func atomicWriteBurstsConvergeAcrossWindows() async throws {
    let folder = try TemporaryFolder()
    let file = folder.url.appendingPathComponent("live.ts")
    try "export const value = 0;\n".write(to: file, atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: nil)
    let hub = FileWatchHub()
    let parser = TreeSyntax()
    let diff = LineDiff()
    let first = WorkspaceModel(workspace: workspace, syntax: parser, diff: diff, observer: hub)
    let second = WorkspaceModel(workspace: workspace, syntax: parser, diff: diff, observer: hub)
    await first.open(folder.url)
    await second.open(folder.url)
    first.select("live.ts")
    second.select("live.ts")
    for _ in 0..<100 where first.presentation == nil || second.presentation == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(first.presentation != nil && second.presentation != nil)
    first.close()
    #expect(hub.subscriptionCount == 1)
    for index in 1...30 {
        try "export const value = \(index);\n".write(to: file, atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<100 where second.presentation?.text != "export const value = 30;\n" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(second.presentation?.text == "export const value = 30;\n")
    #expect(second.error == nil)
    second.close()
    #expect(hub.subscriptionCount == 0)
}

@Test func gitOutputBudgetRejectsTruncation() async throws {
    let fixture = try GitFixture()
    let runner = GitRunner(executable: fixture.git)
    await #expect(throws: WorkspaceFailure.self) {
        try await runner.run(["--version"], at: fixture.folder.url, limit: 1)
    }
}

private final class GitFixture {
    let folder: TemporaryFolder
    let git: URL
    init() throws {
        folder = try TemporaryFolder()
        let candidates = [
            ProcessInfo.processInfo.environment["LOFFO_GIT_EXECUTABLE"],
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
            "/Library/Developer/CommandLineTools/usr/bin/git", "/opt/homebrew/bin/git",
        ].compactMap { $0 }
        let path = try #require(
            candidates.first { FileManager.default.isExecutableFile(atPath: $0) },
            "An installed Git is required for integration tests")
        git = URL(fileURLWithPath: path)
        try run(["init"])
        try run(["config", "user.name", "Loffo Test"])
        try run(["config", "user.email", "test@example.invalid"])
    }
    func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = folder.url
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
    func runCapture(_ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = folder.url
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return data
    }
    func runAllowingFailure(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = folder.url
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

@Test func historicalLongLineUsesTheSameAdmissionPolicy() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("long.ts")
    try String(repeating: "a", count: 20_001).write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "long baseline"])
    try "short\n".write(to: file, atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    await #expect(throws: WorkspaceFailure.self) {
        try await workspace.baseline(in: fixture.folder.url, path: "long.ts", workingText: "short\n")
    }
}

@Test func gitListingMarksUndecodablePathsAsLimited() {
    let listing = GitPathListing.decode(Data([103, 111, 111, 100, 0, 0xFF, 0]))
    #expect(listing.files.map(\.path) == ["good"])
    #expect(listing.usesGitIgnore)
    #expect(listing.isLimited)
}

@Test func gitChangeListingMarksEveryUnmergedStageAsConflict() {
    let status = Data("M\0conflict.swift\0".utf8)
    let untracked = Data()
    let records =
        "100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 1\tconflict.swift\0"
        + "100644 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 2\tconflict.swift\0"
        + "100644 cccccccccccccccccccccccccccccccccccccccc 3\tconflict.swift\0"
    let unmerged = Data(records.utf8)
    let listing = GitPathListing.changes(tracked: status, untracked: untracked, unmerged: unmerged)
    #expect(listing.files.count == 1)
    #expect(listing.files.first?.changeKind == FileChangeKind.conflicted)
    #expect(!listing.isLimited)
    #expect(FileChangeKind.conflicted.marker == "C")
}

@Test @MainActor func unresolvedGitConflictCannotBeMarkedReviewed() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("conflict.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    let mainBranch = String(decoding: try fixture.runCapture(["branch", "--show-current"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try fixture.run(["branch", "conflict-side"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["commit", "-am", "main change"])
    try fixture.run(["checkout", "conflict-side"])
    try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["commit", "-am", "side change"])
    #expect(fixture.runAllowingFailure(["merge", mainBranch]) != 0)

    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<200 where model.changedFiles.first?.changeKind != .conflicted {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.first?.changeKind == .conflicted)
    model.select("conflict.swift")
    for _ in 0..<200 where model.isUpdating || (model.presentation == nil && model.error == nil) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.canReview)
    model.markReviewed()
    #expect(!model.reviewed)
}

@Test func comparisonPolicyIsRecheckedAfterAttributeChanges() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("file.ts")
    try "hello\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "baseline"])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    _ = try await workspace.baseline(in: fixture.folder.url, path: "file.ts", workingText: "hello\n")
    try "*.ts working-tree-encoding=UTF-16\n".write(
        to: fixture.folder.url.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    await #expect(throws: WorkspaceFailure.self) {
        try await workspace.validateComparison(in: fixture.folder.url, path: "file.ts")
    }
}

@Test @MainActor func fiveWindowsConvergeAndReleaseEverySubscription() async throws {
    let folder = try TemporaryFolder()
    let file = folder.url.appendingPathComponent("shared.ts")
    try "const n = 0;\n".write(to: file, atomically: true, encoding: .utf8)
    let hub = FileWatchHub()
    let workspace = LocalWorkspace(gitExecutable: nil)
    let budget = WorkAdmission()
    let parser = TreeSyntax(admission: budget)
    let diff = LineDiff(admission: budget)
    for _ in 0..<10 {
        var models: [WorkspaceModel] = []
        for _ in 0..<5 {
            let model = WorkspaceModel(workspace: workspace, syntax: parser, diff: diff, observer: hub)
            await model.open(folder.url)
            model.select("shared.ts")
            models.append(model)
        }
        for index in 1...10 { try "const n = \(index);\n".write(to: file, atomically: true, encoding: .utf8) }
        for _ in 0..<200 where models.contains(where: { $0.presentation?.text != "const n = 10;\n" }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(models.allSatisfy { $0.presentation?.text == "const n = 10;\n" })
        for model in models { model.close() }
        #expect(hub.subscriptionCount == 0)
        #expect(hub.repositorySubscriptionCount == 0)
    }
    for _ in 0..<100 {
        if await budget.activeJobs == 0 { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await budget.activeJobs == 0)
    #expect(await budget.admittedBytes == 0)
}

@Test func changedFilesRefuseFiltersBeforeRunningConversions() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("file.ts")
    try "old\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "baseline"])
    try "new\n".write(to: file, atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let changes = try await workspace.changes(in: fixture.folder.url)
    #expect(changes.files.map(\.path) == ["file.ts"])
    try fixture.run(["config", "filter.fixture.clean", "touch filter-ran; cat"])
    try "*.ts filter=fixture\n".write(
        to: fixture.folder.url.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
    await #expect(throws: WorkspaceFailure.self) { try await workspace.changes(in: fixture.folder.url) }
    #expect(
        !FileManager.default.fileExists(atPath: fixture.folder.url.appendingPathComponent("filter-ran").path))
}

@Test func gitChangesAndBaselineStayInsideOpenedSubdirectory() async throws {
    let fixture = try GitFixture()
    let inside = fixture.folder.url.appendingPathComponent("Sources/Core/file.swift")
    let outside = fixture.folder.url.appendingPathComponent("Docs/readme.md")
    try FileManager.default.createDirectory(
        at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "let value = 1\n".write(to: inside, atomically: true, encoding: .utf8)
    try "old\n".write(to: outside, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "baseline"])
    try "let value = 2\n".write(to: inside, atomically: true, encoding: .utf8)
    try "new\n".write(to: outside, atomically: true, encoding: .utf8)
    try "untracked\n".write(
        to: inside.deletingLastPathComponent().appendingPathComponent("new.swift"),
        atomically: true, encoding: .utf8)
    let selectedFolder = fixture.folder.url.appendingPathComponent("Sources")
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let changes = try await workspace.changes(in: selectedFolder)
    #expect(changes.files.map(\.path) == ["Core/file.swift", "Core/new.swift"])
    let baseline = try await workspace.baseline(
        in: selectedFolder, path: "Core/file.swift", workingText: "let value = 2\n")
    #expect(baseline.before == "let value = 1\n")
    #expect(try await workspace.history(in: selectedFolder, path: "Core/file.swift").count == 1)
}

@Test func runnerCancellationTerminatesAnActiveProcess() async throws {
    let folder = try TemporaryFolder()
    let executable = folder.url.appendingPathComponent("slow-git")
    // Deliberately ignore runner arguments; exec keeps a single process with no orphan children.
    try "#!/bin/sh\nexec /bin/sleep 10\n".write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runner = GitRunner(executable: executable)
    let task = Task { try await runner.run(["--version"], at: folder.url) }
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(start.duration(to: .now) < .seconds(1))
}

@Test @MainActor func switchingFilesKeepsStatusAndImmediatelyRestoresWarmPreview() async throws {
    let fixture = try GitFixture()
    let firstURL = fixture.folder.url.appendingPathComponent("README.md")
    let secondURL = fixture.folder.url.appendingPathComponent("send.ts")
    try "# Demo\n".write(to: firstURL, atomically: true, encoding: .utf8)
    try "const value = 1;\n".write(to: secondURL, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "initial"])
    try "# Demo\n\nDetails\n".write(to: firstURL, atomically: true, encoding: .utf8)
    try "const value = 2;\n".write(to: secondURL, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("README.md")
    for _ in 0..<300 where model.isUpdating || model.presentation == nil || model.changedFiles.count != 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.diff?.added == 2)
    #expect(model.changedFiles.first(where: { $0.path == "README.md" })?.changeKind == .modified)
    model.select("send.ts")
    #expect(model.error == nil)
    for _ in 0..<300 where model.isUpdating || model.presentation == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.first(where: { $0.path == "README.md" })?.changeKind == .modified)
    let host = NSHostingView(rootView: SwitchingEditor(model: model))
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
        styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderBack(nil)
    defer { window.close() }
    try await Task.sleep(for: .milliseconds(40))
    let start = ContinuousClock.now
    model.select("README.md")
    // This assertion is synchronous: a cache hit must never publish a nil/error frame.
    #expect(model.presentation?.diff?.added == 2)
    #expect(model.presentation?.text.contains("Details") == true)
    #expect(model.isUpdating)
    print("SWITCH warm model publication: \(start.duration(to: .now))")
    for _ in 0..<200 {
        host.layoutSubtreeIfNeeded()
        if nativeText(in: host)?.string == model.presentation?.text { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(nativeText(in: host)?.string == model.presentation?.text)
    print("SWITCH warm native text ready: \(start.duration(to: .now))")
    model.refreshFiles()
    try await Task.sleep(for: .milliseconds(350))
    #expect(model.changedFiles.first(where: { $0.path == "README.md" })?.changeKind == .modified)
    try "# Demo\nUpdated\n".write(to: firstURL, atomically: true, encoding: .utf8)
    model.refresh(immediate: true)
    for _ in 0..<300 where model.presentation?.text.contains("Updated") != true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text.contains("Updated") == true)
    #expect(model.changedFiles.first(where: { $0.path == "README.md" })?.changeKind == .modified)
    model.setDiff(false)
    #expect(model.presentation?.diff == nil)
    model.select("send.ts")
    for _ in 0..<300 where model.isUpdating || model.presentation == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text == "const value = 2;\n")
}

@Test func changedFileListingDistinguishesUntrackedModifiedAndDeleted() async throws {
    let fixture = try GitFixture()
    for name in ["modified.ts", "deleted.ts"] {
        try "const value = 1;\n".write(
            to: fixture.folder.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "initial"])
    try "const value = 2;\n".write(
        to: fixture.folder.url.appendingPathComponent("modified.ts"), atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: fixture.folder.url.appendingPathComponent("deleted.ts"))
    try "const value = 3;\n".write(
        to: fixture.folder.url.appendingPathComponent("untracked.ts"), atomically: true, encoding: .utf8)
    try "const value = 4;\n".write(
        to: fixture.folder.url.appendingPathComponent("added.ts"), atomically: true, encoding: .utf8)
    try fixture.run(["add", "added.ts"])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let listing = try await workspace.changes(in: fixture.folder.url)
    let kinds = Dictionary(uniqueKeysWithValues: listing.files.map { ($0.path, $0.changeKind) })
    #expect(kinds["modified.ts"] == .modified)
    #expect(kinds["deleted.ts"] == .deleted)
    #expect(kinds["untracked.ts"] == .untracked)
    #expect(kinds["added.ts"] == .added)
    #expect(!listing.isLimited)
}

@Test @MainActor func windowsShareAndReleaseImmutablePreviewCacheByWorkspaceLease() async throws {
    let folder = try TemporaryFolder()
    let text = "A shared immutable reading snapshot.\n"
    try text.write(
        to: folder.url.appendingPathComponent("shared.txt"), atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: nil)
    let syntax = TreeSyntax()
    let diff = LineDiff()
    let observer = FileWatchHub()
    let previews = PreviewCache(maximumEntries: 8, maximumBytes: 1_024)
    let first = WorkspaceModel(
        workspace: workspace, syntax: syntax, diff: diff, observer: observer, previews: previews)
    let second = WorkspaceModel(
        workspace: workspace, syntax: syntax, diff: diff, observer: observer, previews: previews)
    defer {
        first.close()
        second.close()
    }

    await first.open(folder.url)
    first.select("shared.txt")
    for _ in 0..<100 where first.isUpdating || first.presentation == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let cachedID = try #require(first.presentation?.id)
    #expect(previews.bytes > 0)

    await second.open(folder.url)
    second.select("shared.txt")
    #expect(second.presentation?.id == cachedID)
    first.close()
    #expect(
        previews.value(
            workspace: folder.url, path: "shared.txt", comparison: false, expanded: false)?.id == cachedID)
    second.close()
    #expect(previews.bytes == 0)
}

@MainActor private struct SwitchingEditor: View {
    @ObservedObject var model: WorkspaceModel
    var body: some View {
        if let presentation = model.presentation { CodeEditor(presentation: presentation) }
    }
}

@MainActor private func nativeText(in view: NSView) -> NSTextView? {
    if let text = view as? NSTextView { return text }
    for child in view.subviews {
        if let text = nativeText(in: child) { return text }
    }
    return nil
}

@Test @MainActor func explicitSelectionLoadsWhileOccludedButBackgroundEventsStayPaused() async throws {
    let folder = try TemporaryFolder()
    let url = folder.url.appendingPathComponent("hidden.ts")
    try "const initial = 1;\n".write(to: url, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: nil), syntax: TreeSyntax(),
        diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    model.setVisible(false)
    await model.open(folder.url)
    model.select("hidden.ts")
    for _ in 0..<100 where model.isUpdating || model.presentation == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text == "const initial = 1;\n")
    try "const updated = 2;\n".write(to: url, atomically: true, encoding: .utf8)
    model.refresh()
    try await Task.sleep(for: .milliseconds(100))
    #expect(model.presentation?.text == "const initial = 1;\n")
    model.setVisible(true)
    for _ in 0..<100 where model.presentation?.text != "const updated = 2;\n" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text == "const updated = 2;\n")
}

@Test @MainActor func explicitDiffRequestFinishesMetadataWhileWindowIsOccluded() async throws {
    let fixture = try GitFixture()
    for name in ["first.ts", "second.ts"] {
        try "const before = 1;\n".write(
            to: fixture.folder.url.appendingPathComponent(name),
            atomically: true, encoding: .utf8)
    }
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "initial"])
    for name in ["first.ts", "second.ts"] {
        try "const after = 2;\n".write(
            to: fixture.folder.url.appendingPathComponent(name),
            atomically: true, encoding: .utf8)
    }
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(),
        diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    model.setVisible(false)
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("first.ts")
    for _ in 0..<200 where model.changedFiles.count != 2 || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.count == 2)
    #expect(model.changedFiles.allSatisfy { $0.changeKind == .modified })
    // A delayed filesystem signal while hidden deliberately disables review until revalidation.
    model.setVisible(true)
    for _ in 0..<200 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    let ready = model.canReview
    #expect(ready)
}

@Test func fileHistoryPreservesRealCommitTimeAndEmptySubjects() async throws {
    let fixture = try GitFixture()
    let started = Date().addingTimeInterval(-1)
    let file = fixture.folder.url.appendingPathComponent("history.ts")
    try "one\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "消息 — original"])
    try "two\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "--allow-empty-message", "-m", ""])
    try "unrelated\n".write(
        to: fixture.folder.url.appendingPathComponent("other.ts"),
        atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "unrelated file"])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let commits = try await workspace.history(in: fixture.folder.url, path: "history.ts")
    #expect(commits.count == 2)
    #expect(commits.first?.subject == "")
    #expect(commits.last?.subject == "消息 — original")
    #expect(Set(commits.map(\.id)).count == 2)
    for commit in commits {
        let date = try #require(commit.committedAt)
        #expect(date >= started && date <= Date())
    }
    #expect(try await workspace.history(in: fixture.folder.url, path: "not-present.ts").isEmpty)
}
