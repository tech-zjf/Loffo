import Foundation
import LoffoDomain

/// A window cancels its own lease. Native sources survive until their last subscriber leaves.
@MainActor public final class FileWatchHub: FileObserving {
    private struct Entry {
        var file: (any DispatchSourceFileSystemObject)?
        var parent: (any DispatchSourceFileSystemObject)?
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
            entries[key]?.parent = source(key.deletingLastPathComponent()) { [weak self] in
                self?.rebind(key)
                self?.notify(key)
            }
            rebind(key)
        }
        entries[key]?.listeners[id] = onChange
        return Lease { [weak self] in self?.release(key, id: id) }
    }

    public func observeWorkspace(_ url: URL, onChange: @escaping @MainActor @Sendable () -> Void)
        -> any ObservationLease
    {
        let key = url.standardizedFileURL
        let id = UUID()
        if repositories[key] == nil { repositories[key] = RepositoryObservation(root: key) }
        repositories[key]?.listeners[id] = onChange
        return Lease { [weak self] in
            self?.repositories[key]?.listeners.removeValue(forKey: id)
            if self?.repositories[key]?.listeners.isEmpty == true {
                self?.repositories.removeValue(forKey: key)?.stop()
            }
        }
    }

    public var repositorySubscriptionCount: Int { repositories.values.reduce(0) { $0 + $1.listeners.count } }
    public var subscriptionCount: Int { entries.values.reduce(0) { $0 + $1.listeners.count } }

    private func rebind(_ url: URL) {
        entries[url]?.file?.cancel()
        entries[url]?.file = source(url) { [weak self] in self?.notify(url) }
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
    private func source(_ url: URL, event: @escaping @MainActor @Sendable () -> Void) -> (
        any DispatchSourceFileSystemObject
    )? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .attrib, .extend], queue: .main)
        source.setEventHandler { Task { @MainActor in event() } }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        return source
    }
}

@MainActor private final class Lease: ObservationLease {
    private var action: (() -> Void)?
    init(action: @escaping () -> Void) { self.action = action }
    func cancel() {
        action?()
        action = nil
    }
}
