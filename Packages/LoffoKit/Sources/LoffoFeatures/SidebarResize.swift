import Foundation

struct SidebarResizeResolution: Equatable {
    let width: CGFloat
    let isCollapsed: Bool
}

enum SidebarResize {
    static let minimumWidth: CGFloat = 220
    static let collapseDragThreshold: CGFloat = 20

    static func resolve(startWidth: CGFloat, translation: CGFloat, maximumWidth: CGFloat)
        -> SidebarResizeResolution
    {
        let targetWidth = startWidth + translation
        guard targetWidth > minimumWidth - collapseDragThreshold else {
            return SidebarResizeResolution(width: 0, isCollapsed: true)
        }
        return SidebarResizeResolution(
            width: min(max(minimumWidth, targetWidth), maximumWidth), isCollapsed: false)
    }
}
