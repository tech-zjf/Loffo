import AppKit
import LoffoDesignSystem
import LoffoDomain
import LoffoEditorUI
import SwiftUI
import UniformTypeIdentifiers

public struct WorkspaceView: View {
    @ObservedObject private var model: WorkspaceModel
    @State private var showsHistory = false
    @State private var showsOutline = false
    @State private var filter = ""
    @FocusState private var filterFocused: Bool
    @State private var showsFilter = false
    @State private var expanded: Set<String> = []
    @State private var visibleFileRows: [FileTreeRow] = []
    @State private var fileTreeScrollView: NSScrollView?
    @State private var isSidebarCollapsed = false
    @State private var sidebarWidth = LoffoMetrics.sidebar
    @State private var inspectorWidth = LoffoMetrics.inspector
    @State private var sidebarDragOrigin: CGFloat?
    @State private var inspectorDragOrigin: CGFloat?
    @State private var syntaxTheme = EditorSyntaxTheme.standard
    @State private var themeImportFailed = false
    @State private var isFileNameHovered = false
    @StateObject private var copyPathFeedback = CopyPathFeedback()
    @FocusState private var copyPathFocused: Bool
    public init(model: WorkspaceModel) {
        self.model = model
        if let json = UserDefaults.standard.string(forKey: "Loffo.editorThemeJSON"),
            let theme = try? EditorSyntaxTheme(vscodeJSON: Data(json.utf8))
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
            Text(L10n.text("Choose a valid VS Code color theme JSON file."))
        }
        .focusedSceneValue(\.workspaceOpenFolder, chooseFolder)
    }

    private var navigationRail: some View {
        VStack(spacing: 6) {
            BrandMark().frame(height: LoffoMetrics.header, alignment: .bottom).padding(.bottom, 8)
            railButton("folder", title: "Files", active: !isSidebarCollapsed && !model.showsDiff) {
                selectSidebar(diff: false)
            }
            .keyboardShortcut("b", modifiers: [.command])
            railButton("branch", title: "Changes", active: !isSidebarCollapsed && model.showsDiff) {
                selectSidebar(diff: true)
            }
            railButton("clock.arrow.circlepath", title: "History", active: false) {}
                .disabled(true).help(L10n.text("Repository history is not available yet"))
            railButton("magnifyingglass", title: "Filter files", active: false) { focusFilter() }
                .keyboardShortcut("p", modifiers: [.command])
            Spacer()
        }.frame(width: LoffoMetrics.rail)
    }

    private func selectSidebar(diff: Bool) {
        if model.showsDiff == diff && !isSidebarCollapsed {
            isSidebarCollapsed = true
        } else {
            isSidebarCollapsed = false
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
        HStack(spacing: 12) {
            Text(projectDisplayName).fontWeight(.semibold).foregroundStyle(LoffoPalette.text)
                .lineLimit(1).truncationMode(.middle).accessibilityLabel(projectDisplayName)
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                .padding(.trailing, 12)
            if model.root != nil {
                HStack(spacing: 9) {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(LoffoPalette.secondary)
                    Text(L10n.text(model.branchLabel)).lineLimit(1).truncationMode(.middle).help(
                        model.branchLabel)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.018), in: Capsule())
                if !model.showsDiff {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(LoffoPalette.secondary)
                    Text("HEAD").font(.system(size: 11)).padding(.horizontal, 14).padding(.vertical, 6)
                        .background(.black.opacity(0.018), in: Capsule())
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(model.error == nil && model.monitoringAvailable ? LoffoPalette.added : .orange)
                        .frame(width: 4, height: 4)
                    Text(
                        L10n.text(
                            !model.monitoringAvailable
                                ? "File monitoring unavailable"
                                : (model.isUpdating ? "Updating" : "Watching files")))
                }.font(.system(size: 10)).foregroundStyle(LoffoPalette.secondary)
            }
            Spacer(minLength: 0)
        }.padding(.leading, 28).padding(.trailing, 24).frame(height: LoffoMetrics.header)
    }

    private var workspace: some View {
        GeometryReader { geometry in
            HStack(alignment: .top, spacing: 0) {
                if !isSidebarCollapsed {
                    sidebar.frame(width: sidebarWidth)
                    paneDivider(title: "Resize sidebar") { delta in
                        let maxWidth = max(
                            220, geometry.size.width - (model.showsDiff ? inspectorWidth + 430 : 430))
                        sidebarWidth = min(
                            max(0, (sidebarDragOrigin ?? sidebarWidth) + delta), min(440, maxWidth))
                    } onBegin: {
                        sidebarDragOrigin = sidebarWidth
                    } onEnd: {
                        sidebarDragOrigin = nil
                    }
                }
                VStack(spacing: 0) {
                    documentToolbar
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
                        if model.showsDiff {
                            HStack(spacing: 8) {
                                Text(
                                    L10n.text(
                                        model.isInitialComparison
                                            ? "Initial → Working tree" : "HEAD → Working tree")
                                )
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.black.opacity(0.018), in: Capsule())
                                if model.error == nil && model.changesError == nil
                                    && model.monitoringAvailable
                                {
                                    Circle().fill(LoffoPalette.added).frame(width: 4, height: 4)
                                    Text(
                                        L10n.text(
                                            model.isUpdating || model.isRefreshingFiles ? "Updating" : "Live")
                                    )
                                }
                                Spacer()
                            }.font(.system(size: 10)).foregroundStyle(LoffoPalette.secondary)
                                .padding(.horizontal, 20).frame(height: 31, alignment: .top).offset(y: -4)
                        }
                        CodeEditor(
                            presentation: presentation, navigation: model.navigation,
                            accessibilityName: model.selected ?? L10n.text("Code"), syntaxTheme: syntaxTheme)
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
                if model.showsDiff, let result = model.presentation?.diff {
                    paneDivider(title: "Resize changes panel") { delta in
                        let maxWidth = max(
                            250, geometry.size.width - (isSidebarCollapsed ? 0 : sidebarWidth) - 430)
                        inspectorWidth = min(
                            max(240, (inspectorDragOrigin ?? inspectorWidth) - delta), min(460, maxWidth))
                    } onBegin: {
                        inspectorDragOrigin = inspectorWidth
                    } onEnd: {
                        inspectorDragOrigin = nil
                    }
                    inspector(result).frame(width: inspectorWidth)
                } else if model.showsDiff && model.selected != nil {
                    Color.clear.frame(width: inspectorWidth)
                }
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
                    if sidebarDragOrigin == nil && inspectorDragOrigin == nil { onBegin() }
                    onChange(value.translation.width)
                }
                .onEnded { _ in onEnd() }
        ).onHover { hovering in
            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
        }.accessibilityLabel(L10n.text(title))
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsFilter {
                TextField(L10n.text("Filter files"), text: $filter).textFieldStyle(.roundedBorder)
                    .accessibilityLabel(L10n.text("Filter files"))
                    .focused($filterFocused)
                    .task { filterFocused = true }
                    .onSubmit { openFirstMatch() }
                    .onExitCommand { dismissFilter() }
            }
            ScrollViewReader { proxy in
                LoffoScrollView(onScrollView: { fileTreeScrollView = $0 }) {
                    LazyVStack(spacing: 0) {
                        if model.showsDiff {
                            ForEach(FileTreeNode.matching(model.changedFiles, query: filter)) { file in
                                Button {
                                    model.select(file.path)
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
                        } else {
                            ForEach(visibleFileRows) { row in
                                treeRow(row)
                            }
                        }
                    }
                    // The same path has different row content in Files and Changes.
                    .id(model.showsDiff)
                    // Keep row labels outside the overlay scroller's hit and paint lane.
                    .padding(.trailing, 20)
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
        }.padding(.leading, 24).padding(.trailing, 8)
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
                    model.select(node.path)
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

    private func documentToolbarContent(compact: Bool) -> some View {
        HStack(spacing: compact ? 8 : 12) {
            if !compact,
                let fileExtension = model.selected.map({ URL(fileURLWithPath: $0).pathExtension.uppercased() }
                ),
                !fileExtension.isEmpty
            {
                Text(fileExtension)
                    .font(.system(size: 11, weight: .medium)).fixedSize()
                    .padding(.horizontal, 8).frame(height: 26)
                    .background(Color.purple.opacity(0.055), in: RoundedRectangle(cornerRadius: 4))
            }
            HStack(spacing: 5) {
                Text(model.selected ?? L10n.text("Your code, in focus."))
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .help(model.selected ?? "").accessibilityLabel(model.selected ?? L10n.text("Code"))
                    .layoutPriority(1)
                if let path = model.selected {
                    Button {
                        copyPathFeedback.copy(path) { value in
                            NSPasteboard.general.clearContents()
                            return NSPasteboard.general.setString(value, forType: .string)
                        }
                    } label: {
                        Image(systemName: copyPathFeedback.isCopied ? "checkmark" : "square.on.square")
                            .font(.system(size: 11))
                            .foregroundStyle(
                                copyPathFeedback.isCopied ? LoffoPalette.added : LoffoPalette.secondary
                            )
                            .frame(width: 24, height: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focused($copyPathFocused)
                    .opacity(isFileNameHovered || copyPathFeedback.isCopied || copyPathFocused ? 1 : 0)
                    .allowsHitTesting(isFileNameHovered || copyPathFeedback.isCopied || copyPathFocused)
                    .help(L10n.text(copyPathFeedback.isCopied ? "Copied" : "Copy path"))
                    .accessibilityLabel(L10n.text(copyPathFeedback.isCopied ? "Copied" : "Copy path"))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { isFileNameHovered = $0 }
            Spacer(minLength: compact ? 0 : 8)
            if !model.showsDiff && !compact {
                Label(L10n.text("Read only"), systemImage: "lock").font(.system(size: 11))
                    .padding(.horizontal, 12).padding(.vertical, 5).background(
                        .black.opacity(0.025), in: Capsule()
                    )
                    .foregroundStyle(LoffoPalette.secondary)
            }
            if !model.showsDiff {
                Button {
                    showsHistory.toggle()
                } label: {
                    if compact {
                        Image(systemName: "clock.arrow.circlepath")
                    } else {
                        Label(L10n.text("History"), systemImage: "clock.arrow.circlepath").font(
                            .system(size: 12))
                    }
                }.buttonStyle(.plain).frame(width: compact ? 28 : 96)
                    .accessibilityLabel(L10n.text("History")).help(L10n.text("History"))
                    .loffoPopover(isPresented: $showsHistory) {
                        historyPanel.padding(18).frame(width: 300)
                    }
                Button {
                    showsOutline.toggle()
                } label: {
                    if compact {
                        Image(systemName: "list.bullet.indent")
                    } else {
                        Label(L10n.text("Outline"), systemImage: "list.bullet.indent").font(.system(size: 12))
                    }
                }.buttonStyle(.plain).frame(width: compact ? 28 : 96)
                    .accessibilityLabel(L10n.text("Outline")).help(L10n.text("Outline"))
                    .loffoPopover(isPresented: $showsOutline) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(L10n.text("File outline")).fontWeight(.medium)
                            ForEach(outline, id: \.self) {
                                Text($0).font(.system(size: 11, design: .monospaced)).textSelection(
                                    .enabled)
                            }
                            if outline.isEmpty {
                                Text(L10n.text("No declarations in this file")).foregroundStyle(
                                    LoffoPalette.secondary)
                            }
                        }.padding(18).frame(width: 360)
                    }
            }
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
                if !compact {
                    Image(systemName: "rectangle.split.2x1").foregroundStyle(
                        LoffoPalette.secondary.opacity(0.5)
                    )
                    .help(L10n.text("Split diff is not available yet"))
                    Image(systemName: "list.bullet").foregroundStyle(LoffoPalette.accent)
                        .padding(7).background(LoffoPalette.selection, in: RoundedRectangle(cornerRadius: 8))
                        .help(L10n.text("Unified diff"))
                }
            }
            Menu {
                Button(L10n.text("Reload File and Baseline")) { model.reload() }
                Button(L10n.text("Import VS Code Theme…"), action: chooseSyntaxTheme)
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
            .accessibilityLabel(
                L10n.text("File actions"))
        }.padding(.horizontal, compact ? 12 : 20).frame(height: LoffoMetrics.toolbar)
    }

    private func inspector(_ result: DiffResult) -> some View {
        GeometryReader { geometry in
            LoffoScrollView {
                inspectorContent(result).frame(minHeight: geometry.size.height, alignment: .top)
            }
        }
    }

    private func inspectorContent(_ result: DiffResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 16) {
                Label(L10n.text("Changes in this file"), systemImage: "doc.text")
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 10) {
                    Text(L10n.format("+%ld Added", result.added)).foregroundStyle(LoffoPalette.added)
                        .padding(.horizontal, 12).padding(.vertical, 4).background(
                            LoffoPalette.addedBackground, in: Capsule())
                    Text(L10n.format("−%ld Removed", result.removed)).foregroundStyle(LoffoPalette.removed)
                        .padding(.horizontal, 12).padding(.vertical, 4).background(
                            LoffoPalette.removedBackground, in: Capsule())
                }.font(.system(size: 11))
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.text("Review")).font(.system(size: 11))
                        HStack {
                            Label(
                                L10n.text(model.reviewed ? "Reviewed" : "Not reviewed"),
                                systemImage: model.reviewed ? "checkmark.circle" : "circle"
                            )
                            .font(.system(size: 11)).foregroundStyle(LoffoPalette.secondary)
                            Spacer(minLength: 4)
                            Button {
                                model.markReviewed()
                            } label: {
                                Label(L10n.text("Mark as reviewed"), systemImage: "checkmark").font(
                                    .system(size: 10)
                                )
                                .foregroundStyle(LoffoPalette.removed).padding(8)
                                .background(LoffoPalette.selection, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain).disabled(!model.canReview || model.reviewed)
                        }
                    }
                }
                Divider().opacity(0.25)
                lastCommit
                if result.isCoarse {
                    Text(L10n.text("Large rewrite · coarse comparison")).foregroundStyle(.orange)
                }
                if let last = result.lines.last(where: { $0.kind != .added }), !last.text.hasSuffix("\n") {
                    Text(L10n.text("Before: no final newline"))
                }
                if let last = result.lines.last(where: { $0.kind != .removed }), !last.text.hasSuffix("\n") {
                    Text(L10n.text("After: no final newline"))
                }
            }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LoffoPalette.inspectorSurface, in: RoundedRectangle(cornerRadius: LoffoMetrics.cardRadius)
                )
                .fixedSize(horizontal: false, vertical: true)
                .overlay(
                    RoundedRectangle(cornerRadius: LoffoMetrics.cardRadius).strokeBorder(
                        LoffoPalette.border.opacity(0.25), lineWidth: 0.5))
            fileHistoryList.padding(18).frame(
                maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading
            )
            .background(
                LoffoPalette.inspectorSurface, in: RoundedRectangle(cornerRadius: LoffoMetrics.cardRadius))
        }.font(.system(size: 10)).padding(.leading, 2).frame(maxHeight: .infinity)
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
        filterFocused = true
    }

    private func dismissFilter() {
        filterFocused = false
        showsFilter = false
        filter = ""
    }

    private func openFirstMatch() {
        let path =
            model.showsDiff
            ? FileTreeNode.matching(model.changedFiles, query: filter).first?.path
            : FileTreeNode.firstFile(in: FileTreeNode.matching(model.fileTree, query: filter))
        guard let path else { return }
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
            let theme = try EditorSyntaxTheme(vscodeJSON: data)
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
            Image(nsImage: image).resizable().scaledToFit().frame(width: 28, height: 28)
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
        ScrollView(.vertical) {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(LoffoPalette.text)
                .frame(width: size.width, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: size.width, height: size.height)
        .scrollIndicators(.hidden)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fixedSize()
    }
}
