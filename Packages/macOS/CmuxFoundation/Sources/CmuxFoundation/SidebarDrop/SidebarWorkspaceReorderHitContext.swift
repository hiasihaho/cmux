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

/// Row hit-test context used while resolving a workspace reorder drag.
struct SidebarWorkspaceReorderHitContext {
    let target: SidebarWorkspaceReorderDropTarget?
    let previousTarget: SidebarWorkspaceReorderDropTarget?
    let nextTarget: SidebarWorkspaceReorderDropTarget?
    let edge: SidebarDropEdge
    let pointerY: CGFloat?
    let targetHeight: CGFloat?
}
