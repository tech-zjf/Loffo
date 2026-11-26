import Foundation
import LoffoDomain

/// A small set of independently owned parsers shares the application processing budget.
/// A busy parser never holds the actor responsible for choosing another parser.
public actor SyntaxPool: SyntaxProviding {
    private let workers: [TreeSyntax]
    private var pending: [Int]
    private var lastPaths: [URL?]

    public init(admission: WorkAdmission, maximumParsers: Int = 2) {
        let count = min(2, max(1, maximumParsers))
        workers = (0..<count).map { _ in TreeSyntax(admission: admission) }
        pending = Array(repeating: 0, count: count)
        lastPaths = Array(repeating: nil, count: count)
    }

    public func highlights(for snapshot: TextSnapshot) async -> [SyntaxSpan] {
        await highlightsWithStatus(for: snapshot).spans
    }

    public func highlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights {
        await run(snapshot, transient: false)
    }

    public func transientHighlightsWithStatus(for snapshot: TextSnapshot) async -> SyntaxHighlights {
        await run(snapshot, transient: true)
    }

    private func run(_ snapshot: TextSnapshot, transient: Bool) async -> SyntaxHighlights {
        let minimum = pending.min() ?? 0
        let index =
            pending.indices.first { pending[$0] == minimum && lastPaths[$0] == snapshot.url }
            ?? pending.firstIndex(of: minimum) ?? 0
        pending[index] += 1
        lastPaths[index] = transient ? nil : snapshot.url
        defer { pending[index] -= 1 }
        if transient { return await workers[index].transientHighlightsWithStatus(for: snapshot) }
        return await workers[index].highlightsWithStatus(for: snapshot)
    }

    public func discardCachedTrees() async {
        lastPaths = Array(repeating: nil, count: workers.count)
        await withTaskGroup(of: Void.self) { group in
            for worker in workers { group.addTask { await worker.discardCachedTree() } }
        }
    }

    #if DEBUG
        public var diagnosticCachedTreeCount: Int {
            get async {
                var count = 0
                for worker in workers where await worker.diagnosticHasCachedTree { count += 1 }
                return count
            }
        }
    #endif
}
