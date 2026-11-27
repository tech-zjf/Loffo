import LoffoDesignSystem
import LoffoDomain
import LoffoEditorUI
import SwiftUI

struct SideBySideDiffView: View {
    let presentation: CodePresentation
    let navigation: CodeNavigation?
    let hunkCursor: Int
    let accessibilityName: String
    let syntaxTheme: EditorSyntaxTheme

    @State private var viewport = LinkedEditorViewport()

    private var comparison: DiffResult? { presentation.diff }
    private var projection: SideBySideProjection? { presentation.sideBySide }

    private func column(_ value: SideBySideColumn) -> CodePresentation {
        CodePresentation(
            text: value.text, syntax: value.syntax, diff: comparison, rows: value.rows,
            hunkStarts: projection?.hunkStarts ?? [], id: presentation.id)
    }

    private var splitNavigation: CodeNavigation? {
        guard let navigation, let starts = projection?.hunkStarts, !starts.isEmpty else { return nil }
        return CodeNavigation(line: starts[min(hunkCursor, starts.count - 1)], id: navigation.id)
    }

    var body: some View {
        Group {
            if let projection {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        heading("Before")
                        Rectangle().fill(LoffoPalette.border).frame(width: 1)
                        heading("After")
                    }.frame(height: 24)
                    HStack(spacing: 0) {
                        CodeEditor(
                            presentation: column(projection.before),
                            navigation: splitNavigation, accessibilityName: "Before \(accessibilityName)",
                            syntaxTheme: syntaxTheme, diffSide: .before, viewportLink: viewport)
                        Rectangle().fill(LoffoPalette.border).frame(width: 1)
                        CodeEditor(
                            presentation: column(projection.after),
                            navigation: splitNavigation, accessibilityName: "After \(accessibilityName)",
                            syntaxTheme: syntaxTheme, diffSide: .after, viewportLink: viewport)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    L10n.text("Side-by-side view unavailable"), systemImage: "rectangle.split.2x1",
                    description: Text(
                        L10n.text("The comparison could not be aligned within its work budget."))
                )
            }
        }
        .background(LoffoPalette.comparisonSurface)
    }

    private func heading(_ title: String) -> some View {
        Text(L10n.text(title))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(LoffoPalette.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .padding(.leading, 12)
            .overlay(alignment: .bottom) { LoffoPalette.border.frame(height: 0.5) }
    }
}
