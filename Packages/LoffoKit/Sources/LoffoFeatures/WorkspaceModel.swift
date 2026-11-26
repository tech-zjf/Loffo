import Combine
import Foundation
import LoffoDomain

public enum ChangesIndicator: Equatable {
    case hidden, checking, unavailable, clean
    case count(Int)
}

@MainActor public final class WorkspaceModel: ObservableObject {
    @Published public private(set) var changedFiles: [ProjectFile] = []
    @Published public private(set) var changesError: String?
    @Published public private(set) var history: [FileCommit] = []
    @Published public private(set) var historyError: String?
    private var historyWorker: Task<Void, Never>?
    private var historyRequest = UUID()
    @Published private(set) var fileTree: [FileTreeNode] = []
    @Published private(set) var fileTreeRevision = UUID()
    @Published public private(set) var branchLabel = L10n.text("Local folder")
    @Published public private(set) var root: URL?
    @Published public private(set) var files: [ProjectFile] = []
    @Published public private(set) var selected: String?
    @Published public private(set) var presentation: CodePresentation?
    @Published public private(set) var error: String?
    @Published public private(set) var isUpdating = false
    @Published public private(set) var isRefreshingFiles = false
    @Published public private(set) var monitoringAvailable = false
    @Published public private(set) var repositorySupportsChanges = false
    public var changesIndicator: ChangesIndicator {
        guard root != nil, repositorySupportsChanges || showsDiff else { return .hidden }
        if changesError != nil || !monitoringAvailable { return .unavailable }
        if isRefreshingFiles { return .checking }
        guard changesRevision != nil else { return .unavailable }
        return changedFiles.isEmpty ? .clean : .count(changedFiles.count)
    }
    /// The last complete nonempty count can stay visible while a newer scan is pending.
    /// It must never outlive an error or stand in for a successfully refreshed result.
    var previousChangesBadgeCount: Int? {
        guard changesRevision != nil, changesError == nil, monitoringAvailable, !changedFiles.isEmpty
        else { return nil }
        return changedFiles.count
    }
    public var syntaxLimited: Bool { presentation?.syntaxLimited ?? false }
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
    private let readAdmission = WorkAdmission(maximumJobs: 2, maximumBytes: 2)
    private let appReadAdmission: WorkAdmission
    private let baselineAdmission: WorkAdmission
    private let projectionWork: ProjectionWork
    private var repositoryLeases: [any ObservationLease] = []
    private var repositoryFileLeases: [URL: any ObservationLease] = [:]
    private var monitoringRetry: Task<Void, Never>?
    private var listingWorker: Task<Void, Never>?
    private var listingWorkerID = UUID()
    private var listingRequested = false
    private var listingUserRequested = false
    private var listingGeneration = UUID()
    private var initialListingForRefresh: FileListing?
    private var completeListing: FileListing?
    private var completeFilePaths: Set<String> = []
    private var pendingFullListing = false
    private var activeFullListing = false
    private var visible = true
    private var lease: (any ObservationLease)?
    private var gate = PublicationGate()
    private var refreshGeneration = UUID()
    private var projectEpoch = UUID()
    private var worker: Task<Void, Never>?
    private var workerID = UUID()
    private var retiringWorkerID: UUID?
    private var comparisonWorker: Task<DiffResult, any Error>?
    private var comparisonWorkerID = UUID()
    private var refinementWorker: Task<Void, Never>?
    private var refreshRequested = false
    private var userRefreshRequested = false
    private let previews: PreviewCache
    private var previewWorkspace: URL?
    private var baseline: BaselineSnapshot?
    private var changesRevision: String?

    public init(
        workspace: any WorkspaceReading, syntax: any SyntaxProviding, diff: any DiffComputing,
        observer: any FileObserving, previews: PreviewCache = PreviewCache(),
        appReadAdmission: WorkAdmission = WorkAdmission(maximumJobs: 4, maximumBytes: 4),
        baselineAdmission: WorkAdmission = WorkAdmission(maximumJobs: 8, maximumBytes: 64 * 1_024 * 1_024),
        processingAdmission: WorkAdmission = WorkAdmission()
    ) {
        self.workspace = workspace
        self.syntax = syntax
        self.diff = diff
        self.observer = observer
        self.previews = previews
        self.appReadAdmission = appReadAdmission
        self.baselineAdmission = baselineAdmission
        self.projectionWork = ProjectionWork(admission: processingAdmission)
    }

    public func open(_ url: URL) async {
        let url = url.resolvingSymlinksInPath()
        listingWorker?.cancel()
        listingWorker = nil
        listingWorkerID = UUID()
        listingRequested = false
        initialListingForRefresh = nil
        completeListing = nil
        completeFilePaths = []
        pendingFullListing = false
        activeFullListing = false
        listingUserRequested = false
        isRefreshingFiles = false
        monitoringRetry?.cancel()
        monitoringRetry = nil
        supersedeWorker()
        refreshRequested = false
        userRefreshRequested = false
        isUpdating = false
        comparisonWorker?.cancel()
        refinementWorker?.cancel()
        bindPreviewWorkspace(url)
        for lease in repositoryLeases { lease.cancel() }
        repositoryLeases = []
        for lease in repositoryFileLeases.values { lease.cancel() }
        repositoryFileLeases = [:]
        projectEpoch = UUID()
        let epoch = projectEpoch
        listingGeneration = UUID()
        let listingEpoch = listingGeneration
        lease?.cancel()
        lease = nil
        gate.reset()
        selected = nil
        presentation = nil
        baseline = nil
        changesRevision = nil
        files = []
        changedFiles = []
        changesError = nil
        repositorySupportsChanges = false
        fileListingWarning = nil
        fileTree = []
        root = url
        error = nil
        repositoryLeases.append(
            observer.observeWorkspaceChanges(url) { [weak self] change in self?.workspaceChanged(change) })
        updateMonitoringStatus()
        do {
            let listing = try await workspace.files(in: url)
            guard projectEpoch == epoch else { return }
            let branch =
                listing.usesGitIgnore ? try await workspace.branch(in: url) : L10n.text("Local folder")
            guard projectEpoch == epoch else { return }
            if listing.usesGitIgnore {
                let metadataRoots = try await workspace.repositoryObservationRoots(in: url)
                guard projectEpoch == epoch else { return }
                let rootPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                var observedPaths = [rootPath]
                for metadataRoot in metadataRoots.sorted(by: { $0.path.count < $1.path.count }) {
                    let path = metadataRoot.path
                    guard
                        !observedPaths.contains(where: { observed in
                            path == observed
                                || path.hasPrefix(observed.hasSuffix("/") ? observed : observed + "/")
                        })
                    else { continue }
                    repositoryLeases.append(
                        observer.observeWorkspaceChanges(metadataRoot) { [weak self] change in
                            self?.workspaceChanged(change)
                        })
                    observedPaths.append(path)
                }
                guard try await bindStableRepositoryFiles(in: url, epoch: epoch, generation: listingEpoch)
                else { return }
                updateMonitoringStatus()
            }
            let tree = await Task.detached { FileTreeNode.build(listing.files) }.value
            guard projectEpoch == epoch, listingGeneration == listingEpoch else { return }
            branchLabel = branch
            repositorySupportsChanges = listing.usesGitIgnore
            files = listing.files
            rememberCompleteListing(listing)
            fileTree = tree
            fileTreeRevision = UUID()
            fileListingWarning = listing.isLimited ? L10n.text("The file listing is incomplete.") : nil
            if listing.usesGitIgnore || showsDiff {
                enqueueListingRefresh(immediate: true, initialListing: listing)
            }
        } catch {
            guard projectEpoch == epoch, listingGeneration == listingEpoch else { return }
            self.error = error.localizedDescription
        }
    }

    public func select(_ path: String) {
        guard let root else { return }
        supersedeWorker()
        gate.reset()
        baseline = nil
        reviewed = false
        selected = path
        hunkCursor = 0
        navigation = nil
        history = []
        historyError = nil
        refreshHistory(in: root, path: path)
        error = nil
        presentation =
            showsDiff && changesError != nil
            ? nil
            : previews.value(
                workspace: root, path: path, comparison: showsDiff, expanded: expandsContext)
        lease?.cancel()
        lease = observer.observe(root.appendingPathComponent(path)) { [weak self] in self?.refresh() }
        updateMonitoringStatus()
        refresh(immediate: true)
    }

    private func updateMonitoringStatus() {
        monitoringAvailable =
            !repositoryLeases.isEmpty && repositoryLeases.allSatisfy(\.isActive)
            && repositoryFileLeases.values.allSatisfy(\.isActive)
            && (lease?.isActive ?? true)
        if !monitoringAvailable { reviewed = false }
        if !monitoringAvailable && root != nil { scheduleMonitoringRetry() }
    }

    private func scheduleMonitoringRetry() {
        guard monitoringRetry == nil else { return }
        let epoch = projectEpoch
        monitoringRetry = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.projectEpoch == epoch else { return }
                for lease in self.repositoryLeases { lease.retry() }
                for lease in self.repositoryFileLeases.values { lease.retry() }
                self.lease?.retry()
                self.updateMonitoringStatus()
                if self.monitoringAvailable {
                    self.monitoringRetry = nil
                    self.refreshFiles(immediate: true)
                    return
                }
            }
        }
    }

    private func refreshHistory(in root: URL, path: String) {
        historyWorker?.cancel()
        let epoch = projectEpoch
        historyRequest = UUID()
        let request = historyRequest
        historyWorker = Task { [weak self] in
            guard let self else { return }
            do {
                let entries = try await self.workspace.history(in: root, path: path)
                guard self.projectEpoch == epoch && self.selected == path && self.historyRequest == request
                else { return }
                self.history = entries
                self.historyError = nil
            } catch is CancellationError { return } catch {
                if self.projectEpoch == epoch && self.selected == path && self.historyRequest == request {
                    self.historyError = error.localizedDescription
                }
            }
        }
    }

    public func setDiff(_ enabled: Bool) {
        guard showsDiff != enabled else { return }
        supersedeWorker()
        showsDiff = enabled
        refreshFiles(immediate: true)
        gate.reset()
        baseline = nil
        error = nil
        presentation = selected.flatMap { path in
            guard let root, !(enabled && changesError != nil) else { return nil }
            return previews.value(
                workspace: root, path: path, comparison: enabled, expanded: expandsContext)
        }
        refresh(immediate: true)
    }

    public func refresh(immediate: Bool = false) {
        guard selected != nil else { return }
        updateMonitoringStatus()
        refreshGeneration = UUID()
        refinementWorker?.cancel()
        comparisonWorker?.cancel()
        userRefreshRequested = userRefreshRequested || immediate
        guard visible || userRefreshRequested else {
            refreshRequested = true
            return
        }
        refreshRequested = true
        isUpdating = true
        reviewed = false
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        worker = Task { [weak self] in
            guard let self else { return }
            // A fixed delay coalesces bursts without resetting the timer on every event.
            if !immediate { try? await Task.sleep(for: .milliseconds(40)) }
            while self.refreshRequested && (self.visible || self.userRefreshRequested) && !Task.isCancelled {
                self.refreshRequested = false
                let explicitRequest = self.userRefreshRequested
                let generation = self.refreshGeneration
                self.userRefreshRequested = false
                await self.updateSelected()
                // Background invalidation must not silently discard a pending explicit selection
                // merely because its window became occluded while the read was in flight.
                if explicitRequest && self.refreshGeneration != generation && !Task.isCancelled {
                    self.userRefreshRequested = true
                }
            }
            if self.workerID == id && self.worker != nil {
                self.isUpdating = false
                self.worker = nil
            } else if self.retiringWorkerID == id {
                self.retiringWorkerID = nil
                if self.refreshRequested, self.worker?.isCancelled == true { self.supersedeWorker() }
            }
            if self.worker == nil && self.refreshRequested && (self.visible || self.userRefreshRequested) {
                self.refresh(immediate: self.userRefreshRequested)
            }
        }
    }

    private func supersedeWorker() {
        guard let worker else { return }
        worker.cancel()
        guard retiringWorkerID == nil else { return }
        retiringWorkerID = workerID
        self.worker = nil
    }

    private func updateSelected() async {
        guard let root, let selected else { return }
        let intent = gate.intent
        let generation = refreshGeneration
        let comparison = showsDiff
        let cacheGeneration = previews.generation
        isUpdating = true
        do {
            if comparison && changesError != nil {
                presentation = nil
                return
            }
            if comparison && changedFiles.first(where: { $0.path == selected })?.changeKind == .conflicted {
                throw WorkspaceFailure.unsupportedComparison(
                    "This file has unresolved Git conflicts. Resolve them before reviewing the change.")
            }
            if comparison
                && changedFiles.first(where: { $0.path == selected })?.hasUnsupportedGitType == true
            {
                throw WorkspaceFailure.unsupportedComparison(
                    "Symbolic links and submodules cannot be reviewed as text files.")
            }
            let isDeleted =
                comparison && changedFiles.first(where: { $0.path == selected })?.changeKind == .deleted
            let snapshot = try await CancellableRead().run(
                workspace: workspace, windowAdmission: readAdmission, appAdmission: appReadAdmission,
                root: root, path: selected,
                allowMissing: isDeleted)
            guard gate.intent == intent, refreshGeneration == generation else { return }
            if comparison {
                if changedFiles.first(where: { $0.path == selected })?.hasModeChange == true {
                    throw WorkspaceFailure.unsupportedComparison(
                        "File mode changes are not yet supported. This change cannot be reviewed here.")
                }
                guard !snapshot.text.utf8.contains(13) else {
                    throw WorkspaceFailure.unsupportedComparison(
                        "CRLF/CR comparison is not yet validated. Use Files to read this document.")
                }
                let base: BaselineSnapshot
                if let baseline, baseline.intent == intent {
                    try await workspace.validateComparison(in: root, path: selected)
                    guard gate.intent == intent, refreshGeneration == generation else { return }
                    base = baseline
                } else {
                    try await baselineAdmission.acquire(bytes: BaselineLease.reservedBytes)
                    let lease = BaselineLease(admission: baselineAdmission)
                    guard !Task.isCancelled, gate.intent == intent, refreshGeneration == generation else {
                        return
                    }
                    let input = try await workspace.baseline(
                        in: root, path: selected, workingText: snapshot.text)
                    guard gate.intent == intent, refreshGeneration == generation else { return }
                    base = BaselineSnapshot(
                        intent: intent, text: input.before, label: input.label, revision: input.revision,
                        lease: lease)
                    baseline = base
                }
                if let changesRevision, let revision = base.revision, changesRevision != revision {
                    refreshFiles(immediate: true)
                    return
                }
                guard base.text.reduce(0, { $1.isNewline ? $0 + 1 : $0 }) < 30_000 else {
                    throw WorkspaceFailure.unsupportedComparison(
                        "The baseline exceeds the 30,000-line prototype limit.")
                }
                let diff = diff
                let comparison = Task { [base] in
                    defer { withExtendedLifetime(base.lease) {} }
                    return try await diff.compare(before: base.text, after: snapshot.text)
                }
                let comparisonID = UUID()
                comparisonWorkerID = comparisonID
                comparisonWorker = comparison
                defer {
                    if comparisonWorkerID == comparisonID { comparisonWorker = nil }
                }
                let result = try await comparison.value
                guard gate.intent == intent, refreshGeneration == generation else { return }
                // This prototype pins the commit until Reload, avoiding Git scans on every save.
                let stamp = PresentationStamp(intent: intent, contentVersion: snapshot.version)
                let projectionCost =
                    8 * 1_024 * 1_024 + (snapshot.byteCount + base.text.utf8.count) * 4
                    + result.lines.count * 192
                let expandedContext = expandsContext
                let initialProjection = try await projectionWork.run(bytes: projectionCost) {
                    try TextLimits.validatePresentationRows(result.lines.lazy.map(\.text))
                    return try UnifiedProjection.cancellable(result: result, expanded: expandedContext)
                }
                guard gate.intent == intent, refreshGeneration == generation else { return }
                error = nil
                if gate.accept(stamp) {
                    presentation = CodePresentation(
                        text: initialProjection.text, diff: result, rows: initialProjection.rows,
                        hunkStarts: initialProjection.hunkStarts)
                    baselineLabel = base.label
                    cachePresentation(path: selected, version: snapshot.version, generation: cacheGeneration)
                } else if gate.accepted != stamp {
                    return
                }
                scheduleRefinement(
                    snapshot: snapshot, result: result, baseline: base, path: selected,
                    intent: intent, generation: generation, cacheGeneration: cacheGeneration)
            } else {
                let stamp = PresentationStamp(intent: intent, contentVersion: snapshot.version)
                error = nil
                if gate.accept(stamp) {
                    presentation = CodePresentation(text: snapshot.text)
                    cachePresentation(path: selected, version: snapshot.version, generation: cacheGeneration)
                    error = nil
                }
                scheduleRefinement(
                    snapshot: snapshot, result: nil, baseline: nil, path: selected,
                    intent: intent, generation: generation, cacheGeneration: cacheGeneration)
            }
        } catch is CancellationError {
            return
        } catch {
            guard gate.intent == intent, refreshGeneration == generation else { return }
            gate.reset()
            baseline = nil
            presentation = nil
            previews.remove(workspace: root, path: selected, comparison: comparison)
            self.error = error.localizedDescription
        }
    }

    private func scheduleRefinement(
        snapshot: TextSnapshot, result: DiffResult?, baseline: BaselineSnapshot?, path: String,
        intent: UUID, generation: UUID, cacheGeneration: UInt64
    ) {
        refinementWorker?.cancel()
        let syntax = syntax
        let projectionWork = projectionWork
        refinementWorker = Task { [weak self] in
            defer { withExtendedLifetime(baseline?.lease) {} }
            if let result, let baseline {
                let before = baseline.text
                let oldSpans = await syntax.transientHighlightsWithStatus(
                    for: TextSnapshot(url: snapshot.url, version: snapshot.version, text: before))
                guard !Task.isCancelled, self?.gate.intent == intent, self?.refreshGeneration == generation
                else { return }
                let newSpans = await syntax.highlightsWithStatus(for: snapshot)
                guard !Task.isCancelled, self?.gate.intent == intent, self?.refreshGeneration == generation
                else { return }
                guard !Task.isCancelled, self?.gate.intent == intent, self?.refreshGeneration == generation,
                    let expanded = self?.expandsContext
                else { return }
                let projection: UnifiedProjection
                do {
                    let cost =
                        8 * 1_024 * 1_024 + (snapshot.byteCount + baseline.text.utf8.count) * 4
                        + result.lines.count * 192 + (oldSpans.spans.count + newSpans.spans.count) * 48
                    projection = try await projectionWork.run(bytes: cost) {
                        let spans = try DiffSyntaxProjection.cancellableSpans(
                            result: result, before: oldSpans.spans, after: newSpans.spans)
                        return try UnifiedProjection.cancellable(
                            result: result, syntax: spans, expanded: expanded)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled, self.gate.intent == intent,
                        self.refreshGeneration == generation, let current = self.presentation
                    else { return }
                    self.presentation = CodePresentation(
                        text: current.text, syntax: current.syntax, diff: current.diff,
                        rows: current.rows, hunkStarts: current.hunkStarts, syntaxLimited: true)
                    self.cachePresentation(path: path, version: snapshot.version, generation: cacheGeneration)
                    return
                }
                guard let self, !Task.isCancelled, self.gate.intent == intent,
                    self.refreshGeneration == generation,
                    self.gate.accept(
                        PresentationStamp(intent: intent, contentVersion: snapshot.version, refinement: 1))
                else { return }
                self.presentation = CodePresentation(
                    text: projection.text, syntax: projection.syntax, diff: result, rows: projection.rows,
                    hunkStarts: projection.hunkStarts,
                    syntaxLimited: oldSpans.isLimited || newSpans.isLimited)
                self.cachePresentation(path: path, version: snapshot.version, generation: cacheGeneration)
            } else {
                let spans = await syntax.highlightsWithStatus(for: snapshot)
                guard let self, !Task.isCancelled, self.gate.intent == intent,
                    self.refreshGeneration == generation,
                    self.gate.accept(
                        PresentationStamp(intent: intent, contentVersion: snapshot.version, refinement: 1))
                else { return }
                self.presentation = CodePresentation(
                    text: snapshot.text, syntax: spans.spans, syntaxLimited: spans.isLimited)
                self.cachePresentation(path: path, version: snapshot.version, generation: cacheGeneration)
            }
        }
    }

    private func cachePresentation(path: String, version: UInt64, generation: UInt64) {
        guard let presentation, let root else { return }
        previews.insert(
            presentation, workspace: root, path: path, comparison: showsDiff,
            expanded: expandsContext, version: version, generation: generation)
    }

    private func bindPreviewWorkspace(_ workspace: URL) {
        let next = workspace.standardizedFileURL
        guard previewWorkspace?.path != next.path else { return }
        if let previewWorkspace { previews.release(workspace: previewWorkspace) }
        previewWorkspace = next
        previews.acquire(workspace: next)
    }

    public var hunkCount: Int { presentation?.hunkStarts.count ?? 0 }
    public var isInitialComparison: Bool { baseline?.revision?.hasPrefix("unborn:") == true }
    public func navigateHunk(_ delta: Int) {
        guard let starts = presentation?.hunkStarts else { return }
        guard !starts.isEmpty else { return }
        hunkCursor = (hunkCursor + delta + starts.count) % starts.count
        navigation = CodeNavigation(line: starts[hunkCursor])
    }

    public var canReview: Bool {
        showsDiff && monitoringAvailable && !isUpdating && !refreshRequested && !listingRequested
            && error == nil
            && !isRefreshingFiles && changesError == nil
            && baseline?.revision == changesRevision
            && presentation?.diff?.isCoarse == false
            && changedFiles.contains {
                $0.path == selected && $0.changeKind != .conflicted && !$0.hasModeChange
                    && !$0.hasUnsupportedGitType
            }
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
        enqueueListingRefresh(immediate: immediate, initialListing: nil)
    }

    private func bindRepositoryFiles(_ files: [URL]) {
        let desired = Set(files)
        for path in repositoryFileLeases.keys where !desired.contains(path) {
            repositoryFileLeases.removeValue(forKey: path)?.cancel()
        }
        for path in desired where repositoryFileLeases[path] == nil {
            repositoryFileLeases[path] = observer.observe(path) { [weak self] in self?.refreshFiles() }
        }
        updateMonitoringStatus()
    }

    private func bindStableRepositoryFiles(in root: URL, epoch: UUID, generation: UUID) async throws -> Bool {
        var files = try await workspace.repositoryObservationFiles(in: root)
        for _ in 0..<4 {
            guard projectEpoch == epoch, listingGeneration == generation else { return false }
            bindRepositoryFiles(files)
            // Revalidation must start after the watchers exist; joining an older in-flight scan
            // would leave changes between discovery and subscription unobserved.
            let current = try await workspace.revalidateRepositoryObservationFiles(in: root)
            guard projectEpoch == epoch, listingGeneration == generation else { return false }
            if Set(current) == Set(files) { return true }
            files = current
        }
        throw WorkspaceFailure.unavailable("Git configuration changed during the scan. Reload to retry.")
    }

    private func rememberCompleteListing(_ listing: FileListing) {
        completeListing = listing.usesGitIgnore && !listing.isLimited ? listing : nil
        completeFilePaths = completeListing == nil ? [] : Set(listing.files.map(\.path))
    }

    private func workspaceChanged(_ change: WorkspaceChange) {
        guard case .fileContents(let paths) = change, let root, completeListing != nil,
            !paths.isEmpty, fileListingWarning == nil, changesError == nil
        else {
            refreshFiles()
            return
        }
        let prefix = root.standardizedFileURL.path + "/"
        let isKnownContent = paths.allSatisfy { url in
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { return false }
            let relative = String(path.dropFirst(prefix.count))
            let components = relative.split(separator: "/")
            let policyFiles: Set<Substring> = [".git", ".gitignore", ".gitattributes", ".gitmodules"]
            guard !components.contains(where: { policyFiles.contains($0) })
            else { return false }
            return completeFilePaths.contains(relative)
        }
        enqueueListingRefresh(immediate: false, initialListing: nil, full: !isKnownContent)
    }

    private func enqueueListingRefresh(immediate: Bool, initialListing: FileListing?, full: Bool = true) {
        listingGeneration = UUID()
        pendingFullListing = pendingFullListing || full || activeFullListing || initialListing != nil
        initialListingForRefresh = initialListing
        if initialListing == nil, let root { workspace.invalidateRepositoryScans(in: root) }
        updateMonitoringStatus()
        listingRequested = true
        isRefreshingFiles = true
        reviewed = false
        listingUserRequested = listingUserRequested || immediate
        guard visible || listingUserRequested, listingWorker == nil else { return }
        let workerID = UUID()
        listingWorkerID = workerID
        listingWorker = Task { [weak self] in
            guard let self else { return }
            while self.listingRequested && (self.visible || self.listingUserRequested) && !Task.isCancelled {
                self.listingRequested = false
                let userRequested = self.listingUserRequested
                self.listingUserRequested = false
                let initialListing = self.initialListingForRefresh
                self.initialListingForRefresh = nil
                let fullListing = self.pendingFullListing
                self.pendingFullListing = false
                self.activeFullListing = fullListing
                let epoch = self.projectEpoch
                let generation = self.listingGeneration
                guard let root = self.root else { break }
                do {
                    if !userRequested { try await Task.sleep(for: .milliseconds(250)) }
                    guard self.projectEpoch == epoch, self.listingGeneration == generation else { continue }
                    let listing: FileListing
                    if let initialListing {
                        listing = initialListing
                    } else if !fullListing, let complete = self.completeListing {
                        listing = complete
                    } else {
                        listing = try await self.workspace.files(in: root)
                    }
                    guard self.projectEpoch == epoch, self.listingGeneration == generation else { continue }
                    if listing.usesGitIgnore && initialListing == nil && fullListing {
                        guard
                            try await self.bindStableRepositoryFiles(
                                in: root, epoch: epoch, generation: generation)
                        else { continue }
                    }
                    let branch =
                        initialListing != nil || !fullListing
                        ? self.branchLabel
                        : (listing.usesGitIgnore
                            ? try await self.workspace.branch(in: root) : L10n.text("Local folder"))
                    guard self.projectEpoch == epoch, self.listingGeneration == generation else { continue }
                    let previousFiles = self.files
                    let tree = await Task.detached {
                        listing.files == previousFiles ? nil : FileTreeNode.build(listing.files)
                    }.value
                    guard self.projectEpoch == epoch, self.listingGeneration == generation else { continue }
                    self.branchLabel = branch
                    self.repositorySupportsChanges = listing.usesGitIgnore
                    if fullListing { self.rememberCompleteListing(listing) }
                    if let tree {
                        self.files = listing.files
                        self.fileTree = tree
                        self.fileTreeRevision = UUID()
                    }
                    if self.showsDiff || listing.usesGitIgnore {
                        do {
                            let changes = try await self.workspace.changes(in: root)
                            guard self.projectEpoch == epoch, self.listingGeneration == generation else {
                                continue
                            }
                            if changes.isLimited {
                                self.changesError = L10n.text("The changed-file listing is incomplete.")
                                self.invalidateChanges(in: root)
                                if initialListing == nil || self.showsDiff {
                                    self.refresh(immediate: userRequested)
                                }
                                self.fileListingWarning =
                                    listing.isLimited ? L10n.text("The file listing is incomplete.") : nil
                                continue
                            }
                            if let previous = self.changesRevision, previous != changes.revision,
                                let path = self.selected
                            {
                                self.history = []
                                self.historyError = nil
                                self.refreshHistory(in: root, path: path)
                            }
                            if let baseline = self.baseline, baseline.revision != changes.revision {
                                self.gate.reset()
                                self.baseline = nil
                                self.presentation = nil
                                self.reviewed = false
                            }
                            self.changesRevision = changes.revision
                            self.changedFiles = changes.files
                            self.changesError = nil
                        } catch {
                            if self.projectEpoch == epoch && self.listingGeneration == generation {
                                self.changesError = error.localizedDescription
                                self.invalidateChanges(in: root)
                            }
                        }
                    } else {
                        self.changesRevision = nil
                        self.changedFiles = []
                        self.changesError = nil
                    }
                    guard self.projectEpoch == epoch, self.listingGeneration == generation else { continue }
                    if initialListing == nil || self.showsDiff { self.refresh(immediate: userRequested) }
                    self.fileListingWarning =
                        listing.isLimited ? L10n.text("The file listing is incomplete.") : nil
                } catch is CancellationError { break } catch {
                    if self.projectEpoch == epoch && self.listingGeneration == generation {
                        self.error = error.localizedDescription
                        if self.showsDiff || self.repositorySupportsChanges {
                            self.changesError = error.localizedDescription
                            self.invalidateChanges(in: root)
                        }
                    }
                }
            }
            guard self.listingWorkerID == workerID else { return }
            self.listingWorker = nil
            self.activeFullListing = false
            self.isRefreshingFiles = self.listingRequested
        }
    }

    private func invalidateComparison(in root: URL) {
        changesRevision = nil
        changedFiles = []
        gate.reset()
        comparisonWorker?.cancel()
        refinementWorker?.cancel()
        baseline = nil
        presentation = nil
        reviewed = false
        if let path = selected { previews.remove(workspace: root, path: path, comparison: true) }
    }

    private func invalidateChanges(in root: URL) {
        if showsDiff {
            invalidateComparison(in: root)
        } else {
            changesRevision = nil
            changedFiles = []
        }
    }

    public func reload() {
        supersedeWorker()
        refreshFiles(immediate: true)
        gate.reset()
        baseline = nil
        refresh(immediate: true)
    }
    public func close() {
        monitoringRetry?.cancel()
        monitoringRetry = nil
        comparisonWorker?.cancel()
        refinementWorker?.cancel()
        projectEpoch = UUID()
        baseline = nil
        changesRevision = nil
        presentation = nil
        selected = nil
        files = []
        changedFiles = []
        changesError = nil
        repositorySupportsChanges = false
        fileTree = []
        fileTreeRevision = UUID()
        fileListingWarning = nil
        if let previewWorkspace {
            previews.release(workspace: previewWorkspace)
            self.previewWorkspace = nil
        }
        for lease in repositoryLeases { lease.cancel() }
        repositoryLeases = []
        for lease in repositoryFileLeases.values { lease.cancel() }
        repositoryFileLeases = [:]
        historyWorker?.cancel()
        listingWorker?.cancel()
        listingWorker = nil
        listingWorkerID = UUID()
        listingRequested = false
        initialListingForRefresh = nil
        completeListing = nil
        completeFilePaths = []
        pendingFullListing = false
        activeFullListing = false
        isRefreshingFiles = false
        listingUserRequested = false
        userRefreshRequested = false
        gate.reset()
        refreshRequested = false
        worker?.cancel()
        lease?.cancel()
        lease = nil
        monitoringAvailable = false
    }
}
