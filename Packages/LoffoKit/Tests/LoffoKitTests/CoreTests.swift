import Foundation
import LoffoDiff
import LoffoDocument
import LoffoDomain
import LoffoEditorUI
import LoffoFeatures
import LoffoInfrastructure
import Testing

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
    #expect(spans.count <= 30_000)
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

final class TemporaryFolder: Sendable {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("loffo-test-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: url) }
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
