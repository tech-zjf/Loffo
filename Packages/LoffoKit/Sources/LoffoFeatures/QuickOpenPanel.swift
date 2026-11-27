import LoffoDesignSystem
import LoffoDomain
import LoffoEditorUI
import SwiftUI

struct QuickOpenPanel: View {
    @Binding var query: String
    let files: [ProjectFile]
    let filesRevision: UUID
    let onOpen: (String) -> Void
    let onDismiss: () -> Void

    @FocusState private var searchFocused: Bool
    @State private var selectedIndex = 0

    @State private var index: QuickOpenIndex?
    @State private var indexRevision: UUID?
    @State private var matches: [ProjectFile] = []
    @State private var hasMoreMatches = false

    private var selectedPath: String? {
        matches.indices.contains(selectedIndex) ? matches[selectedIndex].path : nil
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            VStack(spacing: 0) {
                searchField.padding(10)
                results
            }
            .frame(width: 560)
            .background(LoffoPalette.surface, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
            .padding(.top, 12)
            .onTapGesture {}
        }
        .zIndex(20)
        .task {
            await Task.yield()
            searchFocused = true
        }
        .task(id: filesRevision) {
            let files = self.files
            let revision = filesRevision
            let build = Task.detached(priority: .userInitiated) { QuickOpenIndex(files: files) }
            let result = await withTaskCancellationHandler {
                await build.value
            } onCancel: {
                build.cancel()
            }
            guard !Task.isCancelled, filesRevision == revision else { return }
            index = result
            indexRevision = revision
        }
        .task(
            id: QuickOpenSearchRequest(
                query: query, filesRevision: filesRevision, indexRevision: indexRevision)
        ) {
            guard let index, indexRevision == filesRevision, !query.isEmpty else {
                matches = []
                hasMoreMatches = false
                return
            }
            let request = query
            let revision = filesRevision
            let search = Task.detached(priority: .userInitiated) { index.search(request) }
            let result = await withTaskCancellationHandler {
                await search.value
            } onCancel: {
                search.cancel()
            }
            guard !Task.isCancelled, query == request, filesRevision == revision else { return }
            matches = result.files
            hasMoreMatches = result.hasMore
        }
        .onChange(of: query) { selectedIndex = 0 }
        .onExitCommand(perform: onDismiss)
        .accessibilityLabel(L10n.text("Quick Open"))
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(LoffoPalette.secondary)
            TextField(L10n.text("Search files by name"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit(openSelected)
                .onKeyPress(.downArrow) {
                    moveSelection(by: 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
                .accessibilityLabel(L10n.text("Search files by name"))
            Text(L10n.text("Escape"))
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(LoffoPalette.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(LoffoPalette.canvas, in: RoundedRectangle(cornerRadius: 4))
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(LoffoPalette.canvas, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(LoffoPalette.border, lineWidth: 1)
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            LoffoScrollView {
                LazyVStack(spacing: 2) {
                    if matches.isEmpty {
                        Text(
                            query.isEmpty ? L10n.text("Type to search files") : L10n.text("No matching files")
                        )
                        .font(.system(size: 11))
                        .foregroundStyle(LoffoPalette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                    } else {
                        ForEach(matches.indices, id: \.self) { index in
                            resultRow(matches[index].path, index: index)
                                .id(matches[index].path)
                        }
                    }
                    if hasMoreMatches {
                        Text(L10n.text("Showing the top 200 matches. Refine your search."))
                            .font(.system(size: 10))
                            .foregroundStyle(LoffoPalette.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                    }
                }
            }
            .frame(maxHeight: 360)
            .onChange(of: matches.count) {
                selectedIndex = min(selectedIndex, max(0, matches.count - 1))
            }
            .onChange(of: selectedPath) { _, path in
                guard let path else { return }
                // Scroll in the selection update itself so rapid key repeats cannot cancel the
                // reveal work for the last selected row. Without an anchor, visible rows stay put.
                proxy.scrollTo(path)
            }
        }
    }

    private func resultRow(_ path: String, index: Int) -> some View {
        Button {
            onOpen(path)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "doc")
                    .font(.system(size: 11))
                    .foregroundStyle(LoffoPalette.secondary)
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text((path as NSString).deletingLastPathComponent)
                    .font(.system(size: 10))
                    .foregroundStyle(LoffoPalette.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                index == selectedIndex ? LoffoPalette.selection : .clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { if $0 { selectedIndex = index } }
        .accessibilityLabel(path)
        .accessibilityValue(index == selectedIndex ? L10n.text("Selected") : L10n.text("Not selected"))
    }

    private func moveSelection(by amount: Int) {
        guard !matches.isEmpty else { return }
        selectedIndex = (selectedIndex + amount + matches.count) % matches.count
    }

    private func openSelected() {
        guard matches.indices.contains(selectedIndex) else { return }
        onOpen(matches[selectedIndex].path)
    }
}

private struct QuickOpenSearchRequest: Equatable {
    let query: String
    let filesRevision: UUID
    let indexRevision: UUID?
}
