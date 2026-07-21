import CAdw
import Foundation

/// Divider positions across restarts.
///
/// Stored as a **fraction** of the paned's extent, not pixels — the same
/// choice macOS makes (`SessionSplitLayoutSnapshot.dividerPosition`, read
/// back as `min(max(…, 0), 1)`). A pixel offset restored into a
/// differently sized window is simply wrong, and windows are routinely a
/// different size on the next launch.
///
/// Keyed by workspace and tree path, where a path is the sequence of
/// start/end choices from the root ("" is the root paned, "0" its start
/// child, "01" that child's end child). The same scheme the in-session
/// rebuild already uses, so the two cannot drift.
enum PaneDividers {

    /// The GtkStack holding one child per workspace. Set by the widget
    /// layer; the session layer has no other way to reach the tree.
    static var stack: OpaquePointer?

    /// Fractions read from the session file, consumed when a workspace's
    /// skeleton is first built.
    static var persisted: [UUID: [String: Double]] = [:]

    static func fraction(tabId: UUID, path: String) -> Double? {
        guard let value = persisted[tabId]?[path], value > 0, value < 1 else { return nil }
        return value
    }

    /// Live fractions for a workspace, walked out of the widget tree at
    /// save time. Empty when the workspace has no splits or is not built
    /// yet — callers simply store nothing.
    static func capture(tabId: UUID) -> [String: Double] {
        guard let stack, let root = gtk_stack_get_child_by_name(stack, tabId.uuidString) else {
            return [:]
        }
        var out: [String: Double] = [:]
        walk(root, path: "", into: &out)
        return out
    }

    private static func walk(
        _ widget: UnsafeMutablePointer<GtkWidget>?, path: String, into out: inout [String: Double]
    ) {
        guard let widget,
              g_type_check_instance_is_a(
                UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self),
                gtk_paned_get_type()
              ) != 0 else { return }
        let paned = OpaquePointer(widget)
        let horizontal = gtk_orientable_get_orientation(paned) == GTK_ORIENTATION_HORIZONTAL
        let total = horizontal ? gtk_widget_get_width(widget) : gtk_widget_get_height(widget)
        let position = gtk_paned_get_position(paned)
        // An unallocated paned reports 0; recording 0/0 would persist a
        // divider slammed to one edge.
        if total > 1, position > 0, position < total {
            out[path] = Double(position) / Double(total)
        }
        walk(gtk_paned_get_start_child(paned), path: path + "0", into: &out)
        walk(gtk_paned_get_end_child(paned), path: path + "1", into: &out)
    }
}

/// Carries a fraction into the tick callback, which may not capture.
final class DividerFractionBox {
    let fraction: Double
    init(fraction: Double) { self.fraction = fraction }
}

let dividerFractionBoxDestroy: GDestroyNotify = { data in
    guard let data else { return }
    Unmanaged<DividerFractionBox>.fromOpaque(data).release()
}

/// Applies a restored fraction once the paned actually has a size. A fresh
/// paned reports 0 until its first allocation, so the position cannot be
/// set at build time — the same reason the 50/50 balance uses a tick
/// callback.
let dividerApplyFraction: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, OpaquePointer?, UnsafeMutableRawPointer?
) -> gboolean = { widget, _, userData in
    guard let widget, let userData else { return gboolean(0) }
    let box = Unmanaged<DividerFractionBox>.fromOpaque(userData).takeUnretainedValue()
    let paned = OpaquePointer(widget)
    let horizontal = gtk_orientable_get_orientation(paned) == GTK_ORIENTATION_HORIZONTAL
    let total = horizontal ? gtk_widget_get_width(widget) : gtk_widget_get_height(widget)
    if total <= 1 { return gboolean(1) }   // not allocated yet — try again
    gtk_paned_set_position(paned, Int32(Double(total) * box.fraction))
    return gboolean(0)
}
