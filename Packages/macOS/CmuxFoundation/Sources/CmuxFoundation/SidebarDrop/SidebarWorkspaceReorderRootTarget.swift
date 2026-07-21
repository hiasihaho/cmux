#if canImport(CoreGraphics)
#if canImport(CoreGraphics)
import CoreGraphics
#else
public import Foundation
#endif
#else
public import Foundation
#endif
import Foundation

/// Root-level insertion target derived from visible sidebar rows.
struct SidebarWorkspaceReorderRootTarget {
    let workspaceId: UUID?
    let edge: SidebarDropEdge
    let pointerY: CGFloat?
    let targetHeight: CGFloat?
    let indicator: SidebarDropIndicator?
    let indicatorScope: SidebarWorkspaceReorderDropIndicatorScope
}
