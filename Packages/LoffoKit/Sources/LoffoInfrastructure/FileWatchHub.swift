import Darwin
import Foundation
import LoffoDomain

/// A window cancels its own lease. Native sources survive until their last subscriber leaves.
@MainActor public final class FileWatchHub: FileObserving {
    private enum Signature: Equatable {
        case missing
        case present(dev_t, ino_t, mode_t, off_t, Int, Int, Int, Int)
    }
    private struct Entry {
        var file: (any DispatchSourceFileSystemObject)?
        var parent: (any DispatchSourceFileSystemObject)?
        var signature: Signature?
        var listeners: [UUID: @MainActor @Sendable () -> Void] = [:]
    }
    private var repositories: [URL: RepositoryObservation] = [:]
    private var entries: [URL: Entry] = [:]
    public init() {}

    public func observe(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void)
        -> any ObservationLease
    {
        let key = url.standardizedFileURL
        let id = UUID()
        if entries[key] == nil {
            entries[key] = Entry()
            bindParent(key)
            rebind(key)
        }
        entries[key]?.listeners[id] = onChange
        return Lease(
            active: { [weak self] in
                self?.entries[key]?.parent != nil
                    && FileManager.default.fileExists(atPath: key.deletingLastPathComponent().path)
            },
            retry: { [weak self] in self?.retryFile(key) },
            cancel: { [weak self] in self?.release(key, id: id) })
    }

    public func observeWorkspace(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void) async
        -> any ObservationLease
    {
        await observeWorkspaceChanges(url) { _ in onChange() }
    }

    public func observeWorkspaceChanges(
        _ url: URL, onChange: @escaping @MainActor @Sendable (WorkspaceChange) -> Void
    ) async -> any ObservationLease {
        let key = url.standardizedFileURL
        let id = UUID()
        if repositories[key] == nil { repositories[key] = RepositoryObservation(root: key) }
        guard let observation = repositories[key] else {
            return Lease(active: { false }, retry: {}, cancel: {})
        }
        observation.listeners[id] = onChange
        await observation.startIfNeeded()
        return Lease(
            active: { [weak observation] in observation?.isActive == true },
            retry: { [weak self] in await self?.retryRepository(key) },
            cancel: { [weak self] in
                observation.listeners.removeValue(forKey: id)
                if self?.repositories[key]?.listeners.isEmpty == true {
                    self?.repositories.removeValue(forKey: key)?.stop()
                }
            })
    }

    public var repositorySubscriptionCount: Int { repositories.values.reduce(0) { $0 + $1.listeners.count } }
    public var subscriptionCount: Int { entries.values.reduce(0) { $0 + $1.listeners.count } }

    private func bindParent(_ url: URL) {
        entries[url]?.parent = source(url.deletingLastPathComponent()) { [weak self] flags in
            guard let self else { return }
            let previous = self.entries[url]?.signature
            let current = Self.signature(url)
            let parentChanged = flags.contains(.delete) || flags.contains(.rename) || flags.contains(.attrib)
            if !parentChanged, let previous, let current, previous == current { return }
            if flags.contains(.delete) || flags.contains(.rename) {
                self.entries[url]?.parent?.cancel()
                self.entries[url]?.parent = nil
            }
            self.rebind(url)
            self.notify(url)
        }
    }
    private func retryFile(_ url: URL) {
        guard entries[url] != nil else { return }
        if entries[url]?.parent == nil { bindParent(url) }
        rebind(url)
    }
    private func retryRepository(_ url: URL) async {
        guard let previous = repositories[url], !previous.isActive else { return }
        previous.stop()
        await previous.startIfNeeded()
    }
    private func rebind(_ url: URL) {
        entries[url]?.file?.cancel()
        entries[url]?.signature = Self.signature(url)
        // Directory links are watched through their parent; following the link here would
        // report every child write as a change to the link itself.
        if Self.isDirectorySymlink(url) {
            entries[url]?.file = nil
            return
        }
        entries[url]?.file = source(url) { [weak self] flags in
            guard let self else { return }
            if flags.contains(.delete) || flags.contains(.rename) {
                self.rebind(url)
            } else {
                self.entries[url]?.signature = Self.signature(url)
            }
            self.notify(url)
        }
    }

    private static func isDirectorySymlink(_ url: URL) -> Bool {
        var link = stat()
        var target = stat()
        return lstat(url.path, &link) == 0 && link.st_mode & S_IFMT == S_IFLNK
            && stat(url.path, &target) == 0 && target.st_mode & S_IFMT == S_IFDIR
    }

    private static func signature(_ url: URL) -> Signature? {
        var value = stat()
        guard lstat(url.path, &value) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : nil
        }
        return .present(
            value.st_dev, value.st_ino, value.st_mode, value.st_size,
            value.st_mtimespec.tv_sec, value.st_mtimespec.tv_nsec,
            value.st_ctimespec.tv_sec, value.st_ctimespec.tv_nsec)
    }
    private func notify(_ url: URL) {
        guard let listeners = entries[url]?.listeners else { return }
        for listener in listeners.values { listener() }
    }
    private func release(_ url: URL, id: UUID) {
        entries[url]?.listeners.removeValue(forKey: id)
        if entries[url]?.listeners.isEmpty == true {
            let entry = entries.removeValue(forKey: url)
            entry?.file?.cancel()
            entry?.parent?.cancel()
        }
    }
    private func source(
        _ url: URL, event: @escaping @MainActor @Sendable (DispatchSource.FileSystemEvent) -> Void
    ) -> (
        any DispatchSourceFileSystemObject
    )? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
        source.setEventHandler { [weak source] in
            guard let flags = source?.data else { return }
            Task { @MainActor in event(flags) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}

@MainActor private final class Lease: ObservationLease {
    private var action: (() -> Void)?
    private let active: () -> Bool
    private let retryAction: () async -> Void
    init(
        active: @escaping () -> Bool, retry: @escaping () async -> Void, cancel: @escaping () -> Void
    ) {
        self.active = active
        retryAction = retry
        action = cancel
    }
    var isActive: Bool { action != nil && active() }
    func retry() async { if action != nil && !isActive { await retryAction() } }
    func cancel() {
        action?()
        action = nil
    }
}
