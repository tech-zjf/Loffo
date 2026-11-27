import AppKit
import LoffoDesignSystem
import LoffoDomain
import LoffoEditorUI
import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceView: View {
    @ObservedObject private var model: WorkspaceModel
    @AppStorage("Loffo.diffDisplayMode.sideBySide") private var usesSideBySideDiff = false
    @State private var showsHistory = false
    @State private var showsOutline = false
    @State private var filter = ""
    @State private var showsFilter = false
    @State private var expanded: Set<String> = []
    @State private var visibleFileRows: [FileTreeRow] = []
    @State private var fileTreeScrollView: NSScrollView?
    @State private var isSidebarCollapsed = false
    @State private var sidebarWidth = LoffoMetrics.sidebar
    @State private var sidebarDragOrigin: CGFloat?
    @State private var syntaxTheme = EditorSyntaxTheme.standard
    @State private var themeImportFailed = false
    @State private var isFileNameHovered = false
    @StateObject private var copyPathFeedback = CopyPathFeedback()
    @FocusState private var copyPathFocused: Bool
    public init(model: WorkspaceModel) {
        self.model = model
        if let json = UserDefaults.standard.string(forKey: "Loffo.editorThemeJSON"),
            let theme = try? EditorSyntaxTheme(importing: Data(json.utf8))
        {
            _syntaxTheme = State(initialValue: theme)
        }
    }

    private var editorCornerRadius: CGFloat {
        model.showsDiff ? LoffoMetrics.comparisonRadius : LoffoMetrics.radius
    }

    var projectDisplayName: String { model.root?.lastPathComponent ?? L10n.text("Loffo") }

    public var body: some View {
        HStack(spacing: 0) {
            navigationRail
            VStack(spacing: 0) {
                repositoryHeader
                if model.root == nil { welcome } else { workspace }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.root != nil { statusBar }
        }
        .overlay {
            if showsFilter {
                QuickOpenPanel(
                    query: $filter,
                    files: model.showsDiff ? model.changedFiles : model.files,
                    filesRevision: model.fileTreeRevision,
                    onOpen: openQuickFile,
                    onDismiss: dismissFilter)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(LoffoPalette.text)
        .background(LoffoPalette.canvas)
        .tint(LoffoPalette.accent)
        .preferredColorScheme(.light)
        .frame(minWidth: 960, minHeight: 540)
        .ignoresSafeArea()
        .background(WindowVisibility { model.setVisible($0) })
        .onChange(of: model.root) {
            expanded = FileTreeNode.ancestors(of: model.selected)
            rebuildVisibleFileRows()
        }
        .onChange(of: model.fileTreeRevision) { rebuildVisibleFileRows() }
        .onChange(of: filter) { rebuildVisibleFileRows() }
        .onChange(of: model.selected, initial: true) {
            copyPathFeedback.reset()
            let ancestors = FileTreeNode.ancestors(of: model.selected)
            if !ancestors.isSubset(of: expanded) {
                expanded.formUnion(ancestors)
                rebuildVisibleFileRows()
            }
        }
        .onDisappear {
            copyPathFeedback.reset()
            model.close()
        }
        .alert(L10n.text("Could not import theme"), isPresented: $themeImportFailed) {
            Button(L10n.text("OK"), role: .cancel) {}
        } message: {
            Text(L10n.text("Choose a valid VS Code or Zed theme JSON file."))
        }
        .focusedSceneValue(\.workspaceOpenFolder, chooseFolder)
    }

    private var navigationRail: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: LoffoMetrics.railTopInset)
            BrandMark().frame(height: LoffoMetrics.header, alignment: .bottom)
                .padding(.bottom, LoffoMetrics.brandBottomSpacing)
            railButton("folder", title: "Files", active: !isSidebarCollapsed && !model.showsDiff) {
                selectSidebar(diff: false)
            }
            .keyboardShortcut("b", modifiers: [.command])
            railButton("branch", title: "Changes", active: !isSidebarCollapsed && model.showsDiff) {
                selectSidebar(diff: true)
            }
            railButton("magnifyingglass", title: "Filter files", active: false) { focusFilter() }
                .keyboardShortcut("p", modifiers: [.command])
            Spacer()
        }.frame(width: LoffoMetrics.rail)
    }

    private func selectSidebar(diff: Bool) {
        if model.showsDiff == diff && !isSidebarCollapsed {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSidebarCollapsed = true
            }
        } else {
            withAnimation(.easeInOut(duration: 0.2)) {
                isSidebarCollapsed = false
            }
            model.setDiff(diff)
        }
    }

    private func railButton(_ icon: String, title: String, active: Bool, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Group {
                if icon == "branch" {
                    BranchSymbol().fill(active ? LoffoPalette.accent : LoffoPalette.secondary)
                        .frame(width: 16, height: 18)
                } else {
                    Image(systemName: icon).font(.system(size: 17, weight: .light))
                }
            }
            .foregroundStyle(active ? LoffoPalette.accent : LoffoPalette.secondary)
            .frame(width: 40, height: 36)
            .contentShape(Rectangle())
            .background(
                active ? LoffoPalette.selection.opacity(0.65) : .clear,
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(alignment: .bottomTrailing) {
                if icon == "branch", let badge = changesBadge {
                    Text(badge).font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 4).frame(minWidth: 16, minHeight: 16)
                        .background(LoffoPalette.accent, in: Capsule())
                        .offset(x: 2, y: 2).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
        }.buttonStyle(.plain).help(icon == "branch" ? changesIndicatorDescription : L10n.text(title))
            .accessibilityLabel(L10n.text(title))
            .accessibilityValue(icon == "branch" ? changesIndicatorDescription : "")
    }

    var changesBadge: String? {
        switch model.changesIndicator {
        case .count(let count): count > 99 ? "99+" : String(count)
        case .checking:
            model.previousChangesBadgeCount.map { $0 > 99 ? "99+" : String($0) }
        case .unavailable: "!"
        case .hidden, .clean: nil
        }
    }

    private var changesIndicatorDescription: String {
        switch model.changesIndicator {
        case .hidden: L10n.text("Changes")
        case .checking: L10n.text("Checking for changes")
        case .unavailable: L10n.text("Changes unavailable")
        case .clean: L10n.text("No changes")
        case .count(let count):
            L10n.format(count == 1 ? "%ld file changed" : "%ld files changed", count)
        }
    }

    private var repositoryHeader: some View {
        HStack(spacing: 8) {
            Text(projectDisplayName).fontWeight(.semibold).foregroundStyle(LoffoPalette.text)
                .lineLimit(1).truncationMode(.middle).accessibilityLabel(projectDisplayName)
            Spacer(minLength: 0)
            if !model.showsDiff { readerToolbarContent }
        }.padding(.leading, 28).padding(.trailing, 24).frame(height: LoffoMetrics.header)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                Text(L10n.text(model.branchLabel)).lineLimit(1).truncationMode(.middle)
                    .help(model.branchLabel)
            }
            .accessibilityElement(children: .combine)

            if model.showsDiff {
                Label(L10n.text(model.baselineLabel), systemImage: "arrow.left.arrow.right")
                    .lineLimit(1)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(model.error == nil && model.monitoringAvailable ? LoffoPalette.added : .orange)
                    .frame(width: 5, height: 5)
                Text(
                    L10n.text(
                        !model.monitoringAvailable
                            ? "File monitoring unavailable"
                            : (model.isUpdating || model.isRefreshingFiles ? "Updating" : "Watching files")
                    )
                )
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let path = model.selected {
                HStack(spacing: 5) {
                    Text(path).lineLimit(1).truncationMode(.middle).help(path)
                    Button {
                        copyPathFeedback.copy(path) { value in
                            NSPasteboard.general.clearContents()
                            return NSPasteboard.general.setString(value, forType: .string)
                        }
                    } label: {
                        Image(systemName: copyPathFeedback.isCopied ? "checkmark" : "square.on.square")
                            .font(.system(size: 10))
                            .foregroundStyle(
                                copyPathFeedback.isCopied ? LoffoPalette.added : LoffoPalette.text
                            )
                            .frame(width: 18, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($copyPathFocused)
                    .opacity(isFileNameHovered || copyPathFeedback.isCopied || copyPathFocused ? 1 : 0)
                    .allowsHitTesting(isFileNameHovered || copyPathFeedback.isCopied || copyPathFocused)
                    .help(L10n.text(copyPathFeedback.isCopied ? "Copied" : "Copy path"))
                    .accessibilityLabel(L10n.text(copyPathFeedback.isCopied ? "Copied" : "Copy path"))
                }
                .frame(maxWidth: 420, alignment: .trailing)
                .contentShape(Rectangle())
                .onHover { isFileNameHovered = $0 }
            }

            if let fileExtension = model.selected.map({
                URL(fileURLWithPath: $0).pathExtension.uppercased()
            }), !fileExtension.isEmpty {
                Text(fileExtension).lineLimit(1).help(L10n.format("File type: %@", fileExtension))
            }
            if model.selected != nil {
                Text(L10n.text("UTF-8"))
                if !model.showsDiff {
                    Image(systemName: "lock").help(L10n.text("Read only"))
                }
            }
        }
        .font(.system(size: 10))
        .foregroundStyle(LoffoPalette.secondary)
        .padding(.horizontal, 12)
        .frame(height: LoffoMetrics.statusBar)
        .background(LoffoPalette.canvas)
        .overlay(alignment: .top) { Rectangle().fill(LoffoPalette.border).frame(height: 0.5) }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                if !isSidebarCollapsed || sidebarDragOrigin != nil {
                    sidebar.frame(width: isSidebarCollapsed ? 0 : sidebarWidth)
                        .clipped().opacity(isSidebarCollapsed ? 0 : 1)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    paneDivider(title: "Resize sidebar") { delta in
                        let maxWidth = min(440, max(220, geometry.size.width - 430))
                        let resolution = SidebarResize.resolve(
                            startWidth: sidebarDragOrigin ?? sidebarWidth,
                            translation: delta,
                            maximumWidth: maxWidth)
                        if resolution.isCollapsed != isSidebarCollapsed {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isSidebarCollapsed = resolution.isCollapsed
                            }
                        }
                        if !resolution.isCollapsed { sidebarWidth = resolution.width }
                    } onBegin: {
                        sidebarDragOrigin = sidebarWidth
                    } onEnd: {
                        sidebarDragOrigin = nil
                    }.frame(width: isSidebarCollapsed && sidebarDragOrigin == nil ? 0 : 5)
                }
                VStack(spacing: 0) {
                    if model.showsDiff { documentToolbar }
                    if let error = model.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.system(size: 11)).foregroundStyle(LoffoPalette.secondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(LoffoPalette.selection)
                    }
                    if model.syntaxLimited {
                        Label(
                            L10n.text("Syntax highlighting is incomplete for this file."),
                            systemImage: "exclamationmark.circle"
                        ).font(.system(size: 11)).foregroundStyle(LoffoPalette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12).background(LoffoPalette.selection)
                    }
                    if let presentation = model.presentation {
                        if model.showsDiff, usesSideBySideDiff, presentation.sideBySide != nil {
                            SideBySideDiffView(
                                presentation: presentation, navigation: model.navigation,
                                hunkCursor: model.hunkCursor,
                                accessibilityName: model.selected ?? L10n.text("Code"),
                                syntaxTheme: syntaxTheme)
                        } else {
                            CodeEditor(
                                presentation: presentation, navigation: model.navigation,
                                accessibilityName: model.selected ?? L10n.text("Code"),
                                syntaxTheme: syntaxTheme)
                        }
                    } else if model.showsDiff, let changesError = model.changesError {
                        ContentUnavailableView(
                            L10n.text("Changes unavailable"), systemImage: "exclamationmark.triangle",
                            description: Text(changesError)
                        ).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.selected != nil && model.error == nil {
                        // A cold read is pending, not a failed preview. Keep the content surface stable.
                        Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel(L10n.text("Loading file"))
                    } else {
                        ContentUnavailableView(
                            L10n.text(model.selected == nil ? "Select a file" : "No preview"),
                            systemImage: "doc.text",
                            description: Text(
                                L10n.text(
                                    model.selected == nil
                                        ? "Open a file from the project tree."
                                        : "The file could not be loaded."))
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }.frame(minWidth: 400)
                    .background(model.showsDiff ? LoffoPalette.comparisonSurface : LoffoPalette.surface)
                    .clipShape(
                        RoundedRectangle(cornerRadius: editorCornerRadius)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: editorCornerRadius).stroke(
                            LoffoPalette.border.opacity(0.3), lineWidth: 0.5)
                    )
                    .padding(.trailing, model.showsDiff ? 4 : 0)
            }.padding(.trailing, 4).padding(.bottom, 14)
        }
    }

    private func paneDivider(
        title: String, onChange: @escaping (CGFloat) -> Void,
        onBegin: @escaping () -> Void, onEnd: @escaping () -> Void
    ) -> some View {
        Rectangle().fill(.clear).frame(width: 5).overlay {
            Rectangle().fill(LoffoPalette.border.opacity(0.7)).frame(width: 1)
        }.contentShape(Rectangle()).gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    if sidebarDragOrigin == nil { onBegin() }
                    onChange(value.translation.width)
                }
                .onEnded { _ in onEnd() }
        ).onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }.accessibilityLabel(L10n.text(title))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                LoffoScrollView(
                    onScrollView: { fileTreeScrollView = $0 }, scrollbarGutter: 12
                ) {
                    LazyVStack(spacing: 0) {
                        if model.showsDiff {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 7) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .foregroundStyle(LoffoPalette.accent)
                                    Text(model.branchLabel).lineLimit(1).truncationMode(.middle)
                                        .help(model.branchLabel)
                                }
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 8).padding(.top, 8)
                                Text(L10n.text("Changes"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(LoffoPalette.secondary)
                                    .padding(.horizontal, 8).padding(.top, 4)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            ForEach(FileTreeNode.matching(model.changedFiles, query: filter)) { file in
                                Button {
                                    openQuickFile(file.path)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc").font(.system(size: 11))
                                        Text(file.path).font(.system(size: 11)).lineLimit(1).truncationMode(
                                            .middle)
                                        Spacer(minLength: 4)
                                        changeMarker(file.changeKind)
                                    }.font(.system(size: 9)).padding(.horizontal, 8).frame(
                                        height: LoffoMetrics.changesRow
                                    )
                                    .background(
                                        model.selected == file.path ? LoffoPalette.selection : .clear,
                                        in: RoundedRectangle(cornerRadius: 6)
                                    ).contentShape(Rectangle())
                                }.buttonStyle(.plain).modifier(DelayedPathTooltip(text: file.path))
                                    .accessibilityLabel(file.path)
                                    .accessibilityValue(
                                        L10n.text(model.selected == file.path ? "Selected" : "Not selected")
                                            + ", "
                                            + L10n.text(file.changeKind?.accessibilityLabel ?? "Modified"))
                            }
                            if let error = model.changesError {
                                Text(error).font(.system(size: 10)).foregroundStyle(LoffoPalette.secondary)
                                    .padding(8)
                            }
                            Divider().padding(.horizontal, 8).padding(.top, 8)
                            Text(L10n.text("Recent commits"))
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(LoffoPalette.secondary)
                                .padding(.horizontal, 8).padding(.top, 4)
                            ForEach(model.repositoryHistory) { commit in
                                repositoryCommitRow(commit)
                                    .padding(.horizontal, 8)
                            }
                            if model.repositoryHistoryIsLoading {
                                ProgressView().controlSize(.small)
                                    .frame(maxWidth: .infinity).padding(8)
                            } else if let error = model.repositoryHistoryError {
                                Text(error).font(.system(size: 10)).foregroundStyle(LoffoPalette.secondary)
                                    .textSelection(.enabled).padding(8)
                            } else if model.repositoryHistory.isEmpty {
                                Text(L10n.text("No commits yet"))
                                    .font(.system(size: 10)).foregroundStyle(LoffoPalette.secondary)
                                    .padding(8)
                            } else if model.repositoryHistoryHasMore {
                                Button(L10n.text("Load more commits")) {
                                    model.loadMoreRepositoryHistory()
                                }
                                .font(.system(size: 10)).buttonStyle(.plain)
                                .foregroundStyle(LoffoPalette.accent).padding(8)
                            }
                        } else {
                            ForEach(visibleFileRows) { row in
                                treeRow(row)
                            }
                        }
                    }
                    // The same path has different row content in Files and Changes.
                    .id(model.showsDiff)
                    .padding(.top, 8)
                }
                .task(id: SidebarSelection(path: model.selected, diff: model.showsDiff)) {
                    // Expansion must produce the lazy row before asking ScrollViewReader to reveal it.
                    await Task.yield()
                    guard !Task.isCancelled, let selected = model.selected else { return }
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
            if !filter.isEmpty
                && FileTreeNode.matching(model.showsDiff ? model.changedFiles : model.files, query: filter)
                    .isEmpty
            {
                Text(L10n.text("No matching files")).font(.system(size: 11))
                    .foregroundStyle(LoffoPalette.secondary).padding(.vertical, 8)
            }
            if let warning = model.fileListingWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(LoffoPalette.secondary)
                    .lineLimit(2).padding(.vertical, 6)
            }
        }.padding(.leading, 24)
            .onAppear { rebuildVisibleFileRows() }
    }

    private func treeRow(_ row: FileTreeRow) -> some View {
        let node = row.node
        // Preserve a readable filename column even for deeply nested repositories.
        let indentation = CGFloat(min(row.depth, 5)) * 20
        return
            Button {
                if node.children != nil {
                    if expanded.contains(node.path) {
                        expanded.remove(node.path)
                    } else {
                        expanded.insert(node.path)
                    }
                    toggleVisibleFileRows(for: node.path)
                } else {
                    openQuickFile(node.path)
                }
            } label: {
                HStack(spacing: 8) {
                    if node.children != nil {
                        Image(
                            systemName: !row.isExpanded
                                ? "chevron.right" : "chevron.down"
                        )
                        .font(.system(size: 8)).frame(width: 8)
                    } else {
                        Color.clear.frame(width: 8, height: 1)
                    }
                    Image(systemName: node.children == nil ? "doc" : "folder")
                        .font(.system(size: 11, weight: .light)).frame(width: 14).foregroundStyle(
                            LoffoPalette.secondary)
                    Text(node.name).padding(.leading, node.children == nil ? 0 : 4).font(
                        .system(size: 13)
                    ).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }.padding(.leading, indentation + 3).padding(.trailing, 8)
                    .frame(height: LoffoMetrics.row)
                    .background {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: indentation + 4)
                            RoundedRectangle(cornerRadius: 9).fill(
                                model.selected == node.path ? LoffoPalette.selection : .clear)
                        }
                    }
                    .overlay(alignment: .leading) {
                        HStack(spacing: 0) {
                            ForEach(0..<min(row.depth, 5), id: \.self) { _ in
                                LoffoPalette.border.frame(width: 0.5)
                                    .frame(width: 20, alignment: .leading)
                            }
                        }.padding(.leading, 4).allowsHitTesting(false).accessibilityHidden(true)
                    }
                    .contentShape(Rectangle())
            }.buttonStyle(.plain).modifier(DelayedPathTooltip(text: node.path))
            .accessibilityLabel(node.path)
            .accessibilityValue(
                L10n.text(
                    node.children == nil
                        ? (model.selected == node.path ? "Selected" : "Not selected")
                        : (!row.isExpanded ? "Collapsed" : "Expanded")
                ))
    }

    private func repositoryCommitRow(_ commit: FileCommit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(commit.id.prefix(7))).font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(LoffoPalette.accent)
                Spacer(minLength: 4)
                if let date = commit.committedAt {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9)).foregroundStyle(LoffoPalette.secondary)
                }
            }
            Text(commit.subject).font(.system(size: 10)).lineLimit(2)
                .foregroundStyle(LoffoPalette.text).textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(String(commit.id.prefix(7))), \(commit.subject)")
    }

    private func rebuildVisibleFileRows() {
        visibleFileRows = FileTreeNode.visibleRows(model.fileTree, expanded: expanded, query: filter)
    }

    private func toggleVisibleFileRows(for path: String) {
        let oldRows = visibleFileRows
        guard let rowIndex = oldRows.firstIndex(where: { $0.id == path }) else {
            rebuildVisibleFileRows()
            return
        }
        let oldCount = oldRows.count
        let scrollY = fileTreeScrollView?.contentView.bounds.minY ?? 0
        visibleFileRows = FileTreeNode.visibleRows(model.fileTree, expanded: expanded, query: filter)
        guard let scroll = fileTreeScrollView else { return }
        let preservedOffset = FileTreeNode.preservedScrollOffset(
            currentOffset: scrollY, changedRowIndex: rowIndex, oldRowCount: oldCount,
            newRowCount: visibleFileRows.count, rowHeight: LoffoMetrics.row)
        guard preservedOffset != scrollY else { return }
        var origin = scroll.contentView.bounds.origin
        origin.y = preservedOffset
        scroll.contentView.scroll(to: origin)
        scroll.reflectScrolledClipView(scroll.contentView)
    }

    private func changeMarker(_ kind: FileChangeKind?) -> some View {
        let kind = kind ?? .modified
        let color: Color
        switch kind {
        case .untracked, .added: color = LoffoPalette.added
        case .deleted: color = LoffoPalette.removed
        case .modified, .renamed: color = LoffoPalette.modified
        case .conflicted: color = LoffoPalette.removed
        }
        return Text(kind.marker)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .frame(width: 14, alignment: .center)
            .help(L10n.text(kind.accessibilityLabel))
    }

    private var documentToolbar: some View {
        GeometryReader { geometry in
            documentToolbarContent(compact: geometry.size.width < (model.showsDiff ? 440 : 660))
        }.frame(height: LoffoMetrics.toolbar)
    }

    private var readerToolbarContent: some View {
        HStack(spacing: 8) {
            Button {
                showsHistory.toggle()
            } label: {
                Label(L10n.text("History"), systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("History"))
            .help(L10n.text("History"))
            .loffoPopover(isPresented: $showsHistory) {
                LoffoScrollView {
                    historyPanel.padding(18).frame(width: 300, alignment: .topLeading)
                }
                .frame(maxHeight: 520)
            }

            Button {
                showsOutline.toggle()
            } label: {
                Label(L10n.text("Outline"), systemImage: "list.bullet.indent")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.text("Outline"))
            .help(L10n.text("Outline"))
            .loffoPopover(isPresented: $showsOutline, arrowEdge: .leading) {
                outlinePopover
            }

            fileActionsMenu
        }
    }

    private func documentToolbarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            Spacer(minLength: 0)
            if model.showsDiff && model.changesError == nil {
                HStack(spacing: 10) {
                    Button {
                        model.navigateHunk(1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .accessibilityLabel(L10n.text("Next change")).help(L10n.text("Next change"))
                    .keyboardShortcut(.downArrow, modifiers: [.option])
                    Text("\(model.hunkCount == 0 ? 0 : model.hunkCursor + 1) / \(model.hunkCount)")
                    Button {
                        model.navigateHunk(-1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .accessibilityLabel(L10n.text("Previous change")).help(L10n.text("Previous change"))
                    .keyboardShortcut(.upArrow, modifiers: [.option])
                }.fixedSize(horizontal: true, vertical: false).disabled(model.hunkCount == 0).font(
                    .system(size: 11)
                ).buttonStyle(.plain).padding(
                    .horizontal, 10
                ).padding(.vertical, 6)
                    .background(.black.opacity(0.015), in: RoundedRectangle(cornerRadius: 8))
                diffModeToggle(compact: compact)
            }
            fileActionsMenu
        }.padding(.horizontal, compact ? 12 : 20).frame(height: LoffoMetrics.toolbar)
    }

    private var outlinePopover: some View {
        LoffoScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text("File outline")).fontWeight(.medium)
                ForEach(outline, id: \.self) { OutlineSymbolRow(name: $0) }
                if outline.isEmpty {
                    Text(L10n.text("No declarations in this file"))
                        .foregroundStyle(LoffoPalette.secondary)
                }
            }
            .padding(18)
            .frame(width: 360, alignment: .topLeading)
        }
        .frame(maxHeight: 520)
    }

    private var fileActionsMenu: some View {
        Menu {
            Button(L10n.text("Reload File and Baseline")) { model.reload() }
            Button(L10n.text("Import Editor Theme…"), action: chooseSyntaxTheme)
            Button(L10n.text("Use Default Syntax Theme")) {
                syntaxTheme = .standard
                UserDefaults.standard.removeObject(forKey: "Loffo.editorThemeJSON")
            }
            Button(L10n.text("Filter Files")) { focusFilter() }
            if model.showsDiff {
                Button(L10n.text(model.expandsContext ? "Collapse Context" : "Show Full File")) {
                    model.toggleContext()
                }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(LoffoPalette.text)
        .accessibilityLabel(L10n.text("File actions"))
    }

    private func diffModeToggle(compact: Bool) -> some View {
        let currentMode = usesSideBySideDiff ? "Side-by-side diff" : "Unified diff"
        let nextMode = usesSideBySideDiff ? "Switch to unified diff" : "Switch to side-by-side diff"
        let icon = usesSideBySideDiff ? "rectangle.split.2x1" : "list.bullet"
        return Button {
            usesSideBySideDiff.toggle()
        } label: {
            Image(systemName: icon)
                .foregroundStyle(LoffoPalette.accent)
                .frame(width: compact ? 26 : 30, height: 28)
                .background(LoffoPalette.selection, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .help(L10n.text(nextMode))
        .accessibilityLabel(L10n.text("Toggle diff layout"))
        .accessibilityValue(L10n.text(currentMode))
        .accessibilityAddTraits(.isToggle)
    }

    private var outline: [String] {
        guard let text = model.presentation?.text else { return [] }
        return text.components(separatedBy: .newlines).filter {
            $0.range(of: #"\b(function|class|interface|struct|enum|func)\s+\w+"#, options: .regularExpression)
                != nil
        }.prefix(40).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private var lastCommit: some View {
        CommitSummary(commits: model.history, error: model.historyError)
    }

    private var fileHistoryList: some View {
        FileHistoryList(commits: model.history, error: model.historyError)
    }

    private var historyPanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            lastCommit
            Divider()
            fileHistoryList
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            Text(L10n.text("A clear view of your code.")).font(.system(size: 27, weight: .medium))
            Text(L10n.text("Open a local project to read files and follow changes.")).foregroundStyle(
                LoffoPalette.secondary)
            Button(L10n.text("Open Folder…"), action: chooseFolder).buttonStyle(.borderedProminent)
            Text(L10n.text("Local. Read only. No account required.")).font(.caption).foregroundStyle(
                LoffoPalette.secondary)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func focusFilter() {
        showsFilter = true
    }

    private func dismissFilter() {
        showsFilter = false
        filter = ""
    }

    private func openQuickFile(_ path: String) {
        model.select(path)
        dismissFilter()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { Task { await model.open(url) } }
    }

    private func chooseSyntaxTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber, size.uint64Value <= 2 * 1_024 * 1_024 else {
                themeImportFailed = true
                return
            }
            let data = try Data(contentsOf: url)
            let theme = try EditorSyntaxTheme(importing: data)
            syntaxTheme = theme
            UserDefaults.standard.set(
                String(decoding: data, as: UTF8.self), forKey: "Loffo.editorThemeJSON")
        } catch {
            themeImportFailed = true
        }
    }
}

private struct BrandMark: View {
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "LoffoMark", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
    var body: some View {
        if let image = Self.image {
            Image(nsImage: image).resizable().scaledToFit()
                .frame(width: LoffoMetrics.brandMark, height: LoffoMetrics.brandMark)
                .accessibilityLabel(L10n.text("Loffo"))
        }
    }
}

private struct SidebarSelection: Equatable {
    let path: String?
    let diff: Bool
}

private struct DelayedPathTooltip: ViewModifier {
    let text: String
    @State private var isHovering = false
    @State private var isHoveringTooltip = false
    @State private var isVisible = false
    @State private var showTask: Task<Void, Never>?
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                isHovering = hovering
                showTask?.cancel()
                dismissTask?.cancel()
                guard hovering else {
                    scheduleDismiss()
                    return
                }
                guard !isVisible else { return }
                showTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard !Task.isCancelled, isHovering else { return }
                    isVisible = true
                }
            }
            .loffoPopover(isPresented: $isVisible, arrowEdge: .trailing) {
                PathTooltipCard(text: text)
                    .onHover { hovering in
                        isHoveringTooltip = hovering
                        dismissTask?.cancel()
                        if !hovering { scheduleDismiss() }
                    }
            }
            .onChange(of: isVisible) {
                if !isVisible { isHoveringTooltip = false }
            }
            .onAppear {
                #if DEBUG
                    if ProcessInfo.processInfo.environment["LOFFO_SMOKE_TOOLTIP"] == text {
                        isVisible = true
                    }
                #endif
            }
            .onDisappear {
                showTask?.cancel()
                dismissTask?.cancel()
            }
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            if !isHovering && !isHoveringTooltip { isVisible = false }
        }
    }
}

struct PathTooltipCard: View {
    let text: String

    private var contentSize: CGSize {
        let font = NSFont.systemFont(ofSize: 11)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let width = min(300, max(80, ceil((text as NSString).size(withAttributes: attributes).width)))
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
        return CGSize(width: width, height: min(160, max(16, ceil(bounds.height))))
    }

    var body: some View {
        let size = contentSize
        LoffoScrollView {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(LoffoPalette.text)
                .frame(width: size.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: size.width, height: size.height)
        .padding(.vertical, 7)
        .fixedSize()
    }
}

struct OutlineSymbolRow: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.system(size: 11, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(width: 324, alignment: .leading)
            .clipped()
            .textSelection(.enabled)
            .help(name)
    }
}
