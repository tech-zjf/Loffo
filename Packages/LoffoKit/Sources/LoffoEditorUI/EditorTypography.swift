import AppKit
import LoffoDesignSystem

@MainActor enum EditorTypography {
    // Menlo's 12 pt advance matches the approved source text (~7.22 pt per character).
    static let code =
        NSFont(name: "Menlo-Regular", size: LoffoMetrics.codeSize)
        ?? NSFont.monospacedSystemFont(ofSize: LoffoMetrics.codeSize, weight: .regular)
    static let comment = NSFont(name: "Menlo-Italic", size: LoffoMetrics.codeSize) ?? code
    static let gutter =
        NSFont(name: "Menlo-Regular", size: 11)
        ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
}
