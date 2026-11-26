import SwiftUI

/// Shared presentation chrome for anchored application panels.
public struct LoffoPopoverSurface<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) { self.content = content() }

    public var body: some View {
        content
            .background(LoffoPalette.surface)
            .clipShape(RoundedRectangle(cornerRadius: LoffoMetrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: LoffoMetrics.cardRadius)
                    .strokeBorder(LoffoPalette.border.opacity(0.55), lineWidth: 0.75)
            }
            .presentationBackground(LoffoPalette.surface)
            .presentationCornerRadius(LoffoMetrics.cardRadius)
    }
}

private struct LoffoPopoverModifier<Panel: View>: ViewModifier {
    @Binding var isPresented: Bool
    let arrowEdge: Edge
    let panel: () -> Panel

    func body(content: Content) -> some View {
        content.popover(isPresented: $isPresented, arrowEdge: arrowEdge) {
            LoffoPopoverSurface(content: panel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension View {
    /// Uses native positioning and dismissal while keeping application-owned panel styling.
    public func loffoPopover<Content: View>(
        isPresented: Binding<Bool>, arrowEdge: Edge = .top, @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        modifier(LoffoPopoverModifier(isPresented: isPresented, arrowEdge: arrowEdge, panel: content))
    }
}
