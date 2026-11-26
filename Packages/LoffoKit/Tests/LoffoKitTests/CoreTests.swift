import Foundation
import LoffoDiff
import LoffoDomain
import LoffoEditorUI
import LoffoFeatures
import LoffoInfrastructure
import Testing
import os

@testable import LoffoDocument

@Test func publicationOrdering() {
    var gate = PublicationGate()
    let intent = gate.intent
    let accepted1 = gate.accept(.init(intent: intent, contentVersion: 2))
    #expect(accepted1)
    let accepted2 = gate.accept(.init(intent: intent, contentVersion: 2, refinement: 1))
    #expect(accepted2)
    let accepted3 = !gate.accept(.init(intent: intent, contentVersion: 1, refinement: 99))
    #expect(accepted3)
    let accepted4 = !gate.accept(.init(intent: intent, contentVersion: 2))
    #expect(accepted4)
    let accepted5 = gate.accept(.init(intent: intent, contentVersion: 3))
    #expect(accepted5)
    gate.reset()
    let accepted6 = !gate.accept(.init(intent: intent, contentVersion: 100))
    #expect(accepted6)
}

@Test func diffPreservesBothInputs() async throws {
    let inputs = [
        "", "a", "a\n", "a\r\nb\r\n", "a\nb", "😃 中文\n\nend", "a\na\nb\n", "b\na\na\n", "\r", "\u{2028}x",
    ]
    for before in inputs {
        for after in inputs {
            for budget in [1, 400_000] {
                let result = try await LineDiff(cellBudget: budget).compare(before: before, after: after)
                #expect(
                    Array(result.lines.filter { $0.kind != .added }.map(\.text).joined().utf8)
                        == Array(before.utf8))
                #expect(
                    Array(result.lines.filter { $0.kind != .removed }.map(\.text).joined().utf8)
                        == Array(after.utf8))
                #expect(result.lines.compactMap(\.oldNumber) == Array(1..<(LineDiff.lines(before).count + 1)))
                #expect(result.lines.compactMap(\.newNumber) == Array(1..<(LineDiff.lines(after).count + 1)))
            }
        }
    }
}

@Test func myersRepeatedLinesMatchReferenceAndReconstructBytes() async throws {
    var seed: UInt64 = 0x1289_8342
    func random(_ upperBound: Int) -> Int {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1
        return Int((seed >> 32) % UInt64(upperBound))
    }
    let choices = ["a\n", "b\n", "é\n", "e\u{301}\n", "\n", "中文\n"]
    func text() -> String {
        let count = random(18)
        var value = (0..<count).map { _ in choices[random(choices.count)] }.joined()
        if !value.isEmpty && random(2) == 0 { value.removeLast() }
        return value
    }
    func distance(_ left: [String], _ right: [String]) -> Int {
        var previous = Array(0...right.count)
        for (index, old) in left.enumerated() {
            var current = [index + 1] + Array(repeating: 0, count: right.count)
            for (column, new) in right.enumerated() {
                current[column + 1] =
                    old.utf8.elementsEqual(new.utf8)
                    ? previous[column] : min(previous[column + 1], current[column]) + 1
            }
            previous = current
        }
        return previous[right.count]
    }
    let diff = LineDiff(cellBudget: 1, myersDistanceBudget: 64)
    for iteration in 0..<500 {
        let before = text()
        let after = text()
        let result = try await diff.compare(before: before, after: after)
        #expect(!result.isCoarse, "Case \(iteration) should remain exact")
        let reconstructedBefore = result.lines.filter { $0.kind != .added }.map(\.text).joined()
        let reconstructedAfter = result.lines.filter { $0.kind != .removed }.map(\.text).joined()
        #expect(reconstructedBefore.utf8.elementsEqual(before.utf8))
        #expect(reconstructedAfter.utf8.elementsEqual(after.utf8))
        #expect(result.added + result.removed == distance(LineDiff.lines(before), LineDiff.lines(after)))
    }
}

@Test func largeRewriteIsBounded() async throws {
    let old = (0..<2000).map { "old \($0)\n" }.joined()
    let new = (0..<2000).map { "new \($0)\n" }.joined()
    let result = try await LineDiff().compare(before: old, after: new)
    #expect(result.isCoarse)
    #expect(result.added == 2000 && result.removed == 2000)
}

@Test func largeSparseEditsUseExactBoundedDiff() async throws {
    var lines = (0..<20_000).map { "line \($0)\n" }
    let before = lines.joined()
    lines[4_000] = "changed one\n"
    lines[15_000] = "changed two\n"
    let result = try await LineDiff().compare(before: before, after: lines.joined())
    #expect(!result.isCoarse)
    #expect(result.added == 2 && result.removed == 2)
    #expect(result.lines.filter { $0.kind == .context }.count == 19_998)
}

@Test func standardLargeFileRetainsSyntaxAtTheEnd() async throws {
    let text = (0..<20_000).map { "export const item\($0): string = \"fixture\";\n" }.joined()
    let snapshot = TextSnapshot(url: URL(fileURLWithPath: "/sample.ts"), version: 1, text: text)
    let highlights = await TreeSyntax().highlightsWithStatus(for: snapshot)
    #expect(!highlights.isLimited)
    #expect(highlights.spans.count > 30_000)
    let lastLine = (text as NSString).range(of: "export const item19999", options: .backwards)
    #expect(highlights.spans.contains { NSIntersectionRange($0.range, lastLine).length > 0 })
}

@Test func transientBaselineHighlightDoesNotRemainInParserCache() async throws {
    let url = URL(fileURLWithPath: "/sample.ts")
    let working = TextSnapshot(url: url, version: 1, text: "const current = 1;\n")
    let baseline = TextSnapshot(url: url, version: 2, text: "const previous = 2;\n")
    let parser = TreeSyntax()
    let initial = await parser.highlightsWithStatus(for: working)
    #expect(!initial.isLimited && !initial.spans.isEmpty)
    #expect(await parser.retainedSnapshot == working)
    let temporary = await parser.transientHighlightsWithStatus(for: baseline)
    let reference = await TreeSyntax().highlightsWithStatus(for: baseline)
    #expect(!temporary.isLimited)
    #expect(temporary.spans.map(\.range) == reference.spans.map(\.range))
    #expect(temporary.spans.map(\.kind) == reference.spans.map(\.kind))
    #expect(await parser.retainedSnapshot == nil)
    let resumed = await parser.highlightsWithStatus(for: working)
    #expect(resumed.spans.map(\.range) == initial.spans.map(\.range))
    #expect(resumed.spans.map(\.kind) == initial.spans.map(\.kind))
    #expect(await parser.retainedSnapshot == working)
    let oversized = TextSnapshot(url: url, version: 3, text: String(repeating: "x", count: 5 * 1_024 * 1_024))
    let rejected = await parser.transientHighlightsWithStatus(for: oversized)
    #expect(rejected.isLimited)
    #expect(await parser.retainedSnapshot == nil)

    let budget = WorkAdmission(maximumJobs: 1)
    let waitingParser = TreeSyntax(admission: budget)
    _ = await waitingParser.highlightsWithStatus(for: working)
    try await budget.acquire(bytes: 1)
    let waiting = Task { await waitingParser.transientHighlightsWithStatus(for: baseline) }
    waiting.cancel()
    #expect(await waiting.value.isLimited)
    #expect(await waitingParser.retainedSnapshot == nil)
    await budget.release(bytes: 1)
}

@Test func typescriptHighlightsDirectCallsAndConstructors() async {
    let text = "const c = new EmailClient();\nconst html = renderTemplate(input);\nclient.send(html);\n"
    let snapshot = TextSnapshot(url: URL(fileURLWithPath: "/sample.ts"), version: 1, text: text)
    let highlights = await TreeSyntax().highlightsWithStatus(for: snapshot)
    let source = text as NSString
    #expect(!highlights.isLimited)
    #expect(
        highlights.spans.contains {
            $0.kind == .constructor && $0.range == source.range(of: "EmailClient")
        })
    #expect(
        highlights.spans.contains {
            $0.kind == .functionCall && $0.range == source.range(of: "renderTemplate")
        })
    #expect(
        !highlights.spans.contains {
            $0.kind == .functionCall && $0.range == source.range(of: "send")
        })
}

@Test func syntaxBudgetReportsIncompleteInsteadOfSilentlyTruncating() async throws {
    let line = "let a=true; let b=false; let c=true;\n"
    let text = String(repeating: line, count: 25_000)
    let snapshot = TextSnapshot(url: URL(fileURLWithPath: "/dense.ts"), version: 1, text: text)
    let highlights = await TreeSyntax().highlightsWithStatus(for: snapshot)
    #expect(highlights.isLimited)
    #expect(highlights.spans.count <= 120_000)
}

@Test func typescriptHighlightsParameterDeclarationsWithoutColoringReferences() async {
    let text =
        "function run(input: Value, optional?: string, fallback = input) { return input }\n"
        + "const f = item => item\n"
    let source = text as NSString
    let snapshot = TextSnapshot(url: URL(fileURLWithPath: "/sample.ts"), version: 1, text: text)
    let spans = await TreeSyntax().highlightsWithStatus(for: snapshot).spans
    for name in ["input", "optional", "fallback", "item"] {
        #expect(spans.contains { $0.kind == .parameter && $0.range == source.range(of: name) })
    }
    let inputReference = source.range(of: "input", options: .backwards)
    let itemReference = source.range(of: "item", options: .backwards)
    #expect(!spans.contains { $0.kind == .parameter && $0.range == inputReference })
    #expect(!spans.contains { $0.kind == .parameter && $0.range == itemReference })
}

@Test func typescriptDestructuredParameterBindingsExcludeReferencesAndPropertyKeys() async {
    let text = """
        function run({name, key: alias = fallback, nested: {count}, [lookup]: computed, ...rest},
                     [first, second = fallback]) { return name + alias + first }
        const {local} = object
        """
    let source = text as NSString
    for ext in ["ts", "tsx", "js", "jsx"] {
        let snapshot = TextSnapshot(url: URL(fileURLWithPath: "/sample.\(ext)"), version: 1, text: text)
        let spans = await TreeSyntax().highlightsWithStatus(for: snapshot).spans
        for name in ["name", "alias", "count", "computed", "rest", "first", "second"] {
            #expect(
                spans.contains { $0.kind == .parameter && $0.range == source.range(of: name) },
                "\(ext): \(name)")
        }
        for name in ["key", "nested", "fallback", "lookup", "local"] {
            #expect(
                !spans.contains { $0.kind == .parameter && $0.range == source.range(of: name) },
                "\(ext): \(name)")
        }
        for name in ["name", "alias", "first"] {
            #expect(
                !spans.contains {
                    $0.kind == .parameter && $0.range == source.range(of: name, options: .backwards)
                })
        }
    }
}

@Test func cancelledSyntaxWaitingForBudgetAllowsAnotherFile() async throws {
    let admission = WorkAdmission(maximumJobs: 1)
    let syntax = TreeSyntax(admission: admission)
    try await admission.acquire(bytes: 64 * 1_024 * 1_024)
    let text = String(repeating: "return ", count: 280_000)
    let snapshot = TextSnapshot(url: URL(fileURLWithPath: "/large.py"), version: 1, text: text)
    let task = Task.detached { await syntax.highlightsWithStatus(for: snapshot) }
    task.cancel()
    let result = await task.value
    #expect(result.isLimited)
    #expect(result.spans.isEmpty)
    await admission.release(bytes: 64 * 1_024 * 1_024)
    #expect(await admission.activeJobs == 0)
    #expect(await admission.admittedBytes == 0)
    let next = TextSnapshot(url: URL(fileURLWithPath: "/next.py"), version: 2, text: "return True\n")
    let nextResult = await syntax.highlightsWithStatus(for: next)
    #expect(!nextResult.isLimited)
    #expect(!nextResult.spans.isEmpty)
}

@Test func cancelledPythonSyntaxStopsDuringEnumeration() async {
    let text = String(repeating: "return ", count: 280_000)
    let task = Task.detached {
        var callbacks = 0
        return TreeSyntax.pythonSpans(in: text) {
            callbacks += 1
            if callbacks == 64 { withUnsafeCurrentTask { $0?.cancel() } }
            return Task.isCancelled
        }
    }
    let result = await task.value
    #expect(result.isLimited)
    #expect(result.spans.count < 64)
}

@Test func cancelledTreeSitterParseAllowsAnotherFile() async throws {
    let admission = WorkAdmission(maximumJobs: 1)
    let syntax = TreeSyntax(admission: admission)
    let text = String(repeating: "export const value: string = 'example';\n", count: 45_000)
    let snapshot = TextSnapshot(url: URL(fileURLWithPath: "/large.ts"), version: 1, text: text)
    let task = Task.detached { await syntax.highlightsWithStatus(for: snapshot) }
    var observedRunning = false
    for _ in 0..<1_000 {
        if await admission.activeJobs == 1 {
            observedRunning = true
            break
        }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(observedRunning)
    try await Task.sleep(for: .milliseconds(10))
    task.cancel()
    let result = await task.value
    #expect(result.isLimited)
    #expect(await admission.activeJobs == 0)
    #expect(await admission.admittedBytes == 0)
    let next = TextSnapshot(url: URL(fileURLWithPath: "/next.ts"), version: 2, text: "const x = 1;\n")
    let nextResult = await syntax.highlightsWithStatus(for: next)
    #expect(!nextResult.isLimited)
    #expect(!nextResult.spans.isEmpty)
}

@Test func standardHundredSparseEditsStayPreciseWithinBoundedDistance() async throws {
    var lines = (0..<20_000).map { "line \($0)\n" }
    let before = lines.joined()
    for index in 0..<100 {
        let line = index * 199 + 5
        lines[line] = lines[line].replacingOccurrences(of: "line", with: "updated")
    }
    let after = lines.joined()
    let result = try await LineDiff().compare(before: before, after: after)
    #expect(!result.isCoarse)
    #expect(result.added == 100 && result.removed == 100)
    #expect(
        result.lines.filter { $0.kind != .added }.map(\.text).joined() == before,
        "The old side must reconstruct byte for byte")
    #expect(
        result.lines.filter { $0.kind != .removed }.map(\.text).joined() == after,
        "The new side must reconstruct byte for byte")
}

@Test func boundedDiffPreservesBothSidesAtEditDistanceLimit() async throws {
    let original = (0..<3_000).map { "line \($0)\n" }
    let before = original.joined()
    let diff = LineDiff()
    for edits in [128, 129] {
        var changed = original
        for index in 0..<edits { changed[index * 20 + 5] = "changed \(index)\n" }
        let after = changed.joined()
        let result = try await diff.compare(before: before, after: after)
        #expect(result.isCoarse == (edits == 129))
        if edits == 128 { #expect(result.added == edits && result.removed == edits) }
        #expect(result.lines.filter { $0.kind != .added }.map(\.text).joined() == before)
        #expect(result.lines.filter { $0.kind != .removed }.map(\.text).joined() == after)
    }
}

@Test func documentVersionsAndValidation() async throws {
    let folder = try TemporaryFolder()
    let url = folder.url.appendingPathComponent("file.ts")
    let store = DocumentStore(io: BoundedIO())
    try "const text = '😃';\n".write(to: url, atomically: true, encoding: .utf8)
    async let first = store.read(url)
    async let second = store.read(url)
    let (a, b) = try await (first, second)
    #expect(a.version == b.version)
    try "const text = '😄';\n".write(to: url, atomically: true, encoding: .utf8)
    let c = try await store.read(url)
    #expect(c.version > a.version)
    try Data([0, 1]).write(to: url)
    await #expect(throws: WorkspaceFailure.self) { try await store.read(url) }
    try Data([0xFF]).write(to: url)
    await #expect(throws: WorkspaceFailure.self) { try await store.read(url) }
    try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: url)
    await #expect(throws: WorkspaceFailure.self) { try await store.read(url) }
    try "".write(to: url, atomically: true, encoding: .utf8)
    let empty = try await store.read(url)
    #expect(empty.text.isEmpty)
}

@Test func incrementalSyntaxMatchesFreshParsing() async throws {
    let parser = TreeSyntax()
    let url = URL(fileURLWithPath: "/fixture/example.ts")
    let versions = [
        "const a = '😃';\n", "const a = '😄';\n", "// 中文\nconst a: string = 'é';\n", "",
        "export const a = 42;\n",
    ]
    for (index, text) in versions.enumerated() {
        let snapshot = TextSnapshot(url: url, version: UInt64(index), text: text)
        let incremental = await parser.highlights(for: snapshot)
        let fresh = await TreeSyntax().highlights(for: snapshot)
        #expect(incremental.map(\.range) == fresh.map(\.range))
        #expect(incremental.map { String(describing: $0.kind) } == fresh.map { String(describing: $0.kind) })
        #expect(incremental.allSatisfy { NSMaxRange($0.range) <= text.utf16.count })
    }
}

@Test func standardSizeTypeScriptKeepsBoundedSyntaxHighlights() async throws {
    let text = (0..<20_000).map {
        "export const item\($0): string = \"fixture \($0)\";\n"
    }.joined()
    let url = URL(fileURLWithPath: "/fixture/standard.ts")
    let spans = await TreeSyntax().highlights(for: TextSnapshot(url: url, version: 1, text: text))
    #expect(!spans.isEmpty)
    #expect(spans.count <= 120_000)
    #expect(spans.allSatisfy { NSMaxRange($0.range) <= text.utf16.count })
}

@Test func folderBrowsingWithoutGit() async throws {
    let folder = try TemporaryFolder()
    try "hello".write(to: folder.url.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8)
    let hidden = folder.url.appendingPathComponent("node_modules")
    try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
    try "ignored".write(to: hidden.appendingPathComponent("large.ts"), atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: nil)
    let result = try await workspace.files(in: folder.url)
    #expect(result.files.map(\.path) == ["readme.md"])
    #expect(!result.usesGitIgnore)
    await #expect(throws: WorkspaceFailure.self) {
        try await workspace.baseline(in: folder.url, path: "readme.md", workingText: "hello")
    }
}

@Test @MainActor func watcherLeasesSurviveOtherWindowClosing() async throws {
    let folder = try TemporaryFolder()
    let file = folder.url.appendingPathComponent("watched.ts")
    try "old".write(to: file, atomically: true, encoding: .utf8)
    let hub = FileWatchHub()
    var received = 0
    let first = hub.observe(file) {}
    let second = hub.observe(file) { received += 1 }
    #expect(hub.subscriptionCount == 2)
    first.cancel()
    first.cancel()
    #expect(hub.subscriptionCount == 1)
    try "new".write(to: file, atomically: true, encoding: .utf8)
    for _ in 0..<100 where received == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(received > 0)
    second.cancel()
    #expect(hub.subscriptionCount == 0)
}

@Test @MainActor func changingSelectionRejectsOldAsyncRead() async throws {
    let workspace = DelayedWorkspace()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    await model.open(URL(fileURLWithPath: "/nonexistent"))
    model.select("old.ts")
    try await Task.sleep(for: .milliseconds(70))
    model.select("new.ts")
    for _ in 0..<100 where model.presentation?.text != "new.ts" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text == "new.ts")
    model.close()
}

private actor DelayedWorkspace: WorkspaceReading {
    func files(in root: URL) -> FileListing { .init(files: [], isLimited: false, usesGitIgnore: false) }
    func read(_ url: URL) async throws -> TextSnapshot {
        if url.lastPathComponent == "old.ts" { try await Task.sleep(for: .milliseconds(150)) }
        return .init(url: url, version: 1, text: url.lastPathComponent)
    }
    func baseline(in root: URL, path: String, workingText: String) -> ComparisonInput {
        .init(before: "", after: workingText, label: "test")
    }
}

private actor CancellableReadWorkspace: WorkspaceReading {
    private(set) var started = false
    private(set) var cancelled = false
    func files(in root: URL) -> FileListing {
        FileListing(files: [], isLimited: false, usesGitIgnore: false)
    }
    func read(_ url: URL) async throws -> TextSnapshot {
        if url.lastPathComponent == "old.ts" {
            started = true
            do { try await Task.sleep(for: .seconds(10)) } catch {
                cancelled = true
                throw error
            }
        }
        return TextSnapshot(url: url, version: 1, text: url.lastPathComponent)
    }
    func baseline(in root: URL, path: String, workingText: String) -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD")
    }
}

@Test @MainActor func switchingFilesCancelsObsoleteCooperativeRead() async throws {
    let folder = try TemporaryFolder()
    let workspace = CancellableReadWorkspace()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(folder.url)
    model.select("old.ts")
    for _ in 0..<400 where !(await workspace.started) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.started)
    model.select("new.ts")
    for _ in 0..<400 where model.presentation?.text != "new.ts" {
        try await Task.sleep(for: .milliseconds(10))
    }
    for _ in 0..<1_000 where !(await workspace.cancelled) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.cancelled)
    #expect(model.presentation?.text == "new.ts")
}

private actor UncooperativeReadWorkspace: WorkspaceReading {
    private var continuations: [String: CheckedContinuation<Void, Never>] = [:]
    private var active = 0
    var currentActive: Int { active }
    private(set) var maximumActive = 0
    func files(in root: URL) -> FileListing {
        FileListing(files: [], isLimited: false, usesGitIgnore: false)
    }
    func read(_ url: URL) async -> TextSnapshot {
        active += 1
        maximumActive = max(maximumActive, active)
        let name = url.lastPathComponent
        if name.hasPrefix("slow") { await withCheckedContinuation { continuations[name] = $0 } }
        active -= 1
        return TextSnapshot(url: url, version: 1, text: name)
    }
    func isWaiting(_ name: String) -> Bool { continuations[name] != nil }
    func release(_ name: String) { continuations.removeValue(forKey: name)?.resume() }
    func releaseAll() {
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending { continuation.resume() }
    }
    func baseline(in root: URL, path: String, workingText: String) -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD")
    }
}

@Test @MainActor func rapidSwitchesBoundUncooperativeReadsAndShowLatest() async throws {
    let folder = try TemporaryFolder()
    let workspace = UncooperativeReadWorkspace()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(folder.url)
    model.select("slow-1.ts")
    for _ in 0..<400 where !(await workspace.isWaiting("slow-1.ts")) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await workspace.isWaiting("slow-1.ts"))
    model.select("slow-2.ts")
    for _ in 0..<400 where !(await workspace.isWaiting("slow-2.ts")) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await workspace.isWaiting("slow-2.ts"))
    for index in 3...50 { model.select("slow-\(index).ts") }
    model.select("latest.ts")
    #expect(await workspace.maximumActive <= 2)
    await workspace.release("slow-1.ts")
    for _ in 0..<400 where model.presentation?.text != "latest.ts" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text == "latest.ts")
    #expect(await workspace.isWaiting("slow-2.ts"))
    #expect(await workspace.maximumActive <= 2)
    await workspace.releaseAll()
}

@Test @MainActor func closingWindowDoesNotRetainItForUncooperativeRead() async throws {
    let folder = try TemporaryFolder()
    let workspace = UncooperativeReadWorkspace()
    var model: WorkspaceModel? = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    weak var weakModel = model
    await model?.open(folder.url)
    model?.select("slow-1.ts")
    for _ in 0..<400 where !(await workspace.isWaiting("slow-1.ts")) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await workspace.isWaiting("slow-1.ts"))
    model?.close()
    model = nil
    for _ in 0..<100 where weakModel != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(weakModel == nil)
    await workspace.releaseAll()
}

@Test @MainActor func appReadBudgetSurvivesClosedWindowsUntilProvidersExit() async throws {
    let folder = try TemporaryFolder()
    let workspace = UncooperativeReadWorkspace()
    let admission = WorkAdmission(maximumJobs: 2, maximumBytes: 2)
    let observer = FileWatchHub()
    var models: [WorkspaceModel] = []
    for index in 0..<5 {
        let model = WorkspaceModel(
            workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer,
            appReadAdmission: admission)
        await model.open(folder.url)
        model.select("slow-\(index).ts")
        models.append(model)
    }
    for _ in 0..<400 where await workspace.currentActive < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.currentActive == 2)
    #expect(await admission.activeJobs == 2)
    #expect(await workspace.maximumActive <= 2)
    for model in models { model.close() }
    models.removeAll()
    for _ in 0..<400 where await admission.activeJobs != 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await admission.activeJobs == 2)

    let next = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer,
        appReadAdmission: admission)
    defer { next.close() }
    await next.open(folder.url)
    next.select("latest.ts")
    try await Task.sleep(for: .milliseconds(50))
    #expect(next.presentation == nil)
    #expect(await workspace.maximumActive <= 2)
    if await workspace.isWaiting("slow-0.ts") {
        await workspace.release("slow-0.ts")
    } else if await workspace.isWaiting("slow-1.ts") {
        await workspace.release("slow-1.ts")
    } else if await workspace.isWaiting("slow-2.ts") {
        await workspace.release("slow-2.ts")
    } else if await workspace.isWaiting("slow-3.ts") {
        await workspace.release("slow-3.ts")
    } else {
        await workspace.release("slow-4.ts")
    }
    for _ in 0..<400 where next.presentation?.text != "latest.ts" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(next.presentation?.text == "latest.ts")
    #expect(await workspace.maximumActive <= 2)
    await workspace.releaseAll()
    for _ in 0..<400 where await admission.activeJobs != 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await admission.activeJobs == 0)
    #expect(await admission.admittedBytes == 0)
}

final class TemporaryFolder: Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("loffo-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

@Test func documentCacheKeepsRecentlyReadSnapshotsWhenEvicting() async throws {
    let folder = try TemporaryFolder()
    let store = DocumentStore(io: BoundedIO())
    let files = (0..<9).map { folder.url.appendingPathComponent("file-\($0).txt") }
    for (index, file) in files.enumerated() {
        try "content \(index)\n".write(to: file, atomically: true, encoding: .utf8)
    }
    var versions: [UInt64] = []
    for file in files.prefix(8) { versions.append(try await store.read(file).version) }
    #expect(try await store.read(files[0]).version == versions[0])
    _ = try await store.read(files[8])
    #expect(try await store.read(files[0]).version == versions[0])
    #expect(try await store.read(files[1]).version != versions[1])
}

@Test func documentCacheEvictsByBytesBeforeEntryCount() async throws {
    let folder = try TemporaryFolder()
    let store = DocumentStore(io: BoundedIO())
    let content = String(repeating: String(repeating: "x", count: 99) + "\n", count: 19_000)
    let files = (0..<5).map { folder.url.appendingPathComponent("large-\($0).txt") }
    for file in files { try content.write(to: file, atomically: true, encoding: .utf8) }
    var versions: [UInt64] = []
    for file in files.prefix(4) { versions.append(try await store.read(file).version) }
    #expect(try await store.read(files[0]).version == versions[0])
    _ = try await store.read(files[4])
    #expect(try await store.read(files[0]).version == versions[0])
    #expect(try await store.read(files[1]).version != versions[1])
}

@Test func discardingSnapshotsDoesNotAllowAnOlderReadToRefillTheCache() async throws {
    let folder = try TemporaryFolder()
    let file = folder.url.appendingPathComponent("sample.txt")
    try "current\n".write(to: file, atomically: true, encoding: .utf8)
    let io = BoundedIO(concurrency: 1)
    let store = DocumentStore(io: io)
    let gate = DispatchSemaphore(value: 0)
    let started = OSAllocatedUnfairLock(initialState: false)
    defer { gate.signal() }
    let blocker = Task.detached {
        try await io.run {
            started.withLock { $0 = true }
            gate.wait()
        }
    }
    for _ in 0..<300 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(started.withLock { $0 })
    let pending = Task { try await store.read(file) }
    for _ in 0..<300 where io.operationCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(io.operationCount >= 2)
    await store.discardCachedSnapshots()
    gate.signal()
    try await blocker.value
    let old = try await pending.value
    let reloaded = try await store.read(file)
    #expect(old.text == reloaded.text)
    #expect(old.version != reloaded.version)
    #expect(try await store.read(file).version == reloaded.version)
}

@Test func discardingSyntaxCachePreventsWaitingParseFromRetainingATree() async throws {
    let admission = WorkAdmission(maximumJobs: 1)
    try await admission.acquire(bytes: 1)
    let syntax = TreeSyntax(admission: admission)
    let snapshot = TextSnapshot(
        url: URL(fileURLWithPath: "/sample.ts"), version: 1, text: "const value = 1;\n")
    let pending = Task { await syntax.highlightsWithStatus(for: snapshot) }
    for _ in 0..<300 where await admission.queuedJobs == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await admission.queuedJobs == 1)
    await syntax.discardCachedTree()
    await admission.release(bytes: 1)
    let highlights = await pending.value
    #expect(!highlights.spans.isEmpty && !highlights.isLimited)
    #expect(await syntax.retainedSnapshot == nil)
    _ = await syntax.highlightsWithStatus(for: snapshot)
    #expect(await syntax.retainedSnapshot == snapshot)
    await syntax.discardCachedTree()
    #expect(await syntax.retainedSnapshot == nil)
}

@Test func workspaceReadRejectsParentReplacementDuringRead() throws {
    let folder = try TemporaryFolder()
    let root = folder.url.appendingPathComponent("project", isDirectory: true)
    let parent = root.appendingPathComponent("src", isDirectory: true)
    let moved = root.appendingPathComponent("old-src", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try "old\n".write(to: parent.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    #expect(throws: WorkspaceFailure.self) {
        try StableFileReader.read(in: root, path: "src/file.txt", limit: 1_024) {
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
            try "new\n".write(
                to: parent.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
    }
    #expect(try StableFileReader.read(in: root, path: "src/file.txt", limit: 1_024) == Data("new\n".utf8))
}

@Test func workspaceReadDoesNotReportMissingFileWhenItsParentWasReplaced() throws {
    let folder = try TemporaryFolder()
    let root = folder.url.appendingPathComponent("project", isDirectory: true)
    let parent = root.appendingPathComponent("src", isDirectory: true)
    let moved = root.appendingPathComponent("old-src", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try "old\n".write(to: parent.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    #expect(throws: WorkspaceFailure.self) {
        try StableFileReader.read(in: root, path: "src/file.txt", limit: 1_024) {
            try FileManager.default.moveItem(at: parent, to: moved)
            try FileManager.default.removeItem(at: moved.appendingPathComponent("file.txt"))
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        }
    }
}

@Test func workspaceReadRejectsRootReplacementDuringRead() throws {
    let folder = try TemporaryFolder()
    let root = folder.url.appendingPathComponent("project", isDirectory: true)
    let moved = folder.url.appendingPathComponent("old-project", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try "old\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    #expect(throws: WorkspaceFailure.self) {
        try StableFileReader.read(in: root, path: "file.txt", limit: 1_024) {
            try FileManager.default.moveItem(at: root, to: moved)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            try "new\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        }
    }
    #expect(try StableFileReader.read(in: root, path: "file.txt", limit: 1_024) == Data("new\n".utf8))
}

@Test func workspaceReadRejectsRootAncestorRedirectDuringRead() throws {
    let folder = try TemporaryFolder()
    let outside = try TemporaryFolder()
    let ancestor = folder.url.appendingPathComponent("ancestor", isDirectory: true)
    let root = ancestor.appendingPathComponent("project", isDirectory: true)
    let moved = folder.url.appendingPathComponent("old-ancestor", isDirectory: true)
    let outsideRoot = outside.url.appendingPathComponent("project", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
    try "old\n".write(to: root.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try "outside\n".write(
        to: outsideRoot.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    #expect(throws: WorkspaceFailure.self) {
        try StableFileReader.read(in: root, path: "file.txt", limit: 1_024) {
            try FileManager.default.moveItem(at: ancestor, to: moved)
            try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: outside.url)
        }
    }
}

@Test func readerRejectsSymlinksWithoutFollowingTarget() async throws {
    let folder = try TemporaryFolder()
    let target = folder.url.appendingPathComponent("target.ts")
    let link = folder.url.appendingPathComponent("link.ts")
    try "private target".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let store = DocumentStore(io: BoundedIO())
    await #expect(throws: (any Error).self) { try await store.read(link) }
}

@Test func sharedDocumentReadCancellationDoesNotCancelAnotherSubscriber() async throws {
    let folder = try TemporaryFolder()
    let file = folder.url.appendingPathComponent("shared.swift")
    try "shared content\n".write(to: file, atomically: true, encoding: .utf8)
    let io = BoundedIO(concurrency: 1)
    let store = DocumentStore(io: io)
    let (entered, signalEntered) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let blocker = Task {
        try await io.run {
            signalEntered.yield()
            release.wait()
        }
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    let first = Task { try await store.read(file) }
    let second = Task { try await store.read(file) }
    for _ in 0..<400 where await store.activeReadSubscribers < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await store.activeReadSubscribers == 2)
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(await store.activeReadSubscribers == 1)
    release.signal()
    _ = try await blocker.value
    let snapshot = try await second.value
    #expect(snapshot.text == "shared content\n")
    #expect(await store.activeReadSubscribers == 0)
}

@Test func cancelledQueuedIOIsNotExecuted() async throws {
    let io = BoundedIO(concurrency: 1)
    let (entered, signalEntered) = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    let ran = OSAllocatedUnfairLock(initialState: false)
    let blocker = Task {
        try await io.run {
            signalEntered.yield()
            release.wait()
        }
    }
    var iterator = entered.makeAsyncIterator()
    _ = await iterator.next()
    let waiting = Task { try await io.run { ran.withLock { $0 = true } } }
    try await Task.sleep(for: .milliseconds(20))
    waiting.cancel()
    release.signal()
    _ = try await blocker.value
    await #expect(throws: CancellationError.self) { try await waiting.value }
    #expect(!ran.withLock { $0 })
}

@Test func canonicallyEquivalentEditsPreserveExactBytes() async throws {
    let before = "const name = '\u{e9}';\n"
    let after = "const name = 'e\u{301}';\n"
    let folder = try TemporaryFolder()
    let url = folder.url.appendingPathComponent("unicode.ts")
    let store = DocumentStore(io: BoundedIO())
    try before.write(to: url, atomically: true, encoding: .utf8)
    let first = try await store.read(url)
    try after.write(to: url, atomically: true, encoding: .utf8)
    let second = try await store.read(url)
    #expect(second.version > first.version)
    #expect(Array(second.text.utf8) == Array(after.utf8))
    for budget in [1, 400_000] {
        let result = try await LineDiff(cellBudget: budget).compare(before: before, after: after)
        #expect(result.added == 1 && result.removed == 1)
        #expect(
            Array(result.lines.filter { $0.kind != .added }.map(\.text).joined().utf8) == Array(before.utf8))
        #expect(
            Array(result.lines.filter { $0.kind != .removed }.map(\.text).joined().utf8) == Array(after.utf8))
    }
}

@Test func sharedTextAdmissionRejectsLongHistoricalLines() throws {
    #expect(throws: WorkspaceFailure.self) {
        try TextLimits.decode(Data(String(repeating: "a", count: 20_001).utf8))
    }
    #expect(throws: WorkspaceFailure.self) {
        try TextLimits.validatePresentation(String(repeating: "😀", count: 10_001))
    }
    #expect(try TextLimits.decode(Data("hello\r\n".utf8)) == "hello\r\n")
}

@Test func streamedPresentationLimitsMatchJoinedOutput() {
    func outcome(_ operation: () throws -> Void) -> String {
        do {
            try operation()
            return "ok"
        } catch {
            return String(describing: error)
        }
    }
    let cases: [[String]] = [
        [], [""], ["before\r", "after\r\n", "👩‍💻 e\u{301}", "\u{2028}end"],
        [String(repeating: "😀", count: 10_000)],
        [String(repeating: "😀", count: 10_001)],
        Array(repeating: "", count: 60_000),
        [String(repeating: "a", count: 4 * 1_024 * 1_024 + 2)],
    ]
    for rows in cases {
        let joined = rows.map { $0.hasSuffix("\n") ? $0 : $0 + "\n" }.joined()
        let expected = outcome { try TextLimits.validatePresentation(joined) }
        let actual = outcome { try TextLimits.validatePresentationRows(rows) }
        #expect(actual == expected)
    }
}

@Test func streamedPresentationValidationHonorsCancellation() async {
    let task = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        try TextLimits.validatePresentationRows(["line\n"])
    }
    await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func sharedAdmissionCancelsWaitersAndReleasesCapacity() async throws {
    let budget = WorkAdmission(maximumJobs: 1, maximumBytes: 10)
    try await budget.acquire(bytes: 8)
    let pending = Task { try await budget.acquire(bytes: 4) }
    try await Task.sleep(for: .milliseconds(20))
    pending.cancel()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(await budget.activeJobs == 1)
    #expect(await budget.admittedBytes == 8)
    await budget.release(bytes: 8)
    #expect(await budget.activeJobs == 0)
    try await budget.acquire(bytes: 10)
    await budget.release(bytes: 10)
    await #expect(throws: WorkspaceFailure.self) { try await budget.acquire(bytes: 11) }
    await #expect(throws: WorkspaceFailure.self) { try await budget.acquire(bytes: -1) }
}

@Test func cancellingFirstBudgetWaiterAdmitsTheNextEligibleTask() async throws {
    let budget = WorkAdmission(maximumJobs: 2, maximumBytes: 10)
    try await budget.acquire(bytes: 8)
    let blocked = Task { try await budget.acquire(bytes: 3) }
    for _ in 0..<200 where await budget.queuedJobs != 1 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await budget.queuedJobs == 1)
    for _ in 0..<2 {
        let bypass = Task { try await budget.acquire(bytes: 2) }
        for _ in 0..<200 where await budget.activeJobs != 2 { try await Task.sleep(for: .milliseconds(2)) }
        if await budget.activeJobs != 2 {
            Issue.record("Expected an eligible task to bypass the blocked head")
            bypass.cancel()
            blocked.cancel()
            await budget.release(bytes: 8)
            return
        }
        try await bypass.value
        await budget.release(bytes: 2)
    }
    let following = Task { try await budget.acquire(bytes: 2) }
    for _ in 0..<200 where await budget.queuedJobs != 2 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await budget.queuedJobs == 2)
    blocked.cancel()
    await #expect(throws: CancellationError.self) { try await blocked.value }
    for _ in 0..<100 where await budget.activeJobs != 2 {
        try await Task.sleep(for: .milliseconds(2))
    }
    let admitted = await budget.activeJobs == 2
    #expect(admitted, "Removing a blocked waiter must drain the queue immediately")
    if admitted {
        try await following.value
        await budget.release(bytes: 2)
    } else {
        following.cancel()
        _ = try? await following.value
    }
    await budget.release(bytes: 8)
    #expect(await budget.activeJobs == 0)
}

@Test func budgetAllowsLimitedBypassesWithoutStarvingLargeRequests() async throws {
    let budget = WorkAdmission(maximumJobs: 3, maximumBytes: 10)
    try await budget.acquire(bytes: 8)
    let large = Task { try await budget.acquire(bytes: 4) }
    for _ in 0..<200 where await budget.queuedJobs != 1 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await budget.queuedJobs == 1)
    for _ in 0..<2 {
        let small = Task { try await budget.acquire(bytes: 2) }
        for _ in 0..<200 where await budget.activeJobs != 2 { try await Task.sleep(for: .milliseconds(2)) }
        let admitted = await budget.activeJobs == 2
        #expect(admitted, "Available capacity should admit a small task behind a blocked large task")
        if !admitted {
            small.cancel()
            large.cancel()
            await budget.release(bytes: 8)
            return
        }
        try await small.value
        await budget.release(bytes: 2)
    }
    let following = Task { try await budget.acquire(bytes: 2) }
    for _ in 0..<200 where await budget.queuedJobs != 2 { try await Task.sleep(for: .milliseconds(2)) }
    #expect(await budget.queuedJobs == 2, "The bypass limit must reserve capacity for the large task")
    #expect(await budget.activeJobs == 1)
    await budget.release(bytes: 8)
    try await large.value
    try await following.value
    #expect(await budget.activeJobs == 2)
    #expect(await budget.admittedBytes == 6)
    await budget.release(bytes: 4)
    await budget.release(bytes: 2)
    #expect(await budget.queuedJobs == 0)
    #expect(await budget.admittedBytes == 0)
}

@Test func cancellingRunningDiffReleasesBudgetForNextComparison() async throws {
    let budget = WorkAdmission(maximumJobs: 1, maximumBytes: 64 * 1024 * 1024)
    let diff = LineDiff(cellBudget: 9_000_000, admission: budget)
    let common = String(repeating: "x", count: 200)
    let before = (0..<2_500).map { "\(common)old\($0)\n" }.joined()
    let after = (0..<2_500).map { "\(common)new\($0)\n" }.joined()
    let running = Task { try await diff.compare(before: before, after: after) }
    for _ in 0..<500 where await budget.activeJobs == 0 {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(await budget.activeJobs == 1)
    running.cancel()
    await #expect(throws: CancellationError.self) { try await running.value }
    #expect(await budget.activeJobs == 0)
    #expect(await budget.admittedBytes == 0)
    let next = try await diff.compare(before: "one\n", after: "two\n")
    #expect(next.added == 1 && next.removed == 1)
    #expect(await budget.activeJobs == 0)
}

@Test @MainActor func folderEventsRefreshNestedFilesAndHiddenWindowsCatchUp() async throws {
    let folder = try TemporaryFolder()
    let child = folder.url.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    let hub = FileWatchHub()
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: nil), syntax: TreeSyntax(), diff: LineDiff(), observer: hub)
    await model.open(folder.url)
    let file = child.appendingPathComponent("new.ts")
    try "new".write(to: file, atomically: true, encoding: .utf8)
    for _ in 0..<300 where !model.files.contains(where: { $0.path == "src/new.ts" }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.files.contains { $0.path == "src/new.ts" })
    model.setVisible(false)
    try FileManager.default.moveItem(at: file, to: child.appendingPathComponent("renamed.ts"))
    try await Task.sleep(for: .milliseconds(700))
    model.setVisible(true)
    for _ in 0..<300 where !model.files.contains(where: { $0.path == "src/renamed.ts" }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.files.contains { $0.path == "src/renamed.ts" })
    #expect(!model.files.contains { $0.path == "src/new.ts" })
    model.close()
    #expect(hub.repositorySubscriptionCount == 0)
}

@Test func diffSyntaxCoordinatesFollowEachSourceSide() async throws {
    let before = "const a = 'é';\nconst b = 1;\n"
    let after = "const a = 'e\u{301}';\nconst b = 2;\n"
    let url = URL(fileURLWithPath: "/fixture.ts")
    let syntax = TreeSyntax()
    let oldSpans = await syntax.highlights(for: TextSnapshot(url: url, version: 1, text: before))
    let newSpans = await syntax.highlights(for: TextSnapshot(url: url, version: 2, text: after))
    let result = try await LineDiff().compare(before: before, after: after)
    let spans = DiffSyntaxProjection.spans(result: result, before: oldSpans, after: newSpans)
    let display = result.lines.map { $0.text.hasSuffix("\n") ? $0.text : $0.text + "\n" }.joined() as NSString
    #expect(spans.allSatisfy { NSMaxRange($0.range) <= display.length })
    let strings = spans.filter { $0.kind == .string }.map { Array(display.substring(with: $0.range).utf8) }
    #expect(strings.contains(Array("'é'".utf8)))
    #expect(strings.contains(Array("'e\u{301}'".utf8)))
}

@Test func syntaxHighlighterSupportsSwiftPythonRustAndJava() async {
    let fixtures: [(String, String)] = [
        ("swift", "// Swift\nstruct Reader { let count = 42 }\n"),
        ("py", "# Python\ndef read():\n    return 42\n"),
        ("rs", "// Rust\nfn read() { let count: i32 = 42; }\n"),
        ("java", "// Java\nclass Reader { int count = 42; }\n"),
    ]
    for (index, fixture) in fixtures.enumerated() {
        let syntax = TreeSyntax()
        let snapshot = TextSnapshot(
            url: URL(fileURLWithPath: "/fixture/sample.\(fixture.0)"),
            version: UInt64(index + 1), text: fixture.1)
        let spans = await syntax.highlights(for: snapshot)
        #expect(spans.contains { $0.kind == .keyword }, "\(fixture.0) should highlight keywords")
        #expect(spans.contains { $0.kind == .number }, "\(fixture.0) should highlight numeric literals")
        #expect(spans.contains { $0.kind == .comment }, "\(fixture.0) should highlight comments")
    }
}

@Test func vscodeThemeImportsCommonTextMateScopes() throws {
    let json =
        ##"{"settings":{"foreground":"#222222"},"tokenColors":[{"scope":["keyword.control","storage.type"],"settings":{"foreground":"#aa11bb"}},{"scope":"string.quoted","settings":{"foreground":"#22bb44"}},{"scope":"comment.line","settings":{"foreground":"#999999"}},{"scope":"constant.numeric","settings":{"foreground":"#123456"}},{"scope":"entity.name.type","settings":{"foreground":"#abcdef"}}]}"##
    let theme = try EditorSyntaxTheme(vscodeJSON: Data(json.utf8))
    #expect(theme.hexColor(for: .keyword) == "#aa11bb")
    #expect(theme.hexColor(for: .string) == "#22bb44")
    #expect(theme.hexColor(for: .comment) == "#999999")
    #expect(theme.hexColor(for: .number) == "#123456")
    #expect(theme.hexColor(for: .type) == "#abcdef")
    #expect(theme.hexForeground == "#222222")
}

@Test func vscodeThemeImportsCallAndConstructorColors() throws {
    let json =
        ##"{"tokenColors":[{"scope":"entity.name.function","settings":{"foreground":"#112233"}},{"scope":"entity.name.type","settings":{"foreground":"#445566"}}]}"##
    let theme = try EditorSyntaxTheme(vscodeJSON: Data(json.utf8))
    #expect(theme.hexColor(for: .functionCall) == "#112233")
    #expect(theme.hexColor(for: .constructor) == "#445566")
}

@Test func vscodeThemeImportsParameterColor() throws {
    let json = ##"{"tokenColors":[{"scope":"variable.parameter","settings":{"foreground":"#1234ab"}}]}"##
    let theme = try EditorSyntaxTheme(vscodeJSON: Data(json.utf8))
    #expect(theme.hexColor(for: .parameter) == "#1234ab")
    #expect(theme.hexForeground == "000950")
    #expect(EditorSyntaxTheme.standard.hexColor(for: .type) == "000950")
}

@Test func foldedDiffCopyExcludesVirtualHeaders() async throws {
    let before = (0..<30).map { "line \($0)\n" }.joined()
    let after = before.replacingOccurrences(of: "line 15\n", with: "changed 15\n")
    let result = try await LineDiff().compare(before: before, after: after)
    let projection = UnifiedProjection(result: result)
    #expect(projection.rows.contains { $0.heading != nil })
    #expect(projection.rows.count < result.lines.count)
    let copy = UnifiedProjection.copy(
        range: NSRange(location: 0, length: projection.text.utf16.count), rows: projection.rows)
    #expect(!copy.hasPrefix("\n"))
    #expect(!copy.contains("@@"))
    #expect(copy.contains("line 15\nchanged 15\n"))
    let expanded = UnifiedProjection(result: result, expanded: true)
    #expect(!expanded.rows.contains { $0.heading != nil })
    #expect(expanded.rows.count == result.lines.count)
    #expect(expanded.hunkStarts.count == 1)
    #expect(
        expanded.rows[expanded.hunkStarts[0]].line?.kind == .removed
            || expanded.rows[expanded.hunkStarts[0]].line?.kind == .context)

    let separatedBefore = (0..<80).map { "line \($0)\n" }.joined()
    let separatedAfter =
        separatedBefore
        .replacingOccurrences(of: "line 10\n", with: "changed 10\n")
        .replacingOccurrences(of: "line 60\n", with: "changed 60\n")
    let separated = try await LineDiff().compare(before: separatedBefore, after: separatedAfter)
    #expect(UnifiedProjection(result: separated).hunkStarts.count == 2)
    #expect(UnifiedProjection(result: separated, expanded: true).hunkStarts.count == 2)
}

@Test func manyHunkProjectionPreservesNavigationAndCopy() throws {
    var lines: [DiffLine] = []
    for number in 1...20_000 {
        if number % 20 == 10 {
            lines.append(DiffLine(text: "旧 \(number)\n", kind: .removed, oldNumber: number, newNumber: nil))
            lines.append(DiffLine(text: "新 \(number)\n", kind: .added, oldNumber: nil, newNumber: number))
        } else {
            lines.append(
                DiffLine(text: "line \(number)\n", kind: .context, oldNumber: number, newNumber: number))
        }
    }
    let result = DiffResult(lines: lines, isCoarse: false)
    let folded = UnifiedProjection(result: result)
    let expanded = UnifiedProjection(result: result, expanded: true)
    #expect(folded.text == folded.rows.map(\.text).joined())
    #expect(expanded.text == expanded.rows.map(\.text).joined())
    #expect(result.added == 1_000)
    #expect(result.removed == 1_000)
    #expect(folded.hunkStarts.count == 1_000)
    #expect(expanded.hunkStarts.count == 1_000)
    #expect(folded.hunkStarts.allSatisfy { folded.rows[$0].heading != nil })
    #expect(expanded.rows.compactMap(\.line) == lines)
    let copied = UnifiedProjection.copy(
        range: NSRange(location: 0, length: expanded.text.utf16.count), rows: expanded.rows)
    #expect(copied == result.text)
    let foldedCopy = UnifiedProjection.copy(
        range: NSRange(location: 0, length: folded.text.utf16.count), rows: folded.rows)
    #expect(!foldedCopy.contains("@@"))
    #expect(foldedCopy.contains("旧 19990\n新 19990\n"))
}

@Test func cancelledDiffProjectionsDoNotProducePartialResults() async {
    let result = DiffResult(
        lines: [DiffLine(text: "old\n", kind: .removed, oldNumber: 1, newNumber: nil)], isCoarse: false)
    let unified = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try UnifiedProjection.cancellable(result: result)
    }
    await #expect(throws: CancellationError.self) { try await unified.value }
    let syntax = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try DiffSyntaxProjection.cancellableSpans(result: result, before: [], after: [])
    }
    await #expect(throws: CancellationError.self) { try await syntax.value }
}
