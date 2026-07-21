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

/// Visible bounds and neighbor data for one expanded workspace group.
struct SidebarWorkspaceReorderGroupLayout {
    let bounds: CGRect
    let anchorTarget: SidebarWorkspaceReorderDropTarget
    let nextRootTarget: SidebarWorkspaceReorderDropTarget?
}
