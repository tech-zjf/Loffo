import AppKit
import Combine
import CoreServices
import Foundation
import LoffoDiff
import LoffoDocument
import LoffoDomain
import LoffoEditorUI
import SwiftUI
import Testing
import os

@testable import LoffoFeatures
@testable import LoffoInfrastructure

@Test func projectionBudgetRemainsHeldUntilCancelledWorkExits() async throws {
    let budget = WorkAdmission(maximumJobs: 1, maximumBytes: 1)
    let worker = ProjectionWork(admission: budget)
    let started = OSAllocatedUnfairLock(initialState: false)
    let secondStarted = OSAllocatedUnfairLock(initialState: false)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let first = Task.detached {
        try await worker.run(bytes: 1) {
            started.withLock { $0 = true }
            gate.wait()
            return 1
        }
    }
    for _ in 0..<400 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(started.withLock { $0 })
    first.cancel()
    let second = Task.detached {
        try await worker.run(bytes: 1) {
            secondStarted.withLock { $0 = true }
            return 2
        }
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(await budget.activeJobs == 1)
    #expect(!secondStarted.withLock { $0 })
    gate.signal()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(try await second.value == 2)
    #expect(await budget.activeJobs == 0)
    #expect(await budget.admittedBytes == 0)
}

private struct DenseProjectionSyntax: SyntaxProviding {
    func highlights(for snapshot: TextSnapshot) async -> [SyntaxSpan] {
        Array(repeating: SyntaxSpan(range: NSRange(location: 0, length: 1), kind: .keyword), count: 1_000)
    }
}

@Test @MainActor func rejectedRefinementKeepsDiffAndReportsLimitedSyntax() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "old\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "new\n".write(to: file, atomically: true, encoding: .utf8)
    let budget = WorkAdmission(maximumJobs: 1, maximumBytes: 8 * 1_024 * 1_024 + 4_096)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: DenseProjectionSyntax(),
        diff: LineDiff(), observer: FileWatchHub(), processingAdmission: budget)
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<400 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    model.select("sample.swift")
    for _ in 0..<400 where model.presentation?.syntaxLimited != true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.syntaxLimited == true)
    #expect(model.presentation?.diff?.isCoarse == false)
    #expect(model.presentation?.text.contains("new\n") == true)
    #expect(model.error == nil)
    #expect(await budget.activeJobs == 0)
}

@MainActor private final class InactiveLease: ObservationLease {
    var isActive: Bool { false }
    func cancel() {}
}

@MainActor private final class WatchEventCounter { var count = 0 }

@Test @MainActor func directorySymlinkWatchIgnoresTargetChildrenButDetectsRetargeting() async throws {
    let folder = try TemporaryFolder()
    let first = folder.url.appendingPathComponent("first", isDirectory: true)
    let second = folder.url.appendingPathComponent("second", isDirectory: true)
    let link = folder.url.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "first")
    let hub = FileWatchHub()
    let count = WatchEventCounter()
    let lease = hub.observe(link) { count.count += 1 }
    defer { lease.cancel() }
    try "unrelated".write(to: first.appendingPathComponent("child"), atomically: true, encoding: .utf8)
    try await Task.sleep(for: .milliseconds(500))
    #expect(count.count == 0)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "second")
    for _ in 0..<300 where count.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count.count > 0 && lease.isActive)
}

@Test @MainActor func fileWatchIgnoresSiblingWritesButTracksReplacementAndCreation() async throws {
    let folder = try TemporaryFolder()
    let watched = folder.url.appendingPathComponent("watched.txt")
    let sibling = folder.url.appendingPathComponent("sibling.txt")
    try "first".write(to: watched, atomically: true, encoding: .utf8)
    let hub = FileWatchHub()
    let count = WatchEventCounter()
    let lease = hub.observe(watched) { count.count += 1 }
    defer { lease.cancel() }
    for index in 0..<30 {
        try "unrelated \(index)".write(to: sibling, atomically: true, encoding: .utf8)
    }
    try await Task.sleep(for: .milliseconds(500))
    #expect(count.count == 0)

    try "replacement".write(to: watched, atomically: true, encoding: .utf8)
    for _ in 0..<300 where count.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count.count > 0)
    count.count = 0
    try FileManager.default.removeItem(at: watched)
    for _ in 0..<300 where count.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count.count > 0)
    count.count = 0
    try "created".write(to: watched, atomically: true, encoding: .utf8)
    for _ in 0..<300 where count.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count.count > 0 && lease.isActive)
}

@Test @MainActor func retryingSharedRepositoryWatchKeepsOtherSubscribers() async throws {
    let folder = try TemporaryFolder()
    let root = folder.url.appendingPathComponent("root", isDirectory: true)
    let moved = folder.url.appendingPathComponent("moved", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hub = FileWatchHub()
    let count = WatchEventCounter()
    let first = await hub.observeWorkspace(root) {}
    let second = await hub.observeWorkspace(root) { count.count += 1 }
    defer {
        first.cancel()
        second.cancel()
    }
    #expect(first.isActive && second.isActive)
    try FileManager.default.moveItem(at: root, to: moved)
    for _ in 0..<800 where first.isActive { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!first.isActive && !second.isActive)
    try FileManager.default.moveItem(at: moved, to: root)
    await first.retry()
    #expect(first.isActive && second.isActive)
    first.cancel()
    #expect(second.isActive)
    count.count = 0
    try "changed".write(to: root.appendingPathComponent("file"), atomically: true, encoding: .utf8)
    for _ in 0..<500 where count.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count.count > 0)
}

@MainActor private final class InactiveObserver: FileObserving {
    func observe(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> any ObservationLease {
        InactiveLease()
    }
}

@Test @MainActor func monitoringFailureIsVisibleAndPreventsReview() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "old\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "new\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: InactiveObserver())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<400 where model.presentation?.diff == nil || model.isRefreshingFiles {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.diff != nil)
    #expect(!model.monitoringAvailable)
    #expect(!model.canReview)
    model.markReviewed()
    #expect(!model.reviewed)
}

@Test @MainActor func watcherReportsMissingRootsAndCancelsLeases() async throws {
    let folder = try TemporaryFolder()
    let hub = FileWatchHub()
    let missing = folder.url.appendingPathComponent("missing")
    let repository = await hub.observeWorkspace(missing) {}
    let file = hub.observe(missing.appendingPathComponent("file")) {}
    #expect(!repository.isActive)
    #expect(!file.isActive)
    repository.cancel()
    file.cancel()
    let existingParent = hub.observe(folder.url.appendingPathComponent("not-created-yet")) {}
    #expect(existingParent.isActive)
    let existingRoot = await hub.observeWorkspace(folder.url) {}
    #expect(existingRoot.isActive)
    existingRoot.cancel()
    existingParent.cancel()
    #expect(!existingParent.isActive)
}

@Test @MainActor func repositoryStreamSetupIsOffMainActorAndCancelledStartsStayInactive() async throws {
    let folder = try TemporaryFolder()
    let setupStarted = OSAllocatedUnfairLock(initialState: false)
    let gate = DispatchSemaphore(value: 0)
    defer { gate.signal() }
    let observation = RepositoryObservation(root: folder.url) { _, _ in
        setupStarted.withLock { $0 = true }
        _ = gate.wait(timeout: .now() + 5)
        return StartedStream(stream: nil, started: false)
    }
    let start = Task { await observation.startIfNeeded() }
    for _ in 0..<500 where !setupStarted.withLock({ $0 }) {
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(setupStarted.withLock { $0 }, "Stream creation should run outside the main actor")

    let actorProbe = Task { @MainActor in true }
    #expect(await actorProbe.value, "Main actor work should continue while stream setup is pending")
    observation.stop()
    gate.signal()
    await start.value
    #expect(!observation.isActive, "A cancelled setup must not install its stream")
}

@Test func gitMetadataRelativePathsResolveInsideTheRepositoryDirectory() async throws {
    let fixture = try GitFixture()
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let root = URL(fileURLWithPath: fixture.folder.url.path, isDirectory: false)
    let roots = try await workspace.repositoryObservationRoots(in: root)
    let expected = fixture.folder.url.appendingPathComponent(".git").resolvingSymlinksInPath().path
    #expect(Set(roots.map(\.path)) == [expected, fixture.folder.url.resolvingSymlinksInPath().path])
}

@Test @MainActor func movingWatchedRepositoryRevokesLiveReview() async throws {
    let fixture = try GitFixture()
    try fixture.run(["init", "nested"])
    for (key, value) in [("user.name", "Loffo Test"), ("user.email", "test@example.invalid")] {
        try fixture.run(["-C", "nested", "config", key, value])
    }
    let root = fixture.folder.url.appendingPathComponent("nested", isDirectory: true)
    let file = root.appendingPathComponent("sample.swift")
    try "old\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["-C", "nested", "add", "."])
    try fixture.run(["-C", "nested", "commit", "-m", "base"])
    try "new\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(root)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.monitoringAvailable && model.canReview)
    model.markReviewed()
    try FileManager.default.moveItem(at: root, to: fixture.folder.url.appendingPathComponent("moved"))
    for _ in 0..<800 where model.monitoringAvailable { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.monitoringAvailable)
    #expect(!model.reviewed && !model.canReview)
    let moved = fixture.folder.url.appendingPathComponent("moved", isDirectory: true)
    try "changed while away\n".write(
        to: moved.appendingPathComponent("sample.swift"), atomically: true, encoding: .utf8)
    try FileManager.default.moveItem(at: moved, to: root)
    for _ in 0..<1000
    where !model.monitoringAvailable || !model.canReview
        || model.presentation?.text.contains("changed while away") != true
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.monitoringAvailable && model.canReview && !model.reviewed)
    #expect(model.presentation?.text.contains("changed while away") == true)
}

private actor SlowFirstDiff: DiffComputing {
    private let real = LineDiff()
    private(set) var started = false
    private(set) var cancelled = false
    func compare(before: String, after: String) async throws -> DiffResult {
        if !started {
            started = true
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled = true
                throw error
            }
        }
        return try await real.compare(before: before, after: after)
    }
}

private actor TwoWindowDiff: DiffComputing {
    private let real = LineDiff()
    private(set) var firstStarted = false
    private(set) var firstCancelled = false
    private(set) var secondStarted = false
    private(set) var secondCancelled = false
    private var secondContinuation: CheckedContinuation<Void, Never>?
    func compare(before: String, after: String) async throws -> DiffResult {
        if after.contains("first") {
            firstStarted = true
            do { try await Task.sleep(for: .seconds(30)) } catch {
                firstCancelled = true
                throw error
            }
        } else {
            secondStarted = true
            await withCheckedContinuation { secondContinuation = $0 }
            if Task.isCancelled { secondCancelled = true }
            try Task.checkCancellation()
        }
        return try await real.compare(before: before, after: after)
    }
    func resumeSecond() {
        secondContinuation?.resume()
        secondContinuation = nil
    }
}

private actor RetiredDiffRace: DiffComputing {
    private var firstContinuation: CheckedContinuation<Void, Never>?
    private(set) var firstStarted = false
    private(set) var firstFinished = false
    private(set) var secondStarted = false
    private(set) var secondCancelled = false
    func compare(before: String, after: String) async throws -> DiffResult {
        if after.contains("first") {
            firstStarted = true
            await withCheckedContinuation { firstContinuation = $0 }
            firstFinished = true
            return DiffResult(lines: [], isCoarse: false)
        }
        if after.contains("second") {
            secondStarted = true
            do { try await Task.sleep(for: .seconds(10)) } catch {
                secondCancelled = true
                throw error
            }
        }
        return try await LineDiff().compare(before: before, after: after)
    }
    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}

@Test @MainActor func retiredDiffCannotClearTheCurrentCancellationHandle() async throws {
    let fixture = try GitFixture()
    for name in ["first.swift", "second.swift", "third.swift"] {
        try "old\n".write(
            to: fixture.folder.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    for name in ["first.swift", "second.swift", "third.swift"] {
        try "new \(name)\n".write(
            to: fixture.folder.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let diff = RetiredDiffRace()
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: diff,
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<400 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    model.select("first.swift")
    for _ in 0..<400 where !(await diff.firstStarted) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await diff.firstStarted)
    model.select("second.swift")
    for _ in 0..<400 where !(await diff.secondStarted) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await diff.secondStarted)
    await diff.releaseFirst()
    for _ in 0..<400 where !(await diff.firstFinished) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await diff.firstFinished)
    try await Task.sleep(for: .milliseconds(50))
    model.select("third.swift")
    for _ in 0..<400 where !(await diff.secondCancelled) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await diff.secondCancelled)
    for _ in 0..<400 where model.presentation?.text.contains("new third.swift") != true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text.contains("new third.swift") == true)
}

@Test @MainActor func closingOneWindowDoesNotCancelTheOtherWindowsDiff() async throws {
    let fixture = try GitFixture()
    for name in ["first.swift", "second.swift"] {
        try "old\n".write(
            to: fixture.folder.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    for name in ["first.swift", "second.swift"] {
        try "new \(name)\n".write(
            to: fixture.folder.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let diff = TwoWindowDiff()
    let observer = FileWatchHub()
    let first = WorkspaceModel(workspace: workspace, syntax: TreeSyntax(), diff: diff, observer: observer)
    let second = WorkspaceModel(workspace: workspace, syntax: TreeSyntax(), diff: diff, observer: observer)
    defer {
        first.close()
        second.close()
    }
    for model in [first, second] {
        await model.open(fixture.folder.url)
        model.setDiff(true)
    }
    for _ in 0..<400 where first.isRefreshingFiles || second.isRefreshingFiles {
        try await Task.sleep(for: .milliseconds(10))
    }
    first.select("first.swift")
    for _ in 0..<400 where !(await diff.firstStarted) { try await Task.sleep(for: .milliseconds(10)) }
    second.select("second.swift")
    for _ in 0..<400 where !(await diff.secondStarted) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await diff.firstStarted)
    #expect(await diff.secondStarted)
    first.close()
    for _ in 0..<200 where !(await diff.firstCancelled) { try await Task.sleep(for: .milliseconds(10)) }
    await diff.resumeSecond()
    for _ in 0..<400 where second.presentation?.text.contains("new second.swift") != true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await diff.firstCancelled)
    #expect(!(await diff.secondCancelled))
    #expect(second.presentation?.text.contains("new second.swift") == true)
}

@Test @MainActor func baselineBudgetIsHeldUntilWindowReleasesIt() async throws {
    let fixture = try GitFixture()
    for name in ["first.swift", "second.swift"] {
        let file = fixture.folder.url.appendingPathComponent(name)
        try "old\n".write(to: file, atomically: true, encoding: .utf8)
    }
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    for name in ["first.swift", "second.swift"] {
        try "new\n".write(
            to: fixture.folder.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let budget = WorkAdmission(maximumJobs: 1, maximumBytes: 8 * 1_024 * 1_024)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let observer = FileWatchHub()
    let slowSyntax = DelayedFirstSyntax()
    let first = WorkspaceModel(
        workspace: workspace, syntax: slowSyntax, diff: LineDiff(), observer: observer,
        baselineAdmission: budget)
    let second = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer,
        baselineAdmission: budget)
    defer {
        first.close()
        second.close()
    }
    for model in [first, second] {
        await model.open(fixture.folder.url)
        model.setDiff(true)
    }
    for _ in 0..<400 where first.isRefreshingFiles || second.isRefreshingFiles {
        try await Task.sleep(for: .milliseconds(10))
    }
    first.select("first.swift")
    for _ in 0..<400 where !first.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(first.canReview)
    for _ in 0..<400 where !(await slowSyntax.started) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await slowSyntax.started)
    #expect(await budget.admittedBytes == 8 * 1_024 * 1_024)
    second.select("second.swift")
    try await Task.sleep(for: .milliseconds(50))
    #expect(!second.canReview)
    #expect(await budget.activeJobs == 1)
    first.setDiff(false)
    try await Task.sleep(for: .milliseconds(50))
    #expect(await budget.activeJobs == 1)
    #expect(!second.canReview)
    await slowSyntax.resume()
    for _ in 0..<600 where !second.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(second.canReview)
    #expect(await budget.admittedBytes == 8 * 1_024 * 1_024)
    second.reload()
    for _ in 0..<600 where !second.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(second.canReview)
    second.close()
    for _ in 0..<400 where await budget.activeJobs != 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await budget.activeJobs == 0)
    #expect(await budget.admittedBytes == 0)
}

@Test @MainActor func switchingFilesCancelsTheObsoleteDiff() async throws {
    let fixture = try GitFixture()
    for name in ["first.swift", "second.swift"] {
        try "old\n".write(
            to: fixture.folder.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    for name in ["first.swift", "second.swift"] {
        try "new \(name)\n".write(
            to: fixture.folder.url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    let slow = SlowFirstDiff()
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: slow,
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<400 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    model.select("first.swift")
    for _ in 0..<400 where !(await slow.started) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await slow.started)
    model.select("second.swift")
    for _ in 0..<400 where model.presentation?.text.contains("new second.swift") != true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await slow.cancelled)
    #expect(model.presentation?.text.contains("new second.swift") == true)
}

private actor DelayedFirstSyntax: SyntaxProviding {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func highlights(for snapshot: TextSnapshot) async -> [SyntaxSpan] {
        if !started {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        return snapshot.text.utf16.count >= 3
            ? [SyntaxSpan(range: NSRange(location: 0, length: 3), kind: .keyword)] : []
    }
    func resume() {
        continuation?.resume()
        continuation = nil
    }
}

private struct LimitedSyntax: SyntaxProviding {
    func highlights(for snapshot: TextSnapshot) async -> [SyntaxSpan] { [] }
    func highlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights {
        SyntaxHighlights(spans: [], isLimited: true)
    }
}

@Test @MainActor func limitedSyntaxIsExposedToTheWorkspace() async throws {
    let folder = try TemporaryFolder()
    try "text\n".write(to: folder.url.appendingPathComponent("sample.ts"), atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: nil), syntax: LimitedSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(folder.url)
    model.select("sample.ts")
    for _ in 0..<300 where !model.syntaxLimited { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.syntaxLimited)
    #expect(model.presentation?.text == "text\n")
    model.select("sample.ts")
    #expect(model.syntaxLimited)
    #expect(model.presentation?.syntaxLimited == true)
}

@Test @MainActor func sameVersionRefreshRestartsInterruptedDiffHighlighting() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "old value\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "sample.swift"])
    try fixture.run(["commit", "-m", "base"])
    try "new value\n".write(to: file, atomically: true, encoding: .utf8)
    let syntax = DelayedFirstSyntax()
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: syntax, diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<400 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    model.select("sample.swift")
    for _ in 0..<400 where !(await syntax.started) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await syntax.started)
    #expect(model.presentation?.diff != nil)
    #expect(model.presentation?.syntax.isEmpty == true)
    model.refresh(immediate: true)
    await syntax.resume()
    for _ in 0..<400 where model.presentation?.syntax.isEmpty != false {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.syntax.isEmpty == false)
    #expect(model.presentation?.text.contains("new value") == true)
}

@Test @MainActor func newerFileEventRejectsTheOlderSyntaxPublication() async throws {
    let folder = try TemporaryFolder()
    let file = folder.url.appendingPathComponent("sample.txt")
    try "old\n".write(to: file, atomically: true, encoding: .utf8)
    let syntax = DelayedFirstSyntax()
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: nil), syntax: syntax, diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(folder.url)
    model.select("sample.txt")
    for _ in 0..<200 where !(await syntax.started) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await syntax.started)
    var publications: [String] = []
    let subscription = model.$presentation.sink { value in
        if let text = value?.text { publications.append(text) }
    }
    defer { subscription.cancel() }
    try "new\n".write(to: file, atomically: true, encoding: .utf8)
    model.refresh(immediate: true)
    publications.removeAll()
    for _ in 0..<200 where model.presentation?.text != "new\n" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text == "new\n")
    await syntax.resume()
    try await Task.sleep(for: .milliseconds(50))
    #expect(!publications.contains("old\n"))
}

@Test @MainActor func closingWindowDoesNotWaitForAnUnresponsiveSyntaxProvider() async throws {
    let folder = try TemporaryFolder()
    try "old\n".write(
        to: folder.url.appendingPathComponent("sample.txt"), atomically: true, encoding: .utf8)
    let syntax = DelayedFirstSyntax()
    var model: WorkspaceModel? = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: nil), syntax: syntax, diff: LineDiff(),
        observer: FileWatchHub())
    weak var weakModel = model
    await model?.open(folder.url)
    model?.select("sample.txt")
    for _ in 0..<300 where !(await syntax.started) || model?.isUpdating == true {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await syntax.started)
    model?.close()
    model = nil
    for _ in 0..<100 where weakModel != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(weakModel == nil, "A suspended refinement must not retain a closed window")
    await syntax.resume()
}

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

@Test func gitSpecialPathsKeepDistinctBaselinesAndHistory() async throws {
    let fixture = try GitFixture()
    let folder = fixture.folder.url.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let paths = ["file[1].txt", "file1.txt", ":(glob)other*.txt", "line\nbreak.txt"]
    for (index, path) in paths.enumerated() {
        try "baseline \(index)\n".write(
            to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    try fixture.run(["add", "src"])
    try fixture.run(["commit", "-m", "special paths"])
    for path in paths {
        try "changed\n".write(to: folder.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let listing = try await workspace.changes(in: folder)
    #expect(Set(listing.files.map(\.path)) == Set(paths))
    #expect(!listing.isLimited)
    for (index, path) in paths.enumerated() {
        let input = try await workspace.baseline(in: folder, path: path, workingText: "changed\n")
        #expect(input.before == "baseline \(index)\n")
        #expect(input.revision == listing.revision)
        let history = try await workspace.history(in: folder, path: path)
        #expect(history.first?.subject == "special paths")
    }
}

@Test func missingBaselineObjectIsReportedAsUnavailable() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("missing.swift")
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    let object = String(decoding: try fixture.runCapture(["rev-parse", "HEAD:missing.swift"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let looseObject = fixture.folder.url.appendingPathComponent(".git/objects")
        .appendingPathComponent(String(object.prefix(2))).appendingPathComponent(String(object.dropFirst(2)))
    try FileManager.default.removeItem(at: looseObject)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    do {
        _ = try await workspace.baseline(
            in: fixture.folder.url, path: "missing.swift", workingText: "changed")
        Issue.record("A missing baseline object must fail")
    } catch let failure as WorkspaceFailure {
        guard case .unavailable = failure else {
            Issue.record("A missing object must not be reported as an oversized file")
            return
        }
    }
}

@Test @MainActor func promisorMissingObjectDoesNotTriggerLazyFetch() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("missing.swift")
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    let object = String(decoding: try fixture.runCapture(["rev-parse", "HEAD:missing.swift"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let remoteFolder = try TemporaryFolder()
    let remote = remoteFolder.url.appendingPathComponent("remote.git")
    let marker = remoteFolder.url.appendingPathComponent("fetch-invoked")
    let upload = remoteFolder.url.appendingPathComponent("upload-pack")
    let localOnlyGit = remoteFolder.url.appendingPathComponent("local-only-git")
    try fixture.run(["clone", "--bare", "-q", fixture.folder.url.path, remote.path])
    let gitPath = fixture.git.path.replacingOccurrences(of: "'", with: "'\\''")
    let markerPath = marker.path.replacingOccurrences(of: "'", with: "'\\''")
    try "#!/bin/sh\nprintf x > '\(markerPath)'\nexec '\(gitPath)' upload-pack \"$@\"\n".write(
        to: upload, atomically: true, encoding: .utf8)
    try
        "#!/bin/sh\nexport GIT_ALLOW_PROTOCOL=file GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1\nexec '\(gitPath)' \"$@\"\n"
        .write(
            to: localOnlyGit, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: upload.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: localOnlyGit.path)
    try fixture.run(["config", "remote.origin.url", remote.absoluteString])
    try fixture.run(["config", "remote.origin.promisor", "true"])
    try fixture.run(["config", "remote.origin.partialclonefilter", "blob:none"])
    try fixture.run(["config", "remote.origin.uploadpack", upload.path])
    try fixture.run(["config", "extensions.partialClone", "origin"])
    try fixture.run(["config", "protocol.file.allow", "always"])
    let loose = fixture.folder.url.appendingPathComponent(".git/objects")
        .appendingPathComponent(String(object.prefix(2))).appendingPathComponent(String(object.dropFirst(2)))
    try FileManager.default.removeItem(at: loose)
    try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)

    let workspace = LocalWorkspace(gitExecutable: localOnlyGit)
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.select("missing.swift")
    for _ in 0..<500 where model.changesIndicator != .unavailable || model.presentation == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text == "let value = 2\n")
    #expect(model.monitoringAvailable)
    #expect(model.changesError != nil)
    #expect(model.changesIndicator == .unavailable)
    #expect(model.changedFiles.isEmpty)
    do {
        _ = try await workspace.changes(in: fixture.folder.url)
        Issue.record("A changes scan with a missing promised object must fail explicitly")
    } catch let failure as WorkspaceFailure {
        guard case .unavailable = failure else {
            Issue.record("A missing promised object must not be reported as no changes")
            return
        }
    }
    do {
        _ = try await workspace.baseline(
            in: fixture.folder.url, path: "missing.swift", workingText: "changed\n")
        Issue.record("A promised but missing baseline must not be read as available")
    } catch let failure as WorkspaceFailure {
        guard case .unavailable = failure else {
            Issue.record("A missing promised object must be explicitly unavailable")
            return
        }
    }
    let offline = try await GitRunner(executable: localOnlyGit).run(
        ["cat-file", "-e", object], at: fixture.folder.url)
    #expect(offline.status != 0)
    #expect(!FileManager.default.fileExists(atPath: marker.path))
    model.setDiff(true)
    #expect(!model.canReview && model.presentation == nil)
    model.setDiff(false)
    for _ in 0..<500 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.isRefreshingFiles)
    #expect(!FileManager.default.fileExists(atPath: marker.path))

    // Positive control: plain Git is allowed to fetch only from this temporary local repository.
    try fixture.run(["cat-file", "-s", object])
    #expect(FileManager.default.fileExists(atPath: marker.path))
    let recovered = try await workspace.baseline(
        in: fixture.folder.url, path: "missing.swift", workingText: "changed\n")
    #expect(recovered.before == "let value = 1\n")
    model.refreshFiles(immediate: true)
    for _ in 0..<500 where model.changesIndicator != .count(1) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changesIndicator == .count(1))
}

@Test func changedFileScanRejectsHeadMovedDuringGitCommands() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("tracked.swift")
    try "first\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "first"])
    try "second\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["commit", "-am", "second"])
    let next = String(decoding: try fixture.runCapture(["rev-parse", "HEAD"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try fixture.run(["reset", "--hard", "HEAD~1"])
    let git = fixture.git.path.replacingOccurrences(of: "'", with: "'\\''")
    let wrapper = fixture.folder.url.appendingPathComponent("git-wrapper")
    let script = """
        #!/bin/sh
        '\(git)' "$@"
        result=$?
        for arg do
          if [ "$arg" = "--raw" ]; then
            '\(git)' update-ref HEAD '\(next)'
          fi
        done
        exit "$result"
        """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    let workspace = LocalWorkspace(
        gitExecutable: wrapper, environment: ProcessInfo.processInfo.environment,
        gitTimeoutNanoseconds: 15_000_000_000)
    do {
        _ = try await workspace.changes(in: fixture.folder.url)
        Issue.record("A changes scan must reject a HEAD change during its Git commands")
    } catch let failure as WorkspaceFailure {
        guard case .unavailable(let reason) = failure else {
            Issue.record("A changing HEAD must produce an explicit unavailable result")
            return
        }
        #expect(reason == "HEAD changed during the scan. Reload to retry.")
    }
}

@Test @MainActor func unbornRepositoryComparesNewFilesAndTransitionsAfterFirstCommit() async throws {
    let fixture = try GitFixture()
    let folder = fixture.folder.url.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let staged = folder.appendingPathComponent("staged.swift")
    let deleted = folder.appendingPathComponent("deleted.swift")
    let untracked = folder.appendingPathComponent("new.swift")
    try "let a = 1\n".write(to: staged, atomically: true, encoding: .utf8)
    try "removed\n".write(to: deleted, atomically: true, encoding: .utf8)
    try fixture.run(["add", "src"])
    try FileManager.default.removeItem(at: deleted)
    try "let b = 2\n".write(to: untracked, atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let listing = try await workspace.changes(in: folder)
    #expect(listing.files.first(where: { $0.path == "staged.swift" })?.changeKind == .added)
    #expect(listing.files.first(where: { $0.path == "new.swift" })?.changeKind == .untracked)
    #expect(!listing.files.contains { $0.path == "deleted.swift" })
    let comparison = try await workspace.baseline(
        in: folder, path: "staged.swift", workingText: "let a = 1\n")
    #expect(comparison.before.isEmpty)
    #expect(comparison.revision == listing.revision)
    #expect(try await workspace.history(in: folder, path: "staged.swift").isEmpty)
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(folder)
    model.setDiff(true)
    model.select("staged.swift")
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    #expect(model.isInitialComparison)
    #expect(model.presentation?.diff?.added == 1)
    model.markReviewed()
    try fixture.run(["add", "-u"])
    try fixture.run(["commit", "-m", "first commit"])
    try "let a = 2\n".write(to: staged, atomically: true, encoding: .utf8)
    for _ in 0..<800 where model.isInitialComparison || !model.canReview {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!model.isInitialComparison)
    #expect(model.canReview)
    #expect(!model.reviewed)
    #expect(model.presentation?.text.contains("let a = 1") == true)
    #expect(model.presentation?.text.contains("let a = 2") == true)
    for _ in 0..<400 where model.history.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.history.first?.subject == "first commit")
}

@Test func invalidHeadRefCannotBeTreatedAsAnUnbornRepository() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("file.swift")
    try "value\n".write(to: file, atomically: true, encoding: .utf8)
    let reference = String(decoding: try fixture.runCapture(["symbolic-ref", "HEAD"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let refFile = fixture.folder.url.appendingPathComponent(".git").appendingPathComponent(reference)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    for invalid in ["not-a-ref\n", String(repeating: "1", count: 40) + "\n"] {
        try invalid.write(to: refFile, atomically: true, encoding: .utf8)
        await #expect(throws: WorkspaceFailure.self) { try await workspace.changes(in: fixture.folder.url) }
        await #expect(throws: WorkspaceFailure.self) {
            try await workspace.baseline(in: fixture.folder.url, path: "file.swift", workingText: "value\n")
        }
    }
    var invalidHead = Data("ref: refs/heads/".utf8)
    invalidHead.append(contentsOf: [0xff, 0x0a])
    try invalidHead.write(to: fixture.folder.url.appendingPathComponent(".git/HEAD"), options: .atomic)
    await #expect(throws: WorkspaceFailure.self) { try await workspace.changes(in: fixture.folder.url) }
    try "ref: refs/heads/bad..name\n".write(
        to: fixture.folder.url.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)
    await #expect(throws: WorkspaceFailure.self) { try await workspace.changes(in: fixture.folder.url) }
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

@Test @MainActor func gitEventBurstConvergesAcrossFiveWindows() async throws {
    let fixture = try GitFixture()
    let root = fixture.folder.url
    try "baseline\n".write(to: root.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let hub = FileWatchHub()
    let parser = TreeSyntax()
    let diff = LineDiff()
    let models = (0..<5).map { _ in
        WorkspaceModel(workspace: workspace, syntax: parser, diff: diff, observer: hub)
    }
    defer { for model in models { model.close() } }
    for model in models {
        model.setVisible(true)
        await model.open(root)
    }
    for _ in 0..<1_000 where models.contains(where: { $0.changesIndicator != .clean }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(models.allSatisfy { $0.changesIndicator == .clean })
    let expected = Set((0..<60).map { "burst-\($0).txt" })
    for path in expected {
        try "new\n".write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }
    for _ in 0..<1_000 where models.contains(where: { Set($0.changedFiles.map(\.path)) != expected }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(models.allSatisfy { Set($0.changedFiles.map(\.path)) == expected })
    #expect(models.allSatisfy { $0.changesIndicator == .count(expected.count) })
    for path in expected { try FileManager.default.removeItem(at: root.appendingPathComponent(path)) }
    for _ in 0..<1_000 where models.contains(where: { $0.changesIndicator != .clean }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(models.allSatisfy { $0.changesIndicator == .clean && $0.changedFiles.isEmpty })
}

@Test func gitOutputBudgetRejectsTruncation() async throws {
    let fixture = try GitFixture()
    let runner = GitRunner(executable: fixture.git)
    await #expect(throws: WorkspaceFailure.self) {
        try await runner.run(["--version"], at: fixture.folder.url, limit: 1)
    }
}

@Test @MainActor func executableBitOnlyChangeCannotBeReviewedAsAnEmptyDiff() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("script.sh")
    try "echo hello\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "script.sh"])
    try fixture.run(["commit", "-m", "base"])
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<400 where model.changedFiles.first?.path != "script.sh" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.first?.changeKind == .modified)
    model.select("script.sh")
    for _ in 0..<400 where model.isUpdating || (model.presentation == nil && model.error == nil) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.error != nil)
    #expect(!model.canReview)
    model.markReviewed()
    #expect(!model.reviewed)
    try "echo changed\n".write(to: file, atomically: false, encoding: .utf8)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where model.isRefreshingFiles || model.isUpdating {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.first?.hasModeChange == true)
    #expect(model.error != nil)
    #expect(!model.canReview)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changedFiles.first?.hasModeChange == false)
    #expect(model.error == nil)
    #expect(model.canReview)
}

@Test @MainActor func changedSymlinkIsExplicitlyUnavailableForReview() async throws {
    let fixture = try GitFixture()
    let link = fixture.folder.url.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "first.txt")
    try fixture.run(["add", "link.txt"])
    try fixture.run(["commit", "-m", "base"])
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "second.txt")
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<400 where model.changedFiles.first?.path != "link.txt" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.first?.hasUnsupportedGitType == true)
    model.select("link.txt")
    for _ in 0..<400 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error?.contains("Symbolic links and submodules") == true)
    #expect(model.presentation == nil)
    #expect(!model.canReview)
}

@Test func initialRepositoryRetainsStagedSymlinkType() async throws {
    let fixture = try GitFixture()
    let link = fixture.folder.url.appendingPathComponent("link.txt")
    try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "missing.txt")
    try fixture.run(["add", "link.txt"])
    let listing = try await LocalWorkspace(gitExecutable: fixture.git).changes(in: fixture.folder.url)
    #expect(!listing.isLimited)
    #expect(listing.files.first?.changeKind == .added)
    #expect(listing.files.first?.hasUnsupportedGitType == true)
}

@Test @MainActor func fileTypeChangeAndUntrackedLinkAreNotReviewedAsText() async throws {
    let fixture = try GitFixture()
    let changed = fixture.folder.url.appendingPathComponent("changed.txt")
    let untracked = fixture.folder.url.appendingPathComponent("untracked.txt")
    try "base\n".write(to: changed, atomically: true, encoding: .utf8)
    try fixture.run(["add", "changed.txt"])
    try fixture.run(["commit", "-m", "base"])
    try FileManager.default.removeItem(at: changed)
    try FileManager.default.createSymbolicLink(atPath: changed.path, withDestinationPath: "target.txt")
    try FileManager.default.createSymbolicLink(atPath: untracked.path, withDestinationPath: "target.txt")
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<400 where model.changedFiles.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changedFiles.first(where: { $0.path == "changed.txt" })?.hasUnsupportedGitType == true)
    model.select("changed.txt")
    for _ in 0..<400 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error?.contains("Symbolic links and submodules") == true)
    #expect(!model.canReview)
    model.select("untracked.txt")
    for _ in 0..<400 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error?.contains("Symbolic links cannot be opened") == true)
    #expect(!model.canReview)
    try FileManager.default.removeItem(at: changed)
    try "modified\n".write(to: changed, atomically: true, encoding: .utf8)
    model.refreshFiles(immediate: true)
    model.select("changed.txt")
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.presentation?.diff?.added == 1)
    #expect(model.presentation?.diff?.removed == 1)
    #expect(model.canReview)
}

@Test func workspaceReadsCannotFollowParentSymlinksOrEscapeRoot() async throws {
    let folder = try TemporaryFolder()
    let outside = try TemporaryFolder()
    let directory = folder.url.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "inside\n".write(to: directory.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try "outside\n".write(
        to: outside.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: nil)
    let root = folder.url.resolvingSymlinksInPath()
    let initial = try await workspace.read(in: root, path: "nested/file.txt", allowMissing: false)
    #expect(initial.text == "inside\n")
    try FileManager.default.removeItem(at: directory)
    try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: outside.url)
    await #expect(throws: (any Error).self) {
        try await workspace.read(in: root, path: "nested/file.txt", allowMissing: false)
    }
    await #expect(throws: (any Error).self) {
        try await workspace.read(in: root, path: "nested/file.txt", allowMissing: true)
    }
    await #expect(throws: (any Error).self) {
        try await workspace.read(in: root, path: "../file.txt", allowMissing: false)
    }
    try FileManager.default.removeItem(at: folder.url)
    await #expect(throws: (any Error).self) {
        try await workspace.read(in: root, path: "nested/file.txt", allowMissing: true)
    }
}

@Test @MainActor func dirtySubmoduleIsExplicitlyUnavailableForReview() async throws {
    let dependency = try GitFixture()
    try "base\n".write(
        to: dependency.folder.url.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
    try dependency.run(["add", "file.txt"])
    try dependency.run(["commit", "-m", "base"])
    let fixture = try GitFixture()
    try fixture.run([
        "-c", "protocol.file.allow=always", "submodule", "add", dependency.folder.url.path, "dependency",
    ])
    try fixture.run(["commit", "-m", "add submodule"])
    try "changed\n".write(
        to: fixture.folder.url.appendingPathComponent("dependency/file.txt"),
        atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<400 where !model.changedFiles.contains(where: { $0.path == "dependency" }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.first(where: { $0.path == "dependency" })?.hasUnsupportedGitType == true)
    model.select("dependency")
    for _ in 0..<400 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error?.contains("Symbolic links and submodules") == true)
    #expect(model.presentation == nil)
    #expect(!model.canReview)
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
    func runInput(_ arguments: [String], data: Data) throws {
        let process = Process()
        process.executableURL = git
        process.arguments = arguments
        process.currentDirectoryURL = folder.url
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["GIT_CONFIG_NOSYSTEM"] = "1"
        environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
        process.environment = environment
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
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
    let status = Data(":100644 100644 0 0 M\0conflict.swift\0".utf8)
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
    #expect(model.error != nil)
    #expect(model.presentation == nil)
    #expect(!model.canReview)
    model.markReviewed()
    #expect(!model.reviewed)
    try "let value = 3\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "conflict.swift"])
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changedFiles.first?.changeKind == .modified)
    #expect(model.error == nil)
    #expect(model.presentation?.text.contains("let value = 3") == true)
    #expect(model.canReview)
}

@Test @MainActor func conflictTransitionsConvergeAcrossTwoWindows() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("conflict.swift")
    try "base\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    let branchOutput = try fixture.runCapture(["branch", "--show-current"])
    let originalBranch = String(decoding: branchOutput, as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try fixture.run(["branch", "side"])
    try "main\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["commit", "-am", "main"])
    try fixture.run(["checkout", "side"])
    try "side\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["commit", "-am", "side"])
    try "side with local edit\n".write(to: file, atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let observer = FileWatchHub()
    let previews = PreviewCache()
    let models = (0..<2).map { _ in
        WorkspaceModel(
            workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer,
            previews: previews)
    }
    defer { for model in models { model.close() } }
    for model in models {
        await model.open(fixture.folder.url)
        model.setDiff(true)
        model.select("conflict.swift")
    }
    for _ in 0..<600 where models.contains(where: { !$0.canReview }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(models.allSatisfy { $0.canReview })
    for model in models { model.markReviewed() }
    #expect(models.allSatisfy { $0.reviewed })
    try fixture.run(["checkout", "--", "conflict.swift"])
    #expect(fixture.runAllowingFailure(["merge", originalBranch]) != 0)
    for _ in 0..<800
    where models.contains(where: { $0.changedFiles.first?.changeKind != .conflicted || $0.error == nil }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(models.allSatisfy { $0.changedFiles.first?.changeKind == .conflicted })
    #expect(models.allSatisfy { !$0.reviewed && !$0.canReview && $0.presentation == nil && $0.error != nil })
    try "resolved\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "conflict.swift"])
    for _ in 0..<800 where models.contains(where: { !$0.canReview }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(models.allSatisfy { $0.canReview && !$0.reviewed && $0.error == nil })
    #expect(models.allSatisfy { $0.presentation?.text.contains("resolved") == true })
}

@Test @MainActor func reviewRequiresACompletedSuccessfulChangesScan() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("review.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("review.swift")
    for _ in 0..<300 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    #expect(model.reviewed)

    try fixture.run(["config", "filter.example.clean", "cat"])
    model.refreshFiles(immediate: true)
    #expect(!model.canReview)
    #expect(!model.reviewed)
    for _ in 0..<300 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError != nil)
    for _ in 0..<300 where model.presentation != nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.presentation == nil)
    #expect(!model.canReview)
    model.markReviewed()
    #expect(!model.reviewed)
    model.select("review.swift")
    #expect(model.presentation == nil)

    try fixture.run(["config", "--unset", "filter.example.clean"])
    model.refreshFiles(immediate: true)
    for _ in 0..<300 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError == nil)
    #expect(model.canReview)
    #expect(model.presentation?.diff != nil)
}

@Test @MainActor func changesIndicatorUpdatesInFilesAndPreservesReadingOnScanFailure() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    model.setVisible(false)
    await model.open(fixture.folder.url)
    for _ in 0..<500 where model.changesIndicator != .clean { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesIndicator == .clean, "The initial changes scan must run even if occluded")
    model.setVisible(true)
    model.select("sample.swift")
    for _ in 0..<500 where model.changesIndicator != .clean { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!model.showsDiff)
    #expect(model.changesIndicator == .clean)
    let newFile = fixture.folder.url.appendingPathComponent("new.swift")
    try "new\n".write(to: newFile, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.changesIndicator != .count(1) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changesIndicator == .count(1))
    model.refreshFiles(immediate: true)
    #expect(model.changesIndicator == .checking)
    #expect(WorkspaceView(model: model).changesBadge == "1")
    for _ in 0..<500 where model.changesIndicator != .count(1) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changesIndicator == .count(1))
    try fixture.run(["config", "filter.example.clean", "cat"])
    model.refreshFiles(immediate: true)
    for _ in 0..<500 where model.changesIndicator != .unavailable {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changesIndicator == .unavailable)
    #expect(WorkspaceView(model: model).changesBadge == "!")
    #expect(model.changedFiles.isEmpty)
    #expect(model.presentation?.text == "let value = 1\n")
    try fixture.run(["config", "--unset", "filter.example.clean"])
    model.refreshFiles(immediate: true)
    for _ in 0..<500 where model.changesIndicator != .count(1) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changesIndicator == .count(1))
    try FileManager.default.removeItem(at: newFile)
    for _ in 0..<500 where model.changesIndicator != .clean { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesIndicator == .clean)
    model.close()
    #expect(model.changesIndicator == .hidden)
}

private actor CountingInitialFilesWorkspace: WorkspaceReading {
    private(set) var filesCalls = 0
    func files(in root: URL) async throws -> FileListing {
        filesCalls += 1
        return FileListing(files: [], isLimited: false, usesGitIgnore: true)
    }
    func changes(in root: URL) async throws -> FileListing {
        FileListing(files: [], isLimited: false, usesGitIgnore: true, revision: "fixed")
    }
    func read(_ url: URL) async throws -> TextSnapshot { TextSnapshot(url: url, version: 1, text: "") }
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD", revision: "fixed")
    }
}

@MainActor private final class ActiveTestLease: ObservationLease {
    var isActive = true
    func cancel() { isActive = false }
}

@MainActor private final class ActiveTestObserver: FileObserving {
    func observe(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> any ObservationLease {
        ActiveTestLease()
    }
}

private actor ChangingObservationPathsWorkspace: WorkspaceReading {
    let first: URL
    let second: URL
    let keepsChanging: Bool
    private var calls = 0
    init(first: URL, second: URL, keepsChanging: Bool = false) {
        self.first = first
        self.second = second
        self.keepsChanging = keepsChanging
    }
    func repositoryObservationFiles(in root: URL) async throws -> [URL] {
        calls += 1
        return calls == 1 || (keepsChanging && calls.isMultiple(of: 2) == false) ? [first] : [second]
    }
    func files(in root: URL) async throws -> FileListing {
        FileListing(files: [], isLimited: false, usesGitIgnore: true)
    }
    func read(_ url: URL) async throws -> TextSnapshot { TextSnapshot(url: url, version: 1, text: "") }
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD")
    }
}

@MainActor private final class RecordingObservationPaths: FileObserving {
    var paths: [URL] = []
    func observe(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> any ObservationLease {
        paths.append(url)
        return ActiveTestLease()
    }
}

@Test @MainActor func observationPathsAreRecheckedAfterInstallingWatchers() async throws {
    let folder = try TemporaryFolder()
    let first = folder.url.appendingPathComponent("first")
    let second = folder.url.appendingPathComponent("second")
    let workspace = ChangingObservationPathsWorkspace(first: first, second: second)
    let observer = RecordingObservationPaths()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer)
    defer { model.close() }
    await model.open(folder.url)
    #expect(observer.paths.contains(first))
    #expect(observer.paths.contains(second))
    #expect(model.error == nil)
}

@Test @MainActor func unstableObservationPathsFailExplicitly() async throws {
    let folder = try TemporaryFolder()
    let workspace = ChangingObservationPathsWorkspace(
        first: folder.url.appendingPathComponent("first"),
        second: folder.url.appendingPathComponent("second"), keepsChanging: true)
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: RecordingObservationPaths())
    defer { model.close() }
    await model.open(folder.url)
    #expect(model.error != nil)
    #expect(!model.canReview)
}

@MainActor private final class MutatingObservationPaths: FileObserving {
    let hub = FileWatchHub()
    let trigger: URL
    let content: String
    var attempted = false
    var failure: (any Error)?
    init(trigger: URL, content: String) {
        self.trigger = trigger.resolvingSymlinksInPath().standardizedFileURL
        self.content = content
    }
    func observeWorkspace(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) async
        -> any ObservationLease
    {
        await hub.observeWorkspace(url, onChange: onChange)
    }
    func observe(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> any ObservationLease {
        if !attempted && url.resolvingSymlinksInPath().standardizedFileURL == trigger {
            attempted = true
            do { try content.write(to: trigger, atomically: true, encoding: .utf8) } catch { failure = error }
        }
        return hub.observe(url, onChange: onChange)
    }
}

@Test @MainActor func realGitIncludeAddedBeforeWatcherInstallationIsObserved() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let first = external.url.appendingPathComponent("first-config")
    let second = external.url.appendingPathComponent("second-config")
    try "[example]\n value = initial\n".write(to: first, atomically: true, encoding: .utf8)
    try "[example]\n value = initial\n".write(to: second, atomically: true, encoding: .utf8)
    try fixture.run(["config", "include.path", first.path])
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let observer = MutatingObservationPaths(trigger: first, content: "[include]\n path = second-config\n")
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: observer)
    defer { model.close() }
    await model.open(fixture.folder.url)
    for _ in 0..<1_000 where !observer.attempted { try await Task.sleep(for: .milliseconds(10)) }
    #expect(observer.attempted && observer.failure == nil)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try "[filter \"custom\"]\n clean = cat\n".write(to: second, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.changesError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError != nil && !model.reviewed && !model.canReview)
}

@Test @MainActor func initialChangesScanReusesInitialFileListing() async throws {
    let folder = try TemporaryFolder()
    let workspace = CountingInitialFilesWorkspace()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: ActiveTestObserver())
    defer { model.close() }
    await model.open(folder.url)
    for _ in 0..<400 where model.changesIndicator != .clean { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesIndicator == .clean)
    #expect(await workspace.filesCalls == 1)
}

private actor DelayedInitialChangesWorkspace: WorkspaceReading {
    private(set) var firstStarted = false
    private var releaseFirst: CheckedContinuation<Void, Never>?
    func files(in root: URL) async throws -> FileListing {
        FileListing(files: [], isLimited: false, usesGitIgnore: true)
    }
    func changes(in root: URL) async throws -> FileListing {
        if !firstStarted {
            firstStarted = true
            await withCheckedContinuation { releaseFirst = $0 }
            return FileListing(
                files: [ProjectFile(path: "old.swift", changeKind: .modified)],
                isLimited: false, usesGitIgnore: true, revision: "old")
        }
        return FileListing(
            files: [ProjectFile(path: "new.swift", changeKind: .modified)],
            isLimited: false, usesGitIgnore: true, revision: "new")
    }
    func release() {
        releaseFirst?.resume()
        releaseFirst = nil
    }
    func read(_ url: URL) async throws -> TextSnapshot { TextSnapshot(url: url, version: 1, text: "") }
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD", revision: "new")
    }
}

@Test @MainActor func newerEventRejectsStaleInitialChangesIndicator() async throws {
    let folder = try TemporaryFolder()
    let workspace = DelayedInitialChangesWorkspace()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: ActiveTestObserver())
    defer { model.close() }
    var publishedStale = false
    let observer = model.$changedFiles.sink { files in
        if files.contains(where: { $0.path == "old.swift" }) { publishedStale = true }
    }
    defer { observer.cancel() }
    await model.open(folder.url)
    for _ in 0..<400 where !(await workspace.firstStarted) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.firstStarted)
    model.refreshFiles(immediate: true)
    await workspace.release()
    for _ in 0..<400 where model.changesIndicator != .count(1) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.map(\.path) == ["new.swift"])
    #expect(!publishedStale)
}

private actor FailingListingWorkspace: WorkspaceReading {
    private let base: LocalWorkspace
    private var shouldFail = false
    private var incompleteChanges = false
    init(git: URL) { base = LocalWorkspace(gitExecutable: git) }
    func setFail(_ value: Bool) { shouldFail = value }
    func setIncompleteChanges(_ value: Bool) { incompleteChanges = value }
    func files(in root: URL) async throws -> FileListing {
        if shouldFail { throw WorkspaceFailure.unavailable("File listing failed.") }
        return try await base.files(in: root)
    }
    func changes(in root: URL) async throws -> FileListing {
        let result = try await base.changes(in: root)
        return FileListing(
            files: result.files, isLimited: result.isLimited || incompleteChanges,
            usesGitIgnore: result.usesGitIgnore, revision: result.revision)
    }
    func branch(in root: URL) async throws -> String { try await base.branch(in: root) }
    func repositoryObservationRoots(in root: URL) async throws -> [URL] {
        try await base.repositoryObservationRoots(in: root)
    }
    func read(_ url: URL) async throws -> TextSnapshot { try await base.read(url) }
    func read(in root: URL, path: String, allowMissing: Bool) async throws -> TextSnapshot {
        try await base.read(in: root, path: path, allowMissing: allowMissing)
    }
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput {
        try await base.baseline(in: root, path: path, workingText: workingText)
    }
}

@Test @MainActor func failedFileListingClearsComparisonUntilRecovery() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "old\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "sample.swift"])
    try fixture.run(["commit", "-m", "base"])
    try "new\n".write(to: file, atomically: true, encoding: .utf8)
    let workspace = FailingListingWorkspace(git: fixture.git)
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    await workspace.setFail(true)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where model.changesError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.presentation == nil)
    #expect(model.changedFiles.isEmpty)
    #expect(!model.reviewed && !model.canReview)
    await workspace.setFail(false)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError == nil)
    #expect(model.presentation?.diff != nil && model.canReview)
    model.markReviewed()
    await workspace.setIncompleteChanges(true)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where model.changesError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.presentation == nil)
    #expect(model.changedFiles.isEmpty)
    #expect(!model.reviewed && !model.canReview)
    model.select("sample.swift")
    #expect(model.presentation == nil)
    await workspace.setIncompleteChanges(false)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.presentation?.diff != nil && model.canReview)
}

@Test @MainActor func fileTreeProjectionChangesOnlyWhenListingChanges() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "old\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "sample.swift"])
    try fixture.run(["commit", "-m", "base"])
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    for _ in 0..<500 where !model.files.contains(where: { $0.path == "sample.swift" }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(model.files.contains { $0.path == "sample.swift" })
    model.select("sample.swift")
    let initialRevision = model.fileTreeRevision
    try "changed\n".write(to: file, atomically: true, encoding: .utf8)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.fileTreeRevision == initialRevision)
    for index in 0..<20 {
        try "version \(index)\n".write(to: file, atomically: true, encoding: .utf8)
    }
    for _ in 0..<600 where model.presentation?.text != "version 19\n" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.presentation?.text == "version 19\n")
    #expect(model.fileTreeRevision == initialRevision)
    try "new\n".write(
        to: fixture.folder.url.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !model.files.contains(where: { $0.path == "new.swift" }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.files.contains { $0.path == "new.swift" })
    #expect(model.fileTreeRevision != initialRevision)
}

private actor DelayedListingWorkspace: WorkspaceReading {
    private var filePaths = ["base.swift"]
    private var changePaths: [String] = []
    private var blockFiles = false
    private var blockChanges = false
    private(set) var waitingFiles = false
    private(set) var waitingChanges = false
    private var fileContinuation: CheckedContinuation<Void, Never>?
    private var changesContinuation: CheckedContinuation<Void, Never>?
    func prepareFiles(_ paths: [String]) {
        filePaths = paths
        blockFiles = true
    }
    func prepareChanges(_ paths: [String]) {
        changePaths = paths
        blockChanges = true
    }
    func setFiles(_ paths: [String]) { filePaths = paths }
    func setChanges(_ paths: [String]) { changePaths = paths }
    func releaseFiles() {
        fileContinuation?.resume()
        fileContinuation = nil
    }
    func releaseChanges() {
        changesContinuation?.resume()
        changesContinuation = nil
    }
    func files(in root: URL) async -> FileListing {
        let captured = filePaths
        if blockFiles {
            blockFiles = false
            waitingFiles = true
            await withCheckedContinuation { fileContinuation = $0 }
            waitingFiles = false
        }
        return FileListing(
            files: captured.map { ProjectFile(path: $0) }, isLimited: false, usesGitIgnore: true)
    }
    func changes(in root: URL) async -> FileListing {
        let captured = changePaths
        if blockChanges {
            blockChanges = false
            waitingChanges = true
            await withCheckedContinuation { changesContinuation = $0 }
            waitingChanges = false
        }
        return FileListing(
            files: captured.map { ProjectFile(path: $0, changeKind: .modified) }, isLimited: false,
            usesGitIgnore: true, revision: "revision")
    }
    func read(_ url: URL) -> TextSnapshot { TextSnapshot(url: url, version: 1, text: "") }
    func baseline(in root: URL, path: String, workingText: String) -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD", revision: "revision")
    }
}

private actor CancellableListingWorkspace: WorkspaceReading {
    private var blockedRoot: String?
    private var holdCancellation = false
    private var cancellationContinuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    private(set) var cancelled = false
    func blockNext(in root: URL) {
        blockedRoot = root.resolvingSymlinksInPath().path
        started = false
    }
    func setHoldCancellation(_ hold: Bool) { holdCancellation = hold }
    func releaseCancellation() {
        cancellationContinuation?.resume()
        cancellationContinuation = nil
    }
    func files(in root: URL) async throws -> FileListing {
        if blockedRoot == root.path {
            blockedRoot = nil
            started = true
            do {
                try await Task.sleep(for: .seconds(10))
            } catch {
                cancelled = true
                if holdCancellation { await withCheckedContinuation { cancellationContinuation = $0 } }
                throw error
            }
        }
        return FileListing(files: [ProjectFile(path: "file.swift")], isLimited: false, usesGitIgnore: false)
    }
    func read(_ url: URL) -> TextSnapshot { TextSnapshot(url: url, version: 1, text: "") }
    func baseline(in root: URL, path: String, workingText: String) -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD")
    }
}

@Test @MainActor func switchingProjectsCancelsOldListingWorker() async throws {
    let first = try TemporaryFolder()
    let second = try TemporaryFolder()
    let workspace = CancellableListingWorkspace()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(first.url)
    await workspace.setHoldCancellation(true)
    await workspace.blockNext(in: first.url)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !(await workspace.started) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.started)
    await model.open(second.url)
    for _ in 0..<1_000 where !(await workspace.cancelled) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.cancelled)
    #expect(model.root?.path == second.url.resolvingSymlinksInPath().path)
    #expect(!model.isRefreshingFiles)
    #expect(model.files.first?.path == "file.swift")
    await workspace.blockNext(in: second.url)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !(await workspace.started) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.started)
    await workspace.releaseCancellation()
    try await Task.sleep(for: .milliseconds(50))
    #expect(model.isRefreshingFiles)
    await workspace.setHoldCancellation(false)
}

@Test @MainActor func newerEventsRejectInFlightFileAndChangesListings() async throws {
    let folder = try TemporaryFolder()
    let workspace = DelayedListingWorkspace()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(folder.url)
    model.setDiff(true)
    for _ in 0..<400 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    var publishedStaleFiles = false
    var publishedStaleChanges = false
    let filesSubscription = model.$files.sink { files in
        if files.contains(where: { $0.path == "stale.swift" }) { publishedStaleFiles = true }
    }
    let changesSubscription = model.$changedFiles.sink { files in
        if files.contains(where: { $0.path == "stale.swift" }) { publishedStaleChanges = true }
    }
    defer {
        filesSubscription.cancel()
        changesSubscription.cancel()
    }
    await workspace.prepareFiles(["stale.swift"])
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !(await workspace.waitingFiles) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.waitingFiles)
    await workspace.setFiles(["latest.swift"])
    model.refreshFiles(immediate: true)
    await workspace.releaseFiles()
    for _ in 0..<400 where model.files.first?.path != "latest.swift" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!publishedStaleFiles)
    #expect(model.files.first?.path == "latest.swift")

    await workspace.prepareChanges(["stale.swift"])
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !(await workspace.waitingChanges) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.waitingChanges)
    await workspace.setChanges(["latest.swift"])
    model.refreshFiles(immediate: true)
    await workspace.releaseChanges()
    for _ in 0..<400 where model.changedFiles.first?.path != "latest.swift" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(!publishedStaleChanges)
    #expect(model.changedFiles.first?.path == "latest.swift")
}

@Test @MainActor func newerEventRejectsTheInitialOpenListing() async throws {
    let folder = try TemporaryFolder()
    let workspace = DelayedListingWorkspace()
    await workspace.prepareFiles(["stale.swift"])
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    var publishedStale = false
    let subscription = model.$files.sink { files in
        if files.contains(where: { $0.path == "stale.swift" }) { publishedStale = true }
    }
    defer { subscription.cancel() }
    let opening = Task { await model.open(folder.url) }
    for _ in 0..<400 where !(await workspace.waitingFiles) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.waitingFiles)
    await workspace.setFiles(["latest.swift"])
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where model.files.first?.path != "latest.swift" {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.files.first?.path == "latest.swift")
    await workspace.releaseFiles()
    await opening.value
    #expect(!publishedStale)
    #expect(model.files.first?.path == "latest.swift")
}

@Test func simultaneousPolicyDiscoverySharesWorkAndCancellation() async throws {
    let fixture = try GitFixture()
    let control = try TemporaryFolder()
    let wrapper = control.url.appendingPathComponent("git-wrapper")
    let log = control.url.appendingPathComponent("calls")
    let gate = control.url.appendingPathComponent("release")
    defer { try? Data().write(to: gate) }
    let gitPath = fixture.git.path.replacingOccurrences(of: "'", with: "'\\''")
    let logPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
    let gatePath = gate.path.replacingOccurrences(of: "'", with: "'\\''")
    let script = """
        #!/bin/sh
        for arg do
          if [ "$arg" = "--name-only" ]; then
            printf 'discovery\\n' >> '\(logPath)'
            while [ ! -f '\(gatePath)' ]; do sleep 0.05; done
            break
          fi
        done
        exec '\(gitPath)' "$@"
        """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    // This fixture deliberately blocks Git while asserting subscriber behavior.
    // Production GitRunner keeps its independent three-second limit.
    let workspace = LocalWorkspace(
        gitExecutable: wrapper, environment: ProcessInfo.processInfo.environment,
        gitTimeoutNanoseconds: 15_000_000_000)
    let root = fixture.folder.url
    func count() -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    let first = Task { try await workspace.repositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where count() == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 1)
    let second = Task { try await workspace.repositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where await workspace.activeObservationSubscribers < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await workspace.activeObservationSubscribers == 2)
    #expect(count() == 1)
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    try Data().write(to: gate)
    let result = try await second.value
    #expect(!result.isEmpty)
    #expect(count() == 1)
    try FileManager.default.removeItem(at: gate)
    let old = Task { try await workspace.repositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where count() < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 2)
    workspace.invalidateRepositoryScans(in: root)
    let fresh = Task { try await workspace.repositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where count() < 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 3)
    try Data().write(to: gate)
    _ = try await old.value
    _ = try await fresh.value
    #expect(await workspace.activeObservationSubscribers == 0)
    try FileManager.default.removeItem(at: gate)
    let last = Task { try await workspace.repositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where count() < 4 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 4)
    last.cancel()
    await #expect(throws: CancellationError.self) { try await last.value }
    #expect(await workspace.activeObservationSubscribers == 0)
    try Data().write(to: gate)
}

@Test func revalidationSharesOnlyBeforeScanningAndCancelsIndependently() async throws {
    let fixture = try GitFixture()
    let control = try TemporaryFolder()
    let wrapper = control.url.appendingPathComponent("git-wrapper")
    let log = control.url.appendingPathComponent("calls")
    let gate = control.url.appendingPathComponent("release")
    defer { try? Data().write(to: gate) }
    let gitPath = fixture.git.path.replacingOccurrences(of: "'", with: "'\\''")
    let logPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
    let gatePath = gate.path.replacingOccurrences(of: "'", with: "'\\''")
    let script = """
        #!/bin/sh
        for arg do
          if [ "$arg" = "--name-only" ]; then
            printf 'discovery\\n' >> '\(logPath)'
            while [ ! -f '\(gatePath)' ]; do sleep 0.05; done
            break
          fi
        done
        exec '\(gitPath)' "$@"
        """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    let workspace = LocalWorkspace(
        gitExecutable: wrapper, environment: ProcessInfo.processInfo.environment,
        gitTimeoutNanoseconds: 15_000_000_000, revalidationDelayNanoseconds: 200_000_000)
    let root = fixture.folder.url
    func count() -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    let first = Task { try await workspace.revalidateRepositoryObservationFiles(in: root) }
    let second = Task { try await workspace.revalidateRepositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where await workspace.activeRevalidationSubscribers < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await workspace.activeRevalidationSubscribers == 2)
    for _ in 0..<1_000 where count() < 1 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 1)
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    let late = Task { try await workspace.revalidateRepositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where count() < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 2)
    try Data().write(to: gate)
    #expect(!(try await second.value).isEmpty)
    #expect(!(try await late.value).isEmpty)
    #expect(await workspace.activeRevalidationSubscribers == 0)
    let cancelled = Task { try await workspace.revalidateRepositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where await workspace.activeRevalidationSubscribers == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(await workspace.activeRevalidationSubscribers == 0)
    #expect(count() == 2)
    try FileManager.default.removeItem(at: gate)
    let old = Task { try await workspace.revalidateRepositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where await workspace.activeRevalidationSubscribers == 0 {
        try await Task.sleep(for: .milliseconds(5))
    }
    workspace.invalidateRepositoryScans(in: root)
    let fresh = Task { try await workspace.revalidateRepositoryObservationFiles(in: root) }
    for _ in 0..<1_000 where count() < 4 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 4)
    try Data().write(to: gate)
    _ = try await old.value
    _ = try await fresh.value
    #expect(await workspace.activeRevalidationSubscribers == 0)
}

@Test func simultaneousRepositoryScansShareWorkWithoutCrossingInvalidation() async throws {
    let fixture = try GitFixture()
    try "base\n".write(
        to: fixture.folder.url.appendingPathComponent("base.swift"), atomically: true, encoding: .utf8)
    try fixture.run(["add", "base.swift"])
    try fixture.run(["commit", "-m", "base"])
    let control = try TemporaryFolder()
    let wrapper = control.url.appendingPathComponent("git-wrapper")
    let log = control.url.appendingPathComponent("calls")
    let gate = control.url.appendingPathComponent("release")
    let gitPath = fixture.git.path.replacingOccurrences(of: "'", with: "'\\''")
    let logPath = log.path.replacingOccurrences(of: "'", with: "'\\''")
    let gatePath = gate.path.replacingOccurrences(of: "'", with: "'\\''")
    let script = """
        #!/bin/sh
        '\(gitPath)' "$@"
        result=$?
        for arg do
          if [ "$arg" = "--cached" ] || [ "$arg" = "--raw" ]; then
            printf 'scan\\n' >> '\(logPath)'
            while [ ! -f '\(gatePath)' ]; do sleep 0.05; done
            break
          fi
        done
        exit "$result"
        """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    let workspace = LocalWorkspace(
        gitExecutable: wrapper, environment: ProcessInfo.processInfo.environment,
        gitTimeoutNanoseconds: 15_000_000_000)
    let root = fixture.folder.url
    let other = try GitFixture()
    func count() -> Int {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
    }
    let first = Task { try await workspace.files(in: root) }
    for _ in 0..<1_000 where count() < 1 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 1)
    workspace.invalidateRepositoryScans(in: other.folder.url)
    let equivalentRoot = URL(fileURLWithPath: root.path, isDirectory: true)
    let second = Task { try await workspace.files(in: equivalentRoot) }
    for _ in 0..<1_000 where await workspace.activeScanSubscribers < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await workspace.activeScanSubscribers == 2)
    first.cancel()
    await #expect(throws: CancellationError.self) { try await first.value }
    #expect(await workspace.activeScanSubscribers == 1)
    try Data().write(to: gate)
    let shared = try await second.value
    #expect(shared.files.contains { $0.path == "base.swift" })
    #expect(count() == 1)

    try FileManager.default.removeItem(at: gate)
    let old = Task { try await workspace.files(in: root) }
    for _ in 0..<1_000 where count() < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 2)
    try "new\n".write(
        to: fixture.folder.url.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
    workspace.invalidateRepositoryScans(in: root)
    let freshTask = Task { try await workspace.files(in: root) }
    for _ in 0..<1_000 where count() < 3 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 3)
    try Data().write(to: gate)
    let fresh = try await freshTask.value
    let previous = try await old.value
    #expect(!previous.files.contains { $0.path == "new.swift" })
    #expect(fresh.files.contains { $0.path == "new.swift" })
    #expect(count() == 3)
    try "modified\n".write(to: root.appendingPathComponent("base.swift"), atomically: true, encoding: .utf8)
    workspace.invalidateRepositoryScans(in: root)
    try FileManager.default.removeItem(at: gate)
    let changesOne = Task { try await workspace.changes(in: root) }
    for _ in 0..<1_000 where count() < 4 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 4)
    let changesTwo = Task { try await workspace.changes(in: root) }
    for _ in 0..<1_000 where await workspace.activeScanSubscribers < 2 {
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(await workspace.activeScanSubscribers == 2)
    try Data().write(to: gate)
    let firstChanges = try await changesOne.value
    let secondChanges = try await changesTwo.value
    #expect(firstChanges.files == secondChanges.files)
    #expect(firstChanges.files.contains { $0.path == "base.swift" })
    #expect(count() == 4)
    try FileManager.default.removeItem(at: gate)
    let beforeRollover = Task { try await workspace.files(in: root) }
    for _ in 0..<1_000 where count() < 5 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 5)
    for index in 0..<513 {
        workspace.invalidateRepositoryScans(in: other.folder.url.appendingPathComponent("repo-\(index)"))
    }
    #expect(workspace.scanGenerationEntryCount <= 512)
    let afterRollover = Task { try await workspace.files(in: root) }
    for _ in 0..<1_000 where count() < 6 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 6)
    try Data().write(to: gate)
    _ = try await beforeRollover.value
    _ = try await afterRollover.value
    try FileManager.default.removeItem(at: gate)
    workspace.invalidateRepositoryScans(in: root)
    let last = Task { try await workspace.files(in: root) }
    for _ in 0..<1_000 where count() < 7 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(count() == 7)
    last.cancel()
    await #expect(throws: CancellationError.self) { try await last.value }
    #expect(await workspace.activeScanSubscribers == 0)
    try Data().write(to: gate)
}

@Test @MainActor func invalidGitPathMakesChangesExplicitlyIncomplete() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "old\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "sample.swift"])
    try fixture.run(["commit", "-m", "base"])
    try "new\n".write(to: file, atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()

    let blob = String(decoding: try fixture.runCapture(["rev-parse", "HEAD:sample.swift"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var entry = Data("100644 \(blob)\tinvalid-".utf8)
    entry.append(0xff)
    entry.append(contentsOf: ".swift\0".utf8)
    try fixture.runInput(["update-index", "-z", "--index-info"], data: entry)
    try fixture.run(["commit", "-m", "record raw Git path"])
    let listing = try await workspace.changes(in: fixture.folder.url)
    #expect(listing.isLimited)
    #expect(listing.files.contains { $0.path == "sample.swift" })
    model.refreshFiles(immediate: true)
    for _ in 0..<600 where model.changesError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError != nil)
    #expect(model.presentation == nil)
    #expect(model.changedFiles.isEmpty)
    #expect(!model.canReview && !model.reviewed)
    var removal = Data("0 \(String(repeating: "0", count: blob.count))\tinvalid-".utf8)
    removal.append(0xff)
    removal.append(contentsOf: ".swift\0".utf8)
    try fixture.runInput(["update-index", "-z", "--index-info"], data: removal)
    try fixture.run(["commit", "-m", "remove raw Git path"])
    for _ in 0..<1_000 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError == nil)
    #expect(model.canReview && model.presentation?.diff != nil)
}

@Test func realGitListingOverLimitIsExplicitlyIncomplete() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "base\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "sample.swift"])
    try fixture.run(["commit", "-m", "base"])
    let blob = String(decoding: try fixture.runCapture(["rev-parse", "HEAD:sample.swift"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    var entries = Data()
    for index in 0..<20_001 {
        entries.append(contentsOf: "100644 \(blob)\tmissing/\(index).txt\0".utf8)
    }
    try fixture.runInput(["update-index", "-z", "--index-info"], data: entries)
    try fixture.run(["commit", "-m", "record many paths"])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let changes = try await workspace.changes(in: fixture.folder.url)
    #expect(changes.isLimited)
    #expect(changes.files.count == 20_000)
    #expect(changes.files.allSatisfy { $0.changeKind == .deleted })
}

@Test @MainActor func headChangeRecapturesBaselineAndInvalidatesReviewAcrossWindows() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("revision.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "first"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let observer = FileWatchHub()
    let first = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer)
    let second = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer)
    defer {
        first.close()
        second.close()
    }
    for model in [first, second] {
        await model.open(fixture.folder.url)
        model.setDiff(true)
        model.select("revision.swift")
    }
    for _ in 0..<400 where !first.canReview || !second.canReview {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(first.canReview && second.canReview)
    first.markReviewed()
    second.markReviewed()
    #expect(first.reviewed && second.reviewed)

    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "second"])
    let commit = String(decoding: try fixture.runCapture(["rev-parse", "HEAD"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    try "let value = 2\n".write(to: file, atomically: true, encoding: .utf8)
    let listing = try await workspace.changes(in: fixture.folder.url)
    #expect(listing.revision == commit)
    let input = try await workspace.baseline(in: fixture.folder.url, path: "revision.swift", workingText: "")
    #expect(input.revision == commit)
    first.refreshFiles(immediate: true)
    second.refreshFiles(immediate: true)
    #expect(!first.reviewed && !second.reviewed)
    for _ in 0..<400
    where !first.canReview || !second.canReview
        || first.baselineLabel != String(commit.prefix(7))
        || second.baselineLabel != String(commit.prefix(7))
    {
        try await Task.sleep(for: .milliseconds(10))
    }
    for model in [first, second] {
        #expect(model.canReview)
        #expect(model.baselineLabel == String(commit.prefix(7)))
        #expect(model.presentation?.text.contains("let value = 1") == true)
        #expect(model.presentation?.text.contains("let value = 2") == true)
        #expect(model.presentation?.text.contains("let value = 0") == false)
    }
}

@Test @MainActor func headOnlyCommitTriggersAutomaticBaselineRefresh() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("revision.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "first"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("revision.swift")
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try fixture.run(["commit", "--allow-empty", "-m", "new HEAD"])
    let commit = String(decoding: try fixture.runCapture(["rev-parse", "HEAD"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    for _ in 0..<800 where model.baselineLabel != String(commit.prefix(7)) || !model.canReview {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.baselineLabel == String(commit.prefix(7)))
    #expect(model.canReview)
    #expect(!model.reviewed)
}

@Test @MainActor func subdirectorySeesHeadOnlyCommitOutsideItsTree() async throws {
    let fixture = try GitFixture()
    let folder = fixture.folder.url.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent("revision.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "first"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(folder)
    model.setDiff(true)
    model.select("revision.swift")
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try fixture.run(["commit", "--allow-empty", "-m", "new HEAD"])
    let commit = String(decoding: try fixture.runCapture(["rev-parse", "HEAD"]), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    for _ in 0..<500 where model.baselineLabel != String(commit.prefix(7)) || !model.canReview {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.baselineLabel == String(commit.prefix(7)))
    #expect(model.canReview)
    #expect(!model.reviewed)
}

@Test @MainActor func linkedWorktreeSeesHeadOnlyCommitInExternalMetadata() async throws {
    let fixture = try GitFixture()
    let worktreeParent = try TemporaryFolder()
    let linked = worktreeParent.url.appendingPathComponent("linked")
    try "let value = 0\n".write(
        to: fixture.folder.url.appendingPathComponent("revision.swift"), atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "first"])
    try fixture.run(["worktree", "add", "-b", "linked", linked.path])
    let file = linked.appendingPathComponent("revision.swift")
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(linked)
    model.setDiff(true)
    model.select("revision.swift")
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try fixture.run(["-C", linked.path, "commit", "--allow-empty", "-m", "new HEAD"])
    let commit = String(
        decoding: try fixture.runCapture(["-C", linked.path, "rev-parse", "HEAD"]), as: UTF8.self
    )
    .trimmingCharacters(in: .whitespacesAndNewlines)
    for _ in 0..<500 where model.baselineLabel != String(commit.prefix(7)) || !model.canReview {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.baselineLabel == String(commit.prefix(7)))
    #expect(model.canReview)
    #expect(!model.reviewed)
}

@Test @MainActor func creatingMissingIncludeDirectoriesInvalidatesReview() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let config = external.url.appendingPathComponent("missing/deep/included config")
    try fixture.run(["config", "include.path", config.path])
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let observed = try await workspace.repositoryObservationFiles(in: fixture.folder.url)
    #expect(observed.contains { $0.path.hasSuffix("/missing") })
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    let firstDirectory = external.url.appendingPathComponent("missing", isDirectory: true)
    try FileManager.default.createDirectory(at: firstDirectory, withIntermediateDirectories: false)
    for _ in 0..<500 where model.reviewed || !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed)
    model.markReviewed()
    try FileManager.default.createDirectory(
        at: config.deletingLastPathComponent(), withIntermediateDirectories: false)
    for _ in 0..<500 where model.reviewed || !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed)
    model.markReviewed()
    try "[filter \"custom\"]\n clean = cat\n".write(to: config, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.changesError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError != nil && !model.reviewed && !model.canReview)
    try FileManager.default.removeItem(at: config)
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed && model.changesError == nil)
}

@Test func defaultAttributePathsMatchGitForHomeAndRelativeXDG() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let wrapper = external.url.appendingPathComponent("isolated-git")
    try
        "#!/bin/sh\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null\nexec '\(fixture.git.path)' \"$@\"\n"
        .write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let homeAttributes = external.url.appendingPathComponent(".config/git/attributes")
    let relativeAttributes = fixture.folder.url.appendingPathComponent("relative/git/attributes")
    for (xdg, attributes) in [("", homeAttributes), ("relative", relativeAttributes)] {
        try FileManager.default.createDirectory(
            at: attributes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "*.swift -diff\n".write(to: attributes, atomically: true, encoding: .utf8)
        let environment = ["HOME": external.url.path, "XDG_CONFIG_HOME": xdg, "PATH": "/usr/bin:/bin"]
        let workspace = LocalWorkspace(gitExecutable: wrapper, environment: environment)
        let paths = try await workspace.repositoryObservationFiles(in: fixture.folder.url)
        #expect(paths.map(\.path).contains(attributes.resolvingSymlinksInPath().path))
        let output = try await GitRunner(executable: wrapper, environment: environment).run(
            ["check-attr", "diff", "--", "sample.swift"], at: fixture.folder.url)
        #expect(String(decoding: output.data, as: UTF8.self).contains("diff: unset"))
        try FileManager.default.removeItem(at: attributes)
    }
}

@Test @MainActor func defaultAttributesCreationInvalidatesReview() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let configHome = external.url.appendingPathComponent("xdg", isDirectory: true)
    let attributes = configHome.appendingPathComponent("git/attributes")
    let wrapper = external.url.appendingPathComponent("isolated-git")
    try
        "#!/bin/sh\nexport GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null\nexec '\(fixture.git.path)' \"$@\"\n"
        .write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
    let environment = [
        "HOME": external.url.path, "XDG_CONFIG_HOME": configHome.path, "PATH": "/usr/bin:/bin",
    ]
    let workspace = LocalWorkspace(gitExecutable: wrapper, environment: environment)
    let observed = try await workspace.repositoryObservationFiles(in: fixture.folder.url)
    #expect(observed.contains { $0.path.hasSuffix("/xdg") })
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try FileManager.default.createDirectory(
        at: attributes.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "*.swift -diff\n".write(to: attributes, atomically: true, encoding: .utf8)
    let git = GitRunner(executable: wrapper, environment: environment)
    let result = try await git.run(["check-attr", "diff", "--", "sample.swift"], at: fixture.folder.url)
    #expect(String(decoding: result.data, as: UTF8.self).contains("diff: unset"))
    for _ in 0..<500 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error != nil && !model.reviewed && !model.canReview)
    try FileManager.default.removeItem(at: attributes)
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed && model.error == nil)
}

@Test @MainActor func creatingMissingAttributesDirectoryInvalidatesReview() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let attributes = external.url.appendingPathComponent("missing/attributes")
    try fixture.run(["config", "core.attributesFile", attributes.path])
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try FileManager.default.createDirectory(
        at: attributes.deletingLastPathComponent(), withIntermediateDirectories: false)
    try "*.swift -diff\n".write(to: attributes, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error != nil && !model.reviewed && !model.canReview)
}

@Test @MainActor func externalIncludedConfigChangesInvalidateReview() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let config = external.url.appendingPathComponent("included config")
    try "".write(to: config, atomically: true, encoding: .utf8)
    try fixture.run(["config", "include.path", config.path])
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try "[filter \"custom\"]\n clean = cat\n".write(to: config, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.changesError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError != nil && !model.reviewed && !model.canReview)
    try "[example]\n value = restored\n".write(to: config, atomically: true, encoding: .utf8)
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed && model.changesError == nil)
}

@Test @MainActor func danglingIncludedConfigTargetAndRetargetInvalidateReview() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let link = external.url.appendingPathComponent("include-link")
    let first = external.url.appendingPathComponent("first-config")
    let second = external.url.appendingPathComponent("second-config")
    let filter = "[filter \"custom\"]\n clean = cat\n"
    try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: first.lastPathComponent)
    try fixture.run(["config", "include.path", link.path])
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try filter.write(to: first, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.changesError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError != nil && !model.reviewed && !model.canReview)
    try FileManager.default.removeItem(at: first)
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed && model.changesError == nil)
    model.markReviewed()
    try filter.write(to: second, atomically: true, encoding: .utf8)
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: second.lastPathComponent)
    for _ in 0..<500 where model.changesError == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesError != nil && !model.reviewed && !model.canReview)
    try FileManager.default.removeItem(at: link)
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed && model.changesError == nil)
}

@Test func policyObservationHandlesDanglingDirectoryLinksAndRejectsCycles() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let directoryLink = external.url.appendingPathComponent("directory-link")
    try FileManager.default.createSymbolicLink(
        atPath: directoryLink.path, withDestinationPath: "missing/deep")
    try fixture.run([
        "config", "core.attributesFile", directoryLink.appendingPathComponent("attributes").path,
    ])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let paths = try await workspace.repositoryObservationFiles(in: fixture.folder.url)
    #expect(paths.contains { $0.path.hasSuffix("/directory-link") })
    #expect(paths.contains { $0.path.hasSuffix("/missing") })

    let first = external.url.appendingPathComponent("cycle-a")
    let second = external.url.appendingPathComponent("cycle-b")
    try FileManager.default.createSymbolicLink(atPath: first.path, withDestinationPath: "cycle-b")
    try FileManager.default.createSymbolicLink(atPath: second.path, withDestinationPath: "cycle-a")
    try fixture.run(["config", "core.attributesFile", first.path])
    workspace.invalidateRepositoryScans(in: fixture.folder.url)
    await #expect(throws: WorkspaceFailure.self) {
        try await workspace.repositoryObservationFiles(in: fixture.folder.url)
    }
}

@Test @MainActor func creatingDanglingAttributesTargetInvalidatesReview() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let link = external.url.appendingPathComponent("attributes-link")
    let target = external.url.appendingPathComponent("missing/deep/attributes")
    try FileManager.default.createSymbolicLink(
        atPath: link.path, withDestinationPath: "missing/deep/attributes")
    try fixture.run(["config", "core.attributesFile", link.path])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let observed = try await workspace.repositoryObservationFiles(in: fixture.folder.url)
    #expect(observed.contains { $0.path.hasSuffix("/missing") })
    #expect(observed.contains { $0.path.hasSuffix("/attributes-link") })
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    try FileManager.default.createDirectory(
        at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "*.swift -diff\n".write(to: target, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error != nil && !model.reviewed && !model.canReview)
    try FileManager.default.removeItem(at: target)
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed && model.error == nil)
}

@Test @MainActor func externalAttributeChangesInvalidateReview() async throws {
    let fixture = try GitFixture()
    let external = try TemporaryFolder()
    let attributes = external.url.appendingPathComponent("custom attributes")
    try "".write(to: attributes, atomically: true, encoding: .utf8)
    let alias = external.url.appendingPathComponent("attributes-link")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: attributes)
    try fixture.run(["config", "core.attributesFile", alias.path])
    let paths = try await LocalWorkspace(gitExecutable: fixture.git).repositoryObservationFiles(
        in: fixture.folder.url)
    #expect(Set(paths.map(\.path)).isSuperset(of: [alias.path, attributes.path]))
    let file = fixture.folder.url.appendingPathComponent("sample.swift")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    #expect(model.reviewed)
    try "*.swift -diff\n".write(to: attributes, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error != nil && !model.reviewed && !model.canReview && model.presentation == nil)
    try "".write(to: attributes, atomically: true, encoding: .utf8)
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed && model.error == nil)

    let replacement = external.url.appendingPathComponent("replacement attributes")
    try "".write(to: replacement, atomically: true, encoding: .utf8)
    model.markReviewed()
    try fixture.run(["config", "core.attributesFile", replacement.path])
    for _ in 0..<500 where model.reviewed || !model.canReview {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.canReview && !model.reviewed)
    model.markReviewed()
    try "*.swift -diff\n".write(to: replacement, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error != nil && !model.reviewed && !model.canReview)
}

@Test func relativeAttributesFileIsResolvedFromWorktreeRoot() async throws {
    let fixture = try GitFixture()
    let nested = fixture.folder.url.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "".write(
        to: fixture.folder.url.appendingPathComponent("custom attributes"), atomically: true, encoding: .utf8)
    try fixture.run(["config", "core.attributesFile", "custom attributes"])
    let files = try await LocalWorkspace(gitExecutable: fixture.git).repositoryObservationFiles(in: nested)
    let expected = fixture.folder.url.appendingPathComponent("custom attributes").resolvingSymlinksInPath()
    #expect(files.map(\.path).contains(expected.path))
}

@Test @MainActor func ancestorAttributeChangesInvalidateSubdirectoryReview() async throws {
    let fixture = try GitFixture()
    let nested = fixture.folder.url.appendingPathComponent("nested", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let file = nested.appendingPathComponent("sample.swift")
    let attributes = fixture.folder.url.appendingPathComponent(".gitattributes")
    try "let value = 0\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    try "let value = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub())
    defer { model.close() }
    await model.open(nested)
    model.setDiff(true)
    model.select("sample.swift")
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview)
    model.markReviewed()
    #expect(model.reviewed)

    try "nested/*.swift -diff\n".write(to: attributes, atomically: true, encoding: .utf8)
    for _ in 0..<500 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error != nil)
    #expect(!model.reviewed && !model.canReview && model.presentation == nil)

    try FileManager.default.removeItem(at: attributes)
    for _ in 0..<500 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.canReview && !model.reviewed && model.error == nil)
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

@Test func gitComparisonRejectsConversionsAndBinaryContentExplicitly() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.txt")
    let attributes = fixture.folder.url.appendingPathComponent(".gitattributes")
    try "before\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "sample.txt"])
    try fixture.run(["commit", "-m", "baseline"])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    for attribute in ["filter=custom", "working-tree-encoding=UTF-16", "ident"] {
        try "sample.txt \(attribute)\n".write(to: attributes, atomically: true, encoding: .utf8)
        do {
            _ = try await workspace.baseline(
                in: fixture.folder.url, path: "sample.txt", workingText: "after\n")
            Issue.record("Unsupported conversion must not produce a comparison: \(attribute)")
        } catch let failure as WorkspaceFailure {
            guard case .unsupportedAttribute = failure else {
                Issue.record("Expected an explicit unsupported attribute for \(attribute)")
                continue
            }
        }
    }
    try "sample.txt -diff\n".write(to: attributes, atomically: true, encoding: .utf8)
    do {
        _ = try await workspace.baseline(in: fixture.folder.url, path: "sample.txt", workingText: "after\n")
        Issue.record("Git binary attribute must not produce a text comparison")
    } catch let failure as WorkspaceFailure {
        guard case .binary = failure else {
            Issue.record("Expected a binary error")
            return
        }
    }
    try FileManager.default.removeItem(at: attributes)
    do {
        _ = try await workspace.baseline(in: fixture.folder.url, path: "sample.txt", workingText: "after\r\n")
        Issue.record("Unvalidated CRLF must not produce a text comparison")
    } catch let failure as WorkspaceFailure {
        guard case .unsupportedComparison = failure else {
            Issue.record("Expected a CRLF limitation")
            return
        }
    }
    try "sample.txt -text\n".write(to: attributes, atomically: true, encoding: .utf8)
    try Data("before\r\n".utf8).write(to: file)
    try fixture.run(["add", "sample.txt"])
    try fixture.run(["commit", "-m", "CRLF baseline"])
    try FileManager.default.removeItem(at: attributes)
    do {
        _ = try await workspace.baseline(in: fixture.folder.url, path: "sample.txt", workingText: "after\n")
        Issue.record("A CRLF baseline must not produce a text comparison")
    } catch let failure as WorkspaceFailure {
        guard case .unsupportedComparison = failure else {
            Issue.record("Expected a baseline CRLF limitation")
            return
        }
    }
    try Data([0, 1, 2]).write(to: file)
    do {
        _ = try await workspace.read(file)
        Issue.record("Binary content must not be presented as text")
    } catch let failure as WorkspaceFailure {
        guard case .binary = failure else {
            Issue.record("Expected a binary error")
            return
        }
    }
}

@Test @MainActor func failedComparisonClearsTheOldDiffAndItsCachedPreview() async throws {
    let fixture = try GitFixture()
    let file = fixture.folder.url.appendingPathComponent("sample.txt")
    try "before\n".write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "sample.txt"])
    try fixture.run(["commit", "-m", "base"])
    try "after\n".write(to: file, atomically: true, encoding: .utf8)
    let previews = PreviewCache()
    let model = WorkspaceModel(
        workspace: LocalWorkspace(gitExecutable: fixture.git), syntax: TreeSyntax(), diff: LineDiff(),
        observer: FileWatchHub(), previews: previews)
    defer { model.close() }
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("sample.txt")
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.presentation?.diff != nil)
    #expect(
        previews.value(workspace: fixture.folder.url, path: "sample.txt", comparison: true, expanded: false)
            != nil)
    try Data("after\r\n".utf8).write(to: file)
    model.refresh(immediate: true)
    for _ in 0..<400 where model.error == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error != nil)
    #expect(model.presentation == nil)
    #expect(!model.canReview)
    #expect(
        previews.value(workspace: fixture.folder.url, path: "sample.txt", comparison: true, expanded: false)
            == nil)
    try "after again\n".write(to: file, atomically: true, encoding: .utf8)
    model.refreshFiles(immediate: true)
    for _ in 0..<400 where !model.canReview { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.error == nil)
    #expect(model.presentation?.text.contains("after again") == true)
    #expect(model.canReview)
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

@Test func runnerCancellationTerminatesChildProcess() async throws {
    let folder = try TemporaryFolder()
    let executable = folder.url.appendingPathComponent("forking-git")
    let childFile = folder.url.appendingPathComponent("child-pid")
    try
        "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > child-pid; exec /bin/sleep 30' &\nwait\n"
        .write(
            to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runner = GitRunner(executable: executable)
    let task = Task { try await runner.run(["--version"], at: folder.url) }
    for _ in 0..<400 where FileManager.default.contents(atPath: childFile.path)?.isEmpty ?? true {
        try await Task.sleep(for: .milliseconds(5))
    }
    let childText = try String(contentsOf: childFile, encoding: .utf8)
    let child = try #require(Int32(childText))
    defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    for _ in 0..<200 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(kill(child, 0) != 0, "Cancelling Git must not leave its child running")
}

@Test func runnerTimeoutTerminatesChildProcess() async throws {
    let folder = try TemporaryFolder()
    let executable = folder.url.appendingPathComponent("slow-forking-git")
    let childFile = folder.url.appendingPathComponent("child-pid")
    try
        "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > child-pid; exec /bin/sleep 30' &\nwait\n"
        .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let task = Task { try await GitRunner(executable: executable).run(["--version"], at: folder.url) }
    for _ in 0..<400 where FileManager.default.contents(atPath: childFile.path)?.isEmpty ?? true {
        try await Task.sleep(for: .milliseconds(5))
    }
    let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
    defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
    await #expect(throws: WorkspaceFailure.self) { try await task.value }
    for _ in 0..<200 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(kill(child, 0) != 0, "Timed-out Git must not leave its child running")
}

@Test func runnerCleansChildrenAfterSuccessfulParentExit() async throws {
    let folder = try TemporaryFolder()
    let executable = folder.url.appendingPathComponent("early-exit-git")
    let childFile = folder.url.appendingPathComponent("child-pid")
    try
        "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > child-pid; exec /bin/sleep 30' &\nwhile [ ! -s child-pid ]; do /bin/sleep 0.01; done\nexit 0\n"
        .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let output = try await GitRunner(executable: executable).run(["--version"], at: folder.url)
    let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
    defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
    #expect(output.status == 0)
    for _ in 0..<200 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(kill(child, 0) != 0, "A completed Git command must not leave its child running")
}

private func assertOutputLimitTerminatesChildProcess(stderr: Bool) async throws {
    let folder = try TemporaryFolder()
    let executable = folder.url.appendingPathComponent("noisy-forking-git")
    let childFile = folder.url.appendingPathComponent("child-pid")
    let destination = stderr ? "1>&2" : ""
    try
        "#!/bin/sh\n/bin/sh -c 'trap \"\" TERM; printf \"%s\" \"$$\" > child-pid; exec /bin/sleep 30' &\nwhile [ ! -s child-pid ]; do /bin/sleep 0.01; done\n/bin/dd if=/dev/zero bs=4096 count=512 \(destination) 2>/dev/null\nwait\n"
        .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let task = Task {
        try await GitRunner(executable: executable, environment: nil, timeoutNanoseconds: 20_000_000_000)
            .run(["--version"], at: folder.url, limit: 1_024)
    }
    for _ in 0..<3_000 where FileManager.default.contents(atPath: childFile.path)?.isEmpty ?? true {
        try await Task.sleep(for: .milliseconds(5))
    }
    let child = try #require(Int32(String(contentsOf: childFile, encoding: .utf8)))
    defer { if kill(child, 0) == 0 { kill(child, SIGKILL) } }
    let start = ContinuousClock.now
    await #expect(throws: WorkspaceFailure.self) { try await task.value }
    #expect(start.duration(to: .now) < .milliseconds(2_800), "Output overflow must not wait for timeout")
    for _ in 0..<200 where kill(child, 0) == 0 { try await Task.sleep(for: .milliseconds(5)) }
    #expect(kill(child, 0) != 0, "Output-limited Git must not leave its child running")
}

@Test func runnerOutputLimitTerminatesChildProcess() async throws {
    try await assertOutputLimitTerminatesChildProcess(stderr: false)
}

@Test func runnerDrainsBothPipesAndPreservesExactOutputLimit() async throws {
    let folder = try TemporaryFolder()
    let executable = folder.url.appendingPathComponent("two-stream-git")
    try
        "#!/bin/sh\n/bin/dd if=/dev/zero bs=1024 count=60 1>&2 2>/dev/null\n/bin/dd if=/dev/zero bs=1024 count=128 2>/dev/null\n"
        .write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    let runner = GitRunner(executable: executable)
    let output = try await runner.run(["--version"], at: folder.url, limit: 128 * 1_024)
    #expect(output.status == 0)
    #expect(output.data == Data(repeating: 0, count: 128 * 1_024))
    #expect(output.error.utf8.count == 4_096)
    await #expect(throws: WorkspaceFailure.self) {
        try await runner.run(["--version"], at: folder.url, limit: 128 * 1_024 - 1)
    }
}

@Test func runnerStderrLimitTerminatesChildProcess() async throws {
    try await assertOutputLimitTerminatesChildProcess(stderr: true)
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
    #expect(previews.bytes > 0)

    await second.open(folder.url)
    let cachedID = try #require(
        previews.value(
            workspace: folder.url, path: "shared.txt", comparison: false, expanded: false)?.id)
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

private actor HeldFirstReadWorkspace: WorkspaceReading {
    private let base = LocalWorkspace(gitExecutable: nil)
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func files(in root: URL) async throws -> FileListing { try await base.files(in: root) }
    func read(_ url: URL) async throws -> TextSnapshot { try await base.read(url) }
    func read(in root: URL, path: String, allowMissing: Bool) async throws -> TextSnapshot {
        if !started {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        return try await base.read(in: root, path: path, allowMissing: allowMissing)
    }
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput {
        try await base.baseline(in: root, path: path, workingText: workingText)
    }
    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Test @MainActor func occludedExplicitSelectionSurvivesBackgroundInvalidation() async throws {
    let folder = try TemporaryFolder()
    try "const value = 1;\n".write(
        to: folder.url.appendingPathComponent("hidden.ts"), atomically: true, encoding: .utf8)
    let workspace = HeldFirstReadWorkspace()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    defer {
        model.close()
        Task { await workspace.release() }
    }
    model.setVisible(false)
    await model.open(folder.url)
    model.select("hidden.ts")
    for _ in 0..<300 where !(await workspace.started) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.started)
    model.refresh()
    await workspace.release()
    for _ in 0..<300 where model.presentation == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.presentation?.text == "const value = 1;\n")
    #expect(model.error == nil)
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

@Test @MainActor func newTextFilesCompareAgainstAnEmptyHeadRevision() async throws {
    let fixture = try GitFixture()
    try "base\n".write(
        to: fixture.folder.url.appendingPathComponent("base.txt"), atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    let content = "first\nsecond\n"
    try content.write(
        to: fixture.folder.url.appendingPathComponent("new.swift"), atomically: true, encoding: .utf8)
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let input = try await workspace.baseline(in: fixture.folder.url, path: "new.swift", workingText: content)
    #expect(input.before == "")
    #expect(input.after == content)
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    await model.open(fixture.folder.url)
    model.setDiff(true)
    model.select("new.swift")
    defer { model.close() }
    for _ in 0..<300 where model.isUpdating || model.presentation?.diff == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.error == nil)
    #expect(model.presentation?.diff?.added == 2)
    #expect(model.presentation?.diff?.removed == 0)
}

@Test @MainActor func deletedFileDiffUsesEmptyWorkingRevisionAndTracksRecreation() async throws {
    let fixture = try GitFixture()
    let path = "deleted.swift"
    let file = fixture.folder.url.appendingPathComponent(path)
    let content = "let first = 1\nlet second = 2\n"
    try content.write(to: file, atomically: true, encoding: .utf8)
    try fixture.run(["add", "."])
    try fixture.run(["commit", "-m", "base"])
    let workspace = LocalWorkspace(gitExecutable: fixture.git)
    let initial = try await workspace.read(file)
    try FileManager.default.removeItem(at: file)
    let missing = try await workspace.readDeletedOrCurrent(file)
    #expect(missing.text.isEmpty)
    #expect(missing.version > initial.version)
    await #expect(throws: (any Error).self) { try await workspace.read(file) }
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: FileWatchHub())
    await model.open(fixture.folder.url)
    model.setDiff(true)
    for _ in 0..<300 where model.changedFiles.first(where: { $0.path == path })?.changeKind != .deleted {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.changedFiles.first(where: { $0.path == path })?.changeKind == .deleted)
    model.select(path)
    defer { model.close() }
    for _ in 0..<300 where model.isUpdating || model.presentation?.diff == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.error == nil)
    #expect(model.presentation?.diff?.removed == 2)
    #expect(model.presentation?.diff?.added == 0)
    let rows = try #require(model.presentation?.rows)
    let presentation = try #require(model.presentation)
    #expect(
        UnifiedProjection.copy(range: NSRange(location: 0, length: presentation.text.utf16.count), rows: rows)
            == content)
    try content.write(to: file, atomically: true, encoding: .utf8)
    let recreated = try await workspace.readDeletedOrCurrent(file)
    #expect(recreated.text == content)
    #expect(recreated.version > missing.version)
    model.refreshFiles(immediate: true)
    for _ in 0..<300 where model.isUpdating || model.presentation?.diff?.removed != 0 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(model.error == nil)
    #expect(model.presentation?.diff?.removed == 0)
    #expect(model.presentation?.diff?.added == 0)
    try "".write(to: file, atomically: true, encoding: .utf8)
    let emptyFile = try await workspace.readDeletedOrCurrent(file)
    try FileManager.default.removeItem(at: file)
    let emptyRevision = try await workspace.readDeletedOrCurrent(file)
    #expect(emptyRevision.version > emptyFile.version)
}

@Test func deletionReadDoesNotConvertSymlinkErrorsToEmpty() async throws {
    let folder = try TemporaryFolder()
    let target = folder.url.appendingPathComponent("target")
    let link = folder.url.appendingPathComponent("link")
    try "hello".write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let workspace = LocalWorkspace(gitExecutable: nil)
    await #expect(throws: (any Error).self) { try await workspace.readDeletedOrCurrent(link) }
}

private actor ScopedRefreshWorkspace: WorkspaceReading {
    private(set) var fileScans = 0
    private(set) var changeScans = 0
    func files(in root: URL) async throws -> FileListing {
        fileScans += 1
        return FileListing(
            files: [ProjectFile(path: "known.swift"), ProjectFile(path: ".gitignore")],
            isLimited: false, usesGitIgnore: true)
    }
    func changes(in root: URL) async throws -> FileListing {
        changeScans += 1
        return FileListing(files: [], isLimited: false, usesGitIgnore: true, revision: "fixed")
    }
    func read(_ url: URL) async throws -> TextSnapshot { TextSnapshot(url: url, version: 1, text: "") }
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD", revision: "fixed")
    }
}

@MainActor private final class ScopedEventObserver: FileObserving {
    var handler: (@MainActor @Sendable (WorkspaceChange) -> Void)?
    func observe(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) -> any ObservationLease {
        ActiveTestLease()
    }
    func observeWorkspaceChanges(
        _ url: URL, onChange: @escaping @MainActor @Sendable (WorkspaceChange) -> Void
    ) async -> any ObservationLease {
        handler = onChange
        return ActiveTestLease()
    }
}

@Test @MainActor func knownContentEventsAvoidFullListingButPolicyAndUnknownEventsRescan() async throws {
    let folder = try TemporaryFolder()
    let root = folder.url.resolvingSymlinksInPath()
    let workspace = ScopedRefreshWorkspace()
    let observer = ScopedEventObserver()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer)
    defer { model.close() }
    await model.open(root)
    for _ in 0..<500 where model.changesIndicator != .clean { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesIndicator == .clean)
    #expect(await workspace.fileScans == 1)
    let before = await workspace.changeScans
    observer.handler?(.fileContents([root.appendingPathComponent("known.swift")]))
    for _ in 0..<500 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.fileScans == 1)
    #expect(await workspace.changeScans == before + 1)
    observer.handler?(.fileContents([root.appendingPathComponent(".gitignore")]))
    for _ in 0..<500 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.fileScans == 2)
    observer.handler?(.fileContents([root.appendingPathComponent("unknown.swift")]))
    for _ in 0..<500 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.fileScans == 3)
    observer.handler?(.rescan)
    for _ in 0..<500 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.fileScans == 4)
}

@Test @MainActor func eventClassificationFallsBackForStructuralAndDroppedEvents() {
    let paths = ["/tmp/project/file.swift"] as NSArray
    let modified = FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
    let file = FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsFile)
    func classify(_ value: FSEventStreamEventFlags) -> WorkspaceChange {
        withUnsafePointer(to: value) { flags in
            RepositoryObservation.classify(paths: paths, flags: flags, count: 1)
        }
    }
    if case .fileContents(let urls) = classify(modified | file) {
        #expect(urls.map(\.path) == ["/tmp/project/file.swift"])
    } else {
        Issue.record("A known regular-file content modification should retain its path")
    }
    for flag in [
        kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemRemoved,
        kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagUserDropped,
        kFSEventStreamEventFlagKernelDropped, kFSEventStreamEventFlagRootChanged,
    ] {
        guard case .rescan = classify(modified | file | FSEventStreamEventFlags(flag)) else {
            Issue.record("Structural, dropped or root events must force a complete rescan")
            continue
        }
    }
}

private actor HeldFullListingWorkspace: WorkspaceReading {
    private(set) var fileScans = 0
    private var releaseSecond: CheckedContinuation<Void, Never>?
    func files(in root: URL) async throws -> FileListing {
        fileScans += 1
        let scan = fileScans
        if scan == 2 { await withCheckedContinuation { releaseSecond = $0 } }
        let files =
            scan >= 3
            ? [ProjectFile(path: "known.swift"), ProjectFile(path: "added.swift")]
            : [ProjectFile(path: "known.swift")]
        return FileListing(files: files, isLimited: false, usesGitIgnore: true)
    }
    func release() {
        releaseSecond?.resume()
        releaseSecond = nil
    }
    func changes(in root: URL) async throws -> FileListing {
        FileListing(files: [], isLimited: false, usesGitIgnore: true, revision: "fixed")
    }
    func read(_ url: URL) async throws -> TextSnapshot { TextSnapshot(url: url, version: 1, text: "") }
    func baseline(in root: URL, path: String, workingText: String) async throws -> ComparisonInput {
        ComparisonInput(before: "", after: workingText, label: "HEAD", revision: "fixed")
    }
}

@Test @MainActor func contentEventDuringFullScanCannotDiscardStructuralRefresh() async throws {
    let folder = try TemporaryFolder()
    let root = folder.url.resolvingSymlinksInPath()
    let workspace = HeldFullListingWorkspace()
    let observer = ScopedEventObserver()
    let model = WorkspaceModel(
        workspace: workspace, syntax: TreeSyntax(), diff: LineDiff(), observer: observer)
    defer { model.close() }
    await model.open(root)
    for _ in 0..<500 where model.changesIndicator != .clean { try await Task.sleep(for: .milliseconds(10)) }
    #expect(model.changesIndicator == .clean)
    observer.handler?(.rescan)
    for _ in 0..<500 where await workspace.fileScans < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.fileScans == 2)
    observer.handler?(.fileContents([root.appendingPathComponent("known.swift")]))
    await workspace.release()
    for _ in 0..<500 where model.isRefreshingFiles { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await workspace.fileScans == 3)
    #expect(model.files.map(\.path).contains("added.swift"))
}

@MainActor private final class WorkspaceEventRecorder {
    var changes: [WorkspaceChange] = []
}

@Test @MainActor func realInPlaceFileWriteNotifiesWithPathOrSafeRescan() async throws {
    let folder = try TemporaryFolder()
    let root = folder.url.resolvingSymlinksInPath()
    let file = root.appendingPathComponent("sample.swift")
    try "let value = 1\n".write(to: file, atomically: false, encoding: .utf8)
    let observer = FileWatchHub()
    let recorder = WorkspaceEventRecorder()
    let lease = await observer.observeWorkspaceChanges(root) { recorder.changes.append($0) }
    defer { lease.cancel() }
    #expect(lease.isActive)
    let handle = try FileHandle(forWritingTo: file)
    try handle.seek(toOffset: 12)
    try handle.write(contentsOf: Data("2".utf8))
    try handle.close()
    for _ in 0..<500 where recorder.changes.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!recorder.changes.isEmpty, "An in-place write must notify the workspace")
    for change in recorder.changes {
        if case .fileContents(let paths) = change {
            #expect(paths.contains(file.standardizedFileURL))
        }
    }
}
