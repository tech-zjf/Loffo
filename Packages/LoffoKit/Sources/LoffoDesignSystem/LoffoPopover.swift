import SwiftUI

/// Shared visual surface used by anchored application panels.
public struct LoffoPopoverSurface<Content: View>: View {
    private let content: Content
    let edge: Edge
    private let maximumSize: CGSize

    public init(
        edge: Edge = .top, maximumSize: CGSize = CGSize(width: 420, height: 560),
        @ViewBuilder content: () -> Content
    ) {
        self.edge = edge
        self.maximumSize = maximumSize
        self.content = content()
    }

    private var tipAlignment: Alignment {
        switch edge {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    private var tipSize: CGSize {
        switch edge {
        case .top, .bottom: CGSize(width: 10, height: 5)
        case .leading, .trailing: CGSize(width: 5, height: 10)
        }
    }

    private var tipOffset: CGSize {
        switch edge {
        case .top: CGSize(width: 0, height: -4)
        case .bottom: CGSize(width: 0, height: 4)
        case .leading: CGSize(width: -4, height: 0)
        case .trailing: CGSize(width: 4, height: 0)
        }
    }

    public var body: some View {
        content
            .frame(maxWidth: maximumSize.width, maxHeight: maximumSize.height, alignment: .topLeading)
            .background(LoffoPalette.surface, in: RoundedRectangle(cornerRadius: LoffoMetrics.cardRadius))
            .overlay {
                RoundedRectangle(cornerRadius: LoffoMetrics.cardRadius)
                    .strokeBorder(LoffoPalette.border.opacity(0.7), lineWidth: 0.75)
            }
            .overlay(alignment: tipAlignment) {
                PopoverTip(edge: edge)
                    .fill(LoffoPalette.surface)
                    .frame(width: tipSize.width, height: tipSize.height)
                    .offset(tipOffset)
            }
            .padding(.leading, edge == .leading ? 5 : 0)
            .padding(.trailing, edge == .trailing ? 5 : 0)
            .padding(.top, edge == .top ? 5 : 0)
            .padding(.bottom, edge == .bottom ? 5 : 0)
            .frame(maxWidth: maximumSize.width + 5, maxHeight: maximumSize.height + 5)
            .clipped()
    }
}

private struct PopoverTip: Shape {
    let edge: Edge

    func path(in rect: CGRect) -> Path {
        var path = Path()
        switch edge {
        case .top:
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLines([CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
        case .bottom:
            path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLines([CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY)])
        case .leading, .trailing:
            let tip = edge == .leading ? rect.minX : rect.maxX
            let base = edge == .leading ? rect.maxX : rect.minX
            path.move(to: CGPoint(x: tip, y: rect.midY))
            path.addLines([CGPoint(x: base, y: rect.minY), CGPoint(x: base, y: rect.maxY)])
        }
        path.closeSubpath()
        return path
    }
}
