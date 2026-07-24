import CVte
import Foundation

/// Sidebar drag-and-drop (comfort mirror ⑥, MACOS-UX §3.2): drag a
/// workspace row to reorder it, drop it inside a group's run to join,
/// drop it above a header to leave/stay top-level, drag a header to move
/// the whole group. The DROP mutates through the SAME
/// `applyWorkspaceReorder` core as the `workspace.reorder` verb.
///
/// Mechanics: a sync pass (scene-body idiom, widget writes only) attaches
/// one GtkDragSource per row — once, marked with g_object data — and one
/// GtkDropTarget on the list. The drag payload is the row's workspace
/// UUID string; row identity is resolved at drag time from the row's
/// index into the same projection the List renders.
enum SidebarDnD {

    /// G_TYPE_STRING — the macro does not cross the C importer; the
    /// fundamental type is registered as "gchararray".
    static let stringType: GType = g_type_from_name("gchararray")

    /// Refreshed by the scene body — the drag/drop callbacks read these.
    static var rowsProvider: () -> [SidebarRowModel] = { [] }
    /// Drop commit → (dragged workspace id, neighbor id, before?).
    static var onReorder: ((UUID, UUID, Bool) -> Void)?

    private static let attachedKey = "cmux-dnd-attached"
    private static var dropTargetAttached = false

    /// Row under the pointer currently carrying a drop-indicator class.
    static var indicatorRow: UnsafeMutablePointer<GtkWidget>?

    static func sync(active: Bool) {
        guard active, let list = SidebarColorStyle.listBox() else { return }
        if !dropTargetAttached {
            dropTargetAttached = true
            attachDropTarget(to: list)
        }
        var index: Int32 = 0
        while let row = gtk_list_box_get_row_at_index(OpaquePointer(list), index) {
            index += 1
            let widget = UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkWidget.self)
            if g_object_get_data(
                UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self),
                attachedKey
            ) != nil { continue }
            g_object_set_data(
                UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self),
                attachedKey,
                UnsafeMutableRawPointer(bitPattern: 1)
            )
            guard let source = gtk_drag_source_new() else { continue }
            gtk_drag_source_set_actions(source, GDK_ACTION_MOVE)
            g_signal_connect_data(
                UnsafeMutableRawPointer(source), "prepare",
                unsafeBitCast(sidebarDragPrepare, to: GCallback.self),
                nil, nil, GConnectFlags(0)
            )
            g_signal_connect_data(
                UnsafeMutableRawPointer(source), "drag-begin",
                unsafeBitCast(sidebarDragBegin, to: GCallback.self),
                nil, nil, GConnectFlags(0)
            )
            g_signal_connect_data(
                UnsafeMutableRawPointer(source), "drag-end",
                unsafeBitCast(sidebarDragEnd, to: GCallback.self),
                nil, nil, GConnectFlags(0)
            )
            gtk_widget_add_controller(widget, source)
        }
    }

    private static func attachDropTarget(to list: UnsafeMutablePointer<GtkWidget>) {
        guard let target = gtk_drop_target_new(SidebarDnD.stringType, GDK_ACTION_MOVE) else { return }
        g_signal_connect_data(
            UnsafeMutableRawPointer(target), "motion",
            unsafeBitCast(sidebarDropMotion, to: GCallback.self),
            UnsafeMutableRawPointer(list), nil, GConnectFlags(0)
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(target), "leave",
            unsafeBitCast(sidebarDropLeave, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(target), "drop",
            unsafeBitCast(sidebarDropCommit, to: GCallback.self),
            UnsafeMutableRawPointer(list), nil, GConnectFlags(0)
        )
        gtk_widget_add_controller(list, target)
    }

    static func clearIndicator() {
        if let row = indicatorRow {
            gtk_widget_remove_css_class(row, "cmux-drop-before")
            gtk_widget_remove_css_class(row, "cmux-drop-after")
        }
        indicatorRow = nil
    }

    /// (row, before-half) under a list-relative y, from the live rows.
    static func dropSlot(
        list: UnsafeMutablePointer<GtkWidget>, y: Double
    ) -> (row: UnsafeMutablePointer<GtkWidget>, index: Int, before: Bool)? {
        guard let row = gtk_list_box_get_row_at_y(OpaquePointer(list), Int32(y)) else {
            return nil
        }
        let widget = UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkWidget.self)
        let index = Int(gtk_list_box_row_get_index(row))
        var bounds = graphene_rect_t()
        var before = true
        if gtk_widget_compute_bounds(widget, list, &bounds) != 0 {
            let mid = Double(bounds.origin.y) + Double(bounds.size.height) / 2
            before = y < mid
        }
        return (widget, index, before)
    }
}

/// prepare: payload = the dragged row's workspace UUID string.
let sidebarDragPrepare: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?
) -> UnsafeMutablePointer<GdkContentProvider>? = { source, _, _, _ in
    guard let source,
          let widget = gtk_event_controller_get_widget(
              OpaquePointer(source)) else { return nil }
    let index = Int(gtk_list_box_row_get_index(
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkListBoxRow.self)))
    let rows = SidebarDnD.rowsProvider()
    guard rows.indices.contains(index) else { return nil }
    var value = GValue()
    _ = g_value_init(&value, SidebarDnD.stringType)
    g_value_set_string(&value, rows[index].id.uuidString)
    defer { g_value_unset(&value) }
    return gdk_content_provider_new_for_value(&value)
}

let sidebarDragBegin: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { source, _, _ in
    guard let source,
          let widget = gtk_event_controller_get_widget(OpaquePointer(source)) else { return }
    gtk_widget_add_css_class(widget, "cmux-dragging")
}

let sidebarDragEnd: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?
) -> Void = { source, _, _, _ in
    guard let source,
          let widget = gtk_event_controller_get_widget(OpaquePointer(source)) else { return }
    gtk_widget_remove_css_class(widget, "cmux-dragging")
    SidebarDnD.clearIndicator()
}

/// motion: paint the before/after indicator on the hovered row.
let sidebarDropMotion: @convention(c) (
    UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?
) -> UInt32 = { _, _, y, userData in
    guard let userData else { return 0 }
    let list = userData.assumingMemoryBound(to: GtkWidget.self)
    SidebarDnD.clearIndicator()
    guard let slot = SidebarDnD.dropSlot(list: list, y: y) else { return 0 }
    gtk_widget_add_css_class(slot.row, slot.before ? "cmux-drop-before" : "cmux-drop-after")
    SidebarDnD.indicatorRow = slot.row
    return GDK_ACTION_MOVE.rawValue
}

let sidebarDropLeave: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, _ in
    SidebarDnD.clearIndicator()
}

/// drop: resolve dragged + neighbor, hand to the shared reorder path.
let sidebarDropCommit: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutablePointer<GValue>?, Double, Double,
    UnsafeMutableRawPointer?
) -> Int32 = { _, value, _, y, userData in
    SidebarDnD.clearIndicator()
    guard let value, let userData,
          let raw = g_value_get_string(value),
          let draggedId = UUID(uuidString: String(cString: raw)) else { return 0 }
    let list = userData.assumingMemoryBound(to: GtkWidget.self)
    guard let slot = SidebarDnD.dropSlot(list: list, y: y) else { return 0 }
    let rows = SidebarDnD.rowsProvider()
    guard rows.indices.contains(slot.index) else { return 0 }
    let neighbor = rows[slot.index].id
    guard neighbor != draggedId else { return 1 }
    SidebarDnD.onReorder?(draggedId, neighbor, slot.before)
    return 1
}
