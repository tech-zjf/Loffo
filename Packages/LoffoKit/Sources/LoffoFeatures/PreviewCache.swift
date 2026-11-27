import Foundation
import LoffoDomain

/// App-owned LRU for immutable presentations shared by workspace windows.
/// The byte count is an estimate for cached values, not a cap on active UI or AppKit allocations.
@MainActor public final class PreviewCache {
    private struct Key: Hashable {
        let workspace: String
        let path: String
        let comparison: Bool
        let expanded: Bool
    }
    private struct Entry {
        let presentation: CodePresentation
        let version: UInt64
        let cost: Int
    }

    private var entries: [Key: Entry] = [:]
    private var order: [Key] = []
    private var workspaceLeases: [String: Int] = [:]
    public private(set) var bytes = 0
    public private(set) var generation: UInt64 = 0
    public let maximumEntries: Int
    public let maximumBytes: Int

    public init(maximumEntries: Int = 32, maximumBytes: Int = 32 * 1_024 * 1_024) {
        self.maximumEntries = maximumEntries
        self.maximumBytes = maximumBytes
    }

    public func acquire(workspace: URL) {
        let key = Self.workspaceKey(workspace)
        workspaceLeases[key, default: 0] += 1
    }

    public func release(workspace: URL) {
        let key = Self.workspaceKey(workspace)
        guard let leases = workspaceLeases[key] else { return }
        if leases > 1 {
            workspaceLeases[key] = leases - 1
            return
        }
        workspaceLeases.removeValue(forKey: key)
        removeEntries(where: { $0.workspace == key })
    }

    public func value(
        workspace: URL, path: String, comparison: Bool, expanded: Bool
    ) -> CodePresentation? {
        let key = Key(
            workspace: Self.workspaceKey(workspace), path: path,
            comparison: comparison, expanded: expanded)
        guard let entry = entries[key] else { return nil }
        order.removeAll { $0 == key }
        order.append(key)
        return entry.presentation
    }

    public func insert(
        _ presentation: CodePresentation, workspace: URL, path: String, comparison: Bool,
        expanded: Bool, version: UInt64, generation expectedGeneration: UInt64
    ) {
        guard expectedGeneration == generation else { return }
        let key = Key(
            workspace: Self.workspaceKey(workspace), path: path,
            comparison: comparison, expanded: expanded)
        if let previous = entries[key],
            previous.version > version
                || (previous.version == version && !previous.presentation.syntax.isEmpty
                    && presentation.syntax.isEmpty
                    && previous.presentation.text.utf8.elementsEqual(presentation.text.utf8))
        {
            return
        }
        let cost = Self.estimatedCost(presentation)
        if let old = entries.removeValue(forKey: key) { bytes -= old.cost }
        order.removeAll { $0 == key }
        guard maximumEntries > 0, cost <= maximumBytes else { return }
        while !order.isEmpty && (order.count >= maximumEntries || bytes + cost > maximumBytes) {
            let oldest = order.removeFirst()
            if let old = entries.removeValue(forKey: oldest) { bytes -= old.cost }
        }
        entries[key] = Entry(presentation: presentation, version: version, cost: cost)
        order.append(key)
        bytes += cost
    }

    public func removeAll() {
        generation &+= 1
        entries.removeAll()
        order.removeAll()
        bytes = 0
    }

    public func remove(workspace: URL, path: String, comparison: Bool) {
        generation &+= 1
        let workspace = Self.workspaceKey(workspace)
        removeEntries { $0.workspace == workspace && $0.path == path && $0.comparison == comparison }
    }

    func invalidate(workspace: URL) {
        generation &+= 1
        let workspace = Self.workspaceKey(workspace)
        removeEntries { $0.workspace == workspace }
    }

    private func removeEntries(where predicate: (Key) -> Bool) {
        let removed = entries.keys.filter(predicate)
        for key in removed {
            if let entry = entries.removeValue(forKey: key) { bytes -= entry.cost }
        }
        order.removeAll(where: predicate)
    }

    private static func workspaceKey(_ workspace: URL) -> String {
        workspace.standardizedFileURL.path
    }

    private static func estimatedCost(_ presentation: CodePresentation) -> Int {
        presentation.text.utf8.count * 4 + presentation.syntax.count * 48
            + (presentation.diff?.lines.reduce(0) { $0 + $1.text.utf8.count * 4 + 96 } ?? 0)
            + (presentation.rows?.count ?? 0) * 128
    }
}
