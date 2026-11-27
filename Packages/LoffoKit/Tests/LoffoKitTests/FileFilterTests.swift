import CoreGraphics
import LoffoDomain
import Testing

@testable import LoffoFeatures

@Test func fileFilterPrunesUnrelatedFoldersAndKeepsMatchingAncestors() {
    let files = ["README.md", "src/email/send.ts", "src/email/types.ts", "src/ui/view.ts", "tests/mail.ts"]
        .map { ProjectFile(path: $0) }
    let tree = FileTreeNode.build(files)
    let matches = FileTreeNode.matching(tree, query: "SEND")
    #expect(matches.count == 1)
    #expect(matches.first?.path == "src")
    #expect(matches.first?.children?.count == 1)
    #expect(FileTreeNode.firstFile(in: matches) == "src/email/send.ts")
    #expect(FileTreeNode.matching(tree, query: "missing").isEmpty)
    #expect(
        FileTreeNode.firstFile(in: FileTreeNode.matching(tree, query: "src/email")) == "src/email/send.ts")
    #expect(
        FileTreeNode.matching(files, query: "email").map(\.path) == [
            "src/email/send.ts", "src/email/types.ts",
        ])
    #expect(FileTreeNode.matching(files, query: "").count == files.count)
    #expect(FileTreeNode.matching(tree, query: "").count == tree.count)
}

@Test func quickOpenUsesSubsequenceMatchingAndRanksCloseMatchesFirst() {
    let files = [
        ProjectFile(path: "src/Legacy/Panel.swift"),
        ProjectFile(path: "Packages/LoffoKit/Sources/LoffoPopover.swift"),
        ProjectFile(path: "README.md"),
    ]
    let matches = FileTreeNode.quickOpenMatches(files, query: "lop")
    #expect(matches.map(\.path) == ["Packages/LoffoKit/Sources/LoffoPopover.swift"])
    #expect(FileTreeNode.quickOpenMatches(files, query: "xyz").isEmpty)
}

@Test func quickOpenBoundsBroadResultsAcrossStandardRepositorySize() {
    let files = (0..<10_000).map { ProjectFile(path: String(format: "files/group/file%05d.txt", $0)) }
    let result = QuickOpenIndex(files: files).search("file")

    #expect(result.files.count == QuickOpenIndex.resultLimit)
    #expect(result.hasMore)
    #expect(result.files.first?.path == "files/group/file00000.txt")
    #expect(!QuickOpenIndex(files: files).search("missing").hasMore)
}

@Test func unsupportedAttributeMessageKeepsItsParameter() {
    let error = WorkspaceFailure.unsupportedAttribute("working-tree-encoding")
    #expect(error.errorDescription?.contains("working-tree-encoding") == true)
    #expect(error.errorDescription?.contains("%@") == false)
}

@Test func initialTreeExpansionIncludesOnlySelectedFileAncestors() {
    #expect(FileTreeNode.ancestors(of: "src/email/send.ts") == ["src", "src/email"])
    #expect(FileTreeNode.ancestors(of: "reading.ts").isEmpty)
    #expect(FileTreeNode.ancestors(of: nil).isEmpty)
    #expect(!FileTreeNode.ancestors(of: "src/email/send.ts").contains("src/ui"))
}

@Test func flattenedRowsHonorExpansionWithoutCreatingNestedContainers() {
    let tree = FileTreeNode.build([
        ProjectFile(path: "src/email/send.ts"), ProjectFile(path: "src/email/types.ts"),
        ProjectFile(path: "src/ui/view.ts"), ProjectFile(path: "README.md"),
    ])
    let collapsed = FileTreeNode.visibleRows(tree, expanded: [], query: "")
    #expect(collapsed.map(\.id) == ["src", "README.md"])
    let selected = FileTreeNode.visibleRows(
        tree, expanded: FileTreeNode.ancestors(of: "src/email/send.ts"), query: "")
    #expect(
        selected.map(\.id) == [
            "src", "src/email", "src/email/send.ts", "src/email/types.ts", "src/ui", "README.md",
        ])
    #expect(selected.map(\.depth) == [0, 1, 2, 2, 1, 0])
    let filtered = FileTreeNode.visibleRows(tree, expanded: [], query: "VIEW")
    #expect(filtered.map(\.id) == ["src", "src/ui", "src/ui/view.ts"])
    #expect(filtered.map(\.isExpanded) == [true, true, false])
}

@Test func expandingAboveViewportPreservesTheVisibleTreeAnchor() {
    let rowHeight: CGFloat = 31
    #expect(
        FileTreeNode.preservedScrollOffset(
            currentOffset: 310, changedRowIndex: 2, oldRowCount: 20, newRowCount: 24,
            rowHeight: rowHeight) == 434)
    #expect(
        FileTreeNode.preservedScrollOffset(
            currentOffset: 310, changedRowIndex: 10, oldRowCount: 20, newRowCount: 24,
            rowHeight: rowHeight) == 310,
        "A folder at or below the viewport anchor must not move the current content")
    #expect(
        FileTreeNode.preservedScrollOffset(
            currentOffset: 310, changedRowIndex: 2, oldRowCount: 24, newRowCount: 20,
            rowHeight: rowHeight) == 186,
        "Collapsing rows above the viewport must keep the same file visible")
}
