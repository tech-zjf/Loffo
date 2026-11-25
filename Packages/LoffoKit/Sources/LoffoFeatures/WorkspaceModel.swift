import Combine
import Foundation
import LoffoDomain

@MainActor public final class WorkspaceModel: ObservableObject {
    @Published public private(set) var changedFiles: [ProjectFile] = []
    @Published public private(set) var changesError: String?
    @Published public private(set) var history: [FileCommit] = []
    @Published public private(set) var historyError: String?
    private var historyWorker: Task<Void, Never>?
    @Published private(set) var fileTree: [FileTreeNode] = []
    @Published private(set) var fileTreeRevision = UUID()
    @Published public private(set) var branchLabel = L10n.text("Local folder")
    @Published public private(set) var root: URL?
    @Published public private(set) var files: [ProjectFile] = []
    @Published public private(set) var selected: String?
    @Published public private(set) var presentation: CodePresentation?
    @Published public private(set) var error: String?
    @Published public private(set) var isUpdating = false
    @Published public private(set) var fileListingWarning: String?
    @Published public private(set) var baselineLabel = "HEAD"
    @Published public private(set) var showsDiff = false
    @Published public private(set) var navigation: CodeNavigation?
    @Published public private(set) var hunkCursor = 0
    @Published public private(set) var reviewed = false
    @Published public private(set) var expandsContext = false
    private let workspace: any WorkspaceReading
    private let syntax: any SyntaxProviding
    private let diff: any DiffComputing
    private let observer: any FileObserving
    private var repositoryLease: (any ObservationLease)?
    private var listingWorker: Task<Void, Never>?
    private var listingRequested = false
    private var listingUserRequested = false
    private var visible = true
    private var lease: (any ObservationLease)?
    private var gate = PublicationGate()
    private var projectEpoch = UUID()
    private var worker: Task<Void, Never>?
    private var refreshRequested = false
    private var userRefreshRequested = false
    private let previews: PreviewCache
    private var previewWorkspace: URL?
    private var baseline: (intent: UUID, text: String, label: String)?

    public init(
        workspace: any WorkspaceReading, syntax: any SyntaxProviding, diff: any DiffComputing,
        observer: any FileObserving, previews: PreviewCache = PreviewCache()
    ) {
        self.workspace = workspace
        self.syntax = syntax
        self.diff = diff
        self.observer = observer
        self.previews = previews
    }

    public func open(_ url: URL) async {
        bindPreviewWorkspace(url)
        repositoryLease?.cancel()
        repositoryLease = nil
        projectEpoch = UUID()
        let epoch = projectEpoch
        lease?.cancel()
        lease = nil
        gate.reset()
        selected = nil
        presentation = nil
        baseline = nil
        files = []
        changedFiles = []
        changesError = nil
        fileListingWarning = nil
        fileTree = []
        root = url
        error = nil
        repositoryLease = observer.observeWorkspace(url) { [weak self] in self?.refreshFiles() }
        do {
            let listing = try await workspace.files(in: url)
            guard projectEpoch == epoch else { return }
            branchLabel =
                listing.usesGitIgnore ? try await workspace.branch(in: url) : L10n.text("Local folder")
            guard projectEpoch == epoch else { return }
            files = listing.files
            let tree = await Task.detached { FileTreeNode.build(listing.files) }.value
            guard projectEpoch == epoch else { return }
            fileTree = tree
            fileTreeRevision = UUID()
            fileListingWarning = listing.isLimited ? L10n.text("The file listing is incomplete.") : nil
        } catch {
            guard projectEpoch == epoch else { return }
            self.error = error.localizedDescription
        }
    }

    public func select(_ path: String) {
        guard let root else { return }
        gate.reset()
        baseline = nil
        reviewed = false
        selected = path
        hunkCursor = 0
        navigation = nil
        history = []
        historyError = nil
        historyWorker?.cancel()
        let epoch = projectEpoch
        historyWorker = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.workspace.history(in: root, path: path)
                guard self.projectEpoch == epoch && self.selected == path else { return }
                self.history = entries
            } catch is CancellationError { return } catch {
                if self.projectEpoch == epoch && self.selected == path {
                    self.historyError = error.localizedDescription
                }
            }
        }
        error = nil
        presentation = previews.value(
            workspace: root, path: path, comparison: showsDiff, expanded: expandsContext)
        lease?.cancel()
        lease = observer.observe(root.appendingPathComponent(path)) { [weak self] in self?.refresh() }
        refresh(immediate: true)
    }

    public func setDiff(_ enabled: Bool) {
        guard showsDiff != enabled else { return }
        showsDiff = enabled
        refreshFiles(immediate: true)
        gate.reset()
        error = nil
        presentation = selected.flatMap { path in
            guard let root else { return nil }
            return previews.value(
                workspace: root, path: path, comparison: enabled, expanded: expandsContext)
        }
        refresh(immediate: true)
    }

    public func refresh(immediate: Bool = false) {
        guard selected != nil else { return }
        userRefreshRequested = userRefreshRequested || immediate
        guard visible || userRefreshRequested else {
            refreshRequested = true
            return
        }
        refreshRequested = true
        isUpdating = true
        reviewed = false
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            // A fixed delay coalesces bursts without resetting the timer on every event.
            if !immediate { try? await Task.sleep(for: .milliseconds(40)) }
            while self.refreshRequested && (self.visible || self.userRefreshRequested) && !Task.isCancelled {
                self.refreshRequested = false
                self.userRefreshRequested = false
                await self.updateSelected()
            }
            self.isUpdating = false
            self.worker = nil
        }
    }

    private func updateSelected() async {
        guard let root, let selected else { return }
        let intent = gate.intent
        let comparison = showsDiff
        isUpdating = true
        do {
            let snapshot = try await workspace.read(root.appendingPathComponent(selected))
            guard gate.intent == intent else { return }
            if comparison {
                guard !snapshot.text.contains("\r") else {
                    throw WorkspaceFailure.unsupportedComparison(
                        "CRLF/CR comparison is not yet validated. Use Files to read this document.")
                }
                let base: (intent: UUID, text: String, label: String)
                if let baseline, baseline.intent == intent {
                    try await workspace.validateComparison(in: root, path: selected)
                    guard gate.intent == intent else { return }
                    base = baseline
                } else {
                    let input = try await workspace.baseline(
                        in: root, path: selected, workingText: snapshot.text)
                    guard gate.intent == intent else { return }
                    base = (intent, input.before, input.label)
                    baseline = base
                }
                guard base.text.reduce(0, { $1.isNewline ? $0 + 1 : $0 }) < 30_000 else {
                    throw WorkspaceFailure.unsupportedComparison(
                        "The baseline exceeds the 30,000-line prototype limit.")
                }
                let result = try await diff.compare(before: base.text, after: snapshot.text)
                // This prototype pins the commit until Reload, avoiding Git scans on every save.
                let stamp = PresentationStamp(intent: intent, contentVersion: snapshot.version)
                _ = try await Task.detached(priority: .userInitiated) {
                    let value = result.lines.map { $0.text.hasSuffix("\n") ? $0.text : $0.text + "\n" }
                        .joined()
                    try TextLimits.validatePresentation(value)
                    return value
                }.value
                guard gate.intent == intent else { return }
                error = nil
                guard gate.accept(stamp) else { return }
                let expandedContext = expandsContext
                let initialProjection = await Task.detached {
                    UnifiedProjection(result: result, expanded: expandedContext)
                }.value
                guard gate.intent == intent else { return }
                presentation = CodePresentation(
                    text: initialProjection.text, diff: result, rows: initialProjection.rows,
                    hunkStarts: initialProjection.hunkStarts)
                baselineLabel = base.label
                cachePresentation(path: selected, version: snapshot.version)
                let oldSpans = await syntax.highlights(
                    for: TextSnapshot(url: snapshot.url, version: snapshot.version, text: base.text))
                guard gate.intent == intent else { return }
                let newSpans = await syntax.highlights(for: snapshot)
                let projected = await Task.detached(priority: .userInitiated) {
                    DiffSyntaxProjection.spans(result: result, before: oldSpans, after: newSpans)
                }.value
                guard gate.intent == intent,
                    gate.accept(
                        PresentationStamp(intent: intent, contentVersion: snapshot.version, refinement: 1))
                else { return }
                let expanded = expandsContext
                let projection = await Task.detached {
                    UnifiedProjection(result: result, syntax: projected, expanded: expanded)
                }.value
                guard gate.intent == intent else { return }
                presentation = CodePresentation(
                    text: projection.text, syntax: projection.syntax, diff: result, rows: projection.rows,
                    hunkStarts: projection.hunkStarts)
                baselineLabel = base.label
                cachePresentation(path: selected, version: snapshot.version)
                error = nil
            } else {
                let stamp = PresentationStamp(intent: intent, contentVersion: snapshot.version)
                error = nil
                if gate.accept(stamp) {
                    presentation = CodePresentation(text: snapshot.text)
                    cachePresentation(path: selected, version: snapshot.version)
                    error = nil
                }
                let spans = await syntax.highlights(for: snapshot)
                guard gate.intent == intent,
                    gate.accept(
                        PresentationStamp(intent: intent, contentVersion: snapshot.version, refinement: 1))
                else { return }
                presentation = CodePresentation(text: snapshot.text, syntax: spans)
                cachePresentation(path: selected, version: snapshot.version)
            }
        } catch is CancellationError {
            return
        } catch {
            guard gate.intent == intent else { return }
            self.error = error.localizedDescription
        }
    }

    private func cachePresentation(path: String, version: UInt64) {
        guard let presentation, let root else { return }
        previews.insert(
            presentation, workspace: root, path: path, comparison: showsDiff,
            expanded: expandsContext, version: version)
    }

    private func bindPreviewWorkspace(_ workspace: URL) {
        let next = workspace.standardizedFileURL
        guard previewWorkspace?.path != next.path else { return }
        if let previewWorkspace { previews.release(workspace: previewWorkspace) }
        previewWorkspace = next
        previews.acquire(workspace: next)
    }

    public var hunkCount: Int { presentation?.hunkStarts.count ?? 0 }
    public func navigateHunk(_ delta: Int) {
        guard let starts = presentation?.hunkStarts else { return }
        guard !starts.isEmpty else { return }
        hunkCursor = (hunkCursor + delta + starts.count) % starts.count
        navigation = CodeNavigation(line: starts[hunkCursor])
    }

    public var canReview: Bool {
        showsDiff && !isUpdating && !refreshRequested && !listingRequested && error == nil
            && presentation?.diff?.isCoarse == false
            && changedFiles.first(where: { $0.path == selected })?.changeKind != .conflicted
    }
    public func markReviewed() {
        guard canReview else { return }
        reviewed = true
    }

    public func toggleContext() {
        expandsContext.toggle()
        gate.reset()
        refresh()
    }

    public func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        if value { reload() }
    }

    public func refreshFiles(immediate: Bool = false) {
        listingRequested = true
        listingUserRequested = listingUserRequested || immediate
        guard visible || listingUserRequested, listingWorker == nil else { return }
        listingWorker = Task { [weak self] in
            guard let self else { return }
            while self.listingRequested && (self.visible || self.listingUserRequested) && !Task.isCancelled {
                self.listingRequested = false
                let userRequested = self.listingUserRequested
                self.listingUserRequested = false
                let epoch = self.projectEpoch
                guard let root = self.root else { break }
                do {
                    if !userRequested { try await Task.sleep(for: .milliseconds(250)) }
                    let listing = try await self.workspace.files(in: root)
                    guard self.projectEpoch == epoch else { continue }
                    let branch =
                        listing.usesGitIgnore
                        ? try await self.workspace.branch(in: root) : L10n.text("Local folder")
                    guard self.projectEpoch == epoch else { continue }
                    self.branchLabel = branch
                    self.files = listing.files
                    let tree = await Task.detached { FileTreeNode.build(listing.files) }.value
                    guard self.projectEpoch == epoch else { continue }
                    self.fileTree = tree
                    self.fileTreeRevision = UUID()
                    if self.showsDiff {
                        do {
                            let changes = try await self.workspace.changes(in: root)
                            guard self.projectEpoch == epoch else { continue }
                            self.changedFiles = changes.files
                            self.changesError =
                                changes.isLimited ? L10n.text("The changed-file listing is incomplete.") : nil
                        } catch {
                            if self.projectEpoch == epoch { self.changesError = error.localizedDescription }
                        }
                    }
                    self.refresh(immediate: userRequested)
                    self.fileListingWarning =
                        listing.isLimited ? L10n.text("The file listing is incomplete.") : nil
                } catch is CancellationError { break } catch {
                    if self.projectEpoch == epoch { self.error = error.localizedDescription }
                }
            }
            self.listingWorker = nil
        }
    }

    public func reload() {
        refreshFiles(immediate: true)
        gate.reset()
        refresh(immediate: true)
    }
    public func close() {
        projectEpoch = UUID()
        baseline = nil
        presentation = nil
        selected = nil
        files = []
        changedFiles = []
        fileTree = []
        fileTreeRevision = UUID()
        fileListingWarning = nil
        if let previewWorkspace {
            previews.release(workspace: previewWorkspace)
            self.previewWorkspace = nil
        }
        repositoryLease?.cancel()
        repositoryLease = nil
        historyWorker?.cancel()
        listingWorker?.cancel()
        listingRequested = false
        listingUserRequested = false
        userRefreshRequested = false
        gate.reset()
        refreshRequested = false
        worker?.cancel()
        lease?.cancel()
        lease = nil
    }
}
