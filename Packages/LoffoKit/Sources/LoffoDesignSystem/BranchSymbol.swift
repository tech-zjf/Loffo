import SwiftUI

/// Three-node branch outline used by the approved workspace navigation.
public struct BranchSymbol: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width / 16, y: rect.minY + y * rect.height / 18)
        }
        var connections = Path()
        connections.move(to: point(4, 4.25))
        connections.addLine(to: point(4, 13.75))
        connections.move(to: point(4, 10))
        connections.addLine(to: point(9, 10))
        connections.addQuadCurve(to: point(13, 7.75), control: point(13, 10))
        var result = connections.strokedPath(
            StrokeStyle(lineWidth: 1.35, lineCap: .round, lineJoin: .round))
        for center in [point(4, 2.5), point(4, 15.5), point(13, 6)] {
            result.addEllipse(
                in: CGRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2))
        }
        return result
    }
}
