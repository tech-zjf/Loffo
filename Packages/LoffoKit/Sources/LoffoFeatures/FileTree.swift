import Foundation
import LoffoDomain

struct FileTreeNode: Identifiable, Sendable {
    let path: String
    let name: String
    let children: [FileTreeNode]?
    var id: String { path }

    static func visibleRows(_ nodes: [FileTreeNode], expanded: Set<String>, query: String) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        func append(_ nodes: [FileTreeNode], depth: Int) {
            for node in nodes {
                let isExpanded = node.children != nil && (!query.isEmpty || expanded.contains(node.path))
                rows.append(FileTreeRow(node: node, depth: depth, isExpanded: isExpanded))
                if isExpanded, let children = node.children { append(children, depth: depth + 1) }
            }
        }
        append(matching(nodes, query: query), depth: 0)
        return rows
    }

    static func preservedScrollOffset(
        currentOffset: CGFloat, changedRowIndex: Int, oldRowCount: Int, newRowCount: Int,
        rowHeight: CGFloat
    ) -> CGFloat {
        let changedRowBottom = CGFloat(changedRowIndex + 1) * rowHeight
        guard changedRowBottom <= currentOffset else { return currentOffset }
        let rowDelta = newRowCount - oldRowCount
        return max(0, currentOffset + CGFloat(rowDelta) * rowHeight)
    }

    static func ancestors(of path: String?) -> Set<String> {
        guard let path else { return [] }
        let parts = path.split(separator: "/").dropLast()
        var prefix = ""
        return Set(
            parts.map { part in
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                return prefix
            })
    }

    static func matching(_ nodes: [FileTreeNode], query: String) -> [FileTreeNode] {
        guard !query.isEmpty else { return nodes }
        return nodes.compactMap { node in
            if node.path.localizedCaseInsensitiveContains(query) { return node }
            guard let children = node.children else { return nil }
            let matches = matching(children, query: query)
            return matches.isEmpty ? nil : FileTreeNode(path: node.path, name: node.name, children: matches)
        }
    }

    static func firstFile(in nodes: [FileTreeNode]) -> String? {
        for node in nodes {
            if let children = node.children {
                if let first = firstFile(in: children) { return first }
            } else {
                return node.path
            }
        }
        return nil
    }

    static func matching(_ files: [ProjectFile], query: String) -> [ProjectFile] {
        query.isEmpty ? files : files.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    static func quickOpenMatches(_ files: [ProjectFile], query: String) -> [ProjectFile] {
        QuickOpenIndex(files: files).matching(query)
    }

    static func build(_ files: [ProjectFile]) -> [FileTreeNode] {
        func nodes(_ paths: [[String]], prefix: String) -> [FileTreeNode] {
            let grouped = Dictionary(grouping: paths.filter { !$0.isEmpty }, by: { $0[0] })
            return grouped.map { name, values in
                let path = prefix.isEmpty ? name : prefix + "/" + name
                let nested = values.filter { $0.count > 1 }.map { Array($0.dropFirst()) }
                return FileTreeNode(
                    path: path, name: name, children: nested.isEmpty ? nil : nodes(nested, prefix: path))
            }.sorted {
                if ($0.children != nil) != ($1.children != nil) { return $0.children != nil }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
        }
        return nodes(files.map { $0.path.split(separator: "/").map(String.init) }, prefix: "")
    }
}

struct FileTreeRow: Identifiable, Sendable {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool
    var id: String { node.path }
}
