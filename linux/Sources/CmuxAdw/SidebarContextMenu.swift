import CVte
import Foundation

/// Right-click context menus for sidebar rows (comfort mirror ③,
/// MACOS-UX §4). One window-level GtkGestureClick (button 3, bubble
/// phase — terminal/browser panes consume their own right-clicks first)
/// picks the widget under the pointer; if it is a row of the
/// navigation-sidebar list, a popover of flat buttons opens for it.
/// Menu CONTENT comes from `SidebarContextMenuModel.items` — the same
/// pure projection `debug.sidebar_menu` serves, so suite assertions on
/// the verb are assertions on what the popover shows. Actions route
/// through the closures CmuxApp wires to the shared v2 paths.
enum SidebarContextMenu {

    /// Current row snapshot (the sidebar projection), refreshed by the
    /// scene body on every render — the popover reads it at open time.
    static var rowsProvider: () -> [SidebarRowModel] = { [] }
    static var workspaceCountProvider: () -> Int = { 0 }
    /// Menu action → (item id, row). Wired by CmuxApp.
    static var onAction: ((String, SidebarRowModel) -> Void)?

    private static var installed = false

    /// Idempotent; called from the scene body once a window exists —
    /// the AttentionStyle.install idiom.
    static func install() {
        guard !installed, let window = UIDialogs.mainWindowWidget() else { return }
        installed = true
        // GtkGesture* types do not cross the C importer — the pointers
        // stay opaque, like GtkStyleProvider in AttentionStyle.
        guard let gesture = gtk_gesture_click_new() else { return }
        gtk_gesture_single_set_button(gesture, 3)
        g_signal_connect_data(
            UnsafeMutableRawPointer(gesture), "pressed",
            unsafeBitCast(sidebarContextMenuPressed, to: GCallback.self),
            UnsafeMutableRawPointer(window), nil, GConnectFlags(0)
        )
        gtk_widget_add_controller(window, gesture)
    }

    /// Resolves a press at window coordinates to a sidebar row index,
    /// or nil when the press is anywhere else.
    static func rowIndex(
        inWindow window: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double
    ) -> Int? {
        guard let picked = gtk_widget_pick(window, x, y, GTK_PICK_DEFAULT) else { return nil }
        guard let rowWidget = gtk_widget_get_ancestor(picked, gtk_list_box_row_get_type()) else {
            return nil
        }
        // Only the workspace sidebar's list — not the notifications list
        // or any future ListBox.
        guard let list = gtk_widget_get_parent(rowWidget),
              gtk_widget_has_css_class(list, "navigation-sidebar") != 0 else { return nil }
        let index = gtk_list_box_row_get_index(
            UnsafeMutableRawPointer(rowWidget).assumingMemoryBound(to: GtkListBoxRow.self))
        return index >= 0 ? Int(index) : nil
    }

    /// Builds and pops the menu for `row`, parented to the row's widget.
    static func present(
        row: SidebarRowModel,
        rowWidget: UnsafeMutablePointer<GtkWidget>
    ) {
        let items = SidebarContextMenuModel.items(
            for: row, workspaceCount: workspaceCountProvider())
        guard !items.isEmpty,
              let popover = gtk_popover_new(),
              let list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2) else { return }
        for item in items {
            guard let button = gtk_button_new_with_label(item.title) else { continue }
            gtk_widget_add_css_class(button, "flat")
            if item.destructive { gtk_widget_add_css_class(button, "error") }
            gtk_widget_set_sensitive(button, item.enabled ? 1 : 0)
            if let label = gtk_button_get_child(
                UnsafeMutableRawPointer(button).assumingMemoryBound(to: GtkButton.self)
            ) {
                gtk_widget_set_halign(label, GTK_ALIGN_START)
            }
            let box = SidebarMenuChoice(itemId: item.id, row: row, popover: popover)
            g_signal_connect_data(
                UnsafeMutableRawPointer(button), "clicked",
                unsafeBitCast(sidebarMenuItemClicked, to: GCallback.self),
                Unmanaged.passRetained(box).toOpaque(),
                sidebarMenuChoiceDestroy, GConnectFlags(0)
            )
            gtk_box_append(
                UnsafeMutableRawPointer(list).assumingMemoryBound(to: GtkBox.self), button)
        }
        gtk_widget_set_parent(popover, rowWidget)
        let popoverPtr = UnsafeMutableRawPointer(popover).assumingMemoryBound(to: GtkPopover.self)
        gtk_popover_set_child(popoverPtr, list)
        // Tear the popover down when it closes; it was created per-open.
        g_signal_connect_data(
            UnsafeMutableRawPointer(popover), "closed",
            unsafeBitCast(sidebarMenuPopoverClosed, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        gtk_popover_popup(popoverPtr)
    }
}

/// One menu row's target.
final class SidebarMenuChoice {
    let itemId: String
    let row: SidebarRowModel
    let popover: UnsafeMutablePointer<GtkWidget>
    init(itemId: String, row: SidebarRowModel, popover: UnsafeMutablePointer<GtkWidget>) {
        self.itemId = itemId
        self.row = row
        self.popover = popover
    }
}

let sidebarMenuChoiceDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<SidebarMenuChoice>.fromOpaque(data).release()
}

let sidebarContextMenuPressed: @convention(c) (
    UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?
) -> Void = { _, _, x, y, userData in
    guard let userData else { return }
    let window = userData.assumingMemoryBound(to: GtkWidget.self)
    guard let index = SidebarContextMenu.rowIndex(inWindow: window, x: x, y: y) else { return }
    let rows = SidebarContextMenu.rowsProvider()
    guard rows.indices.contains(index) else { return }
    // Re-pick the row widget to parent the popover on it.
    guard let picked = gtk_widget_pick(window, x, y, GTK_PICK_DEFAULT),
          let rowWidget = gtk_widget_get_ancestor(picked, gtk_list_box_row_get_type()) else {
        return
    }
    SidebarContextMenu.present(row: rows[index], rowWidget: rowWidget)
}

let sidebarMenuItemClicked: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, userData in
    guard let userData else { return }
    let choice = Unmanaged<SidebarMenuChoice>.fromOpaque(userData).takeUnretainedValue()
    gtk_popover_popdown(
        UnsafeMutableRawPointer(choice.popover).assumingMemoryBound(to: GtkPopover.self))
    SidebarContextMenu.onAction?(choice.itemId, choice.row)
}

/// Unparent on close so per-open popovers do not accumulate on the row.
let sidebarMenuPopoverClosed: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { popoverPtr, _ in
    guard let popoverPtr else { return }
    let widget = popoverPtr.assumingMemoryBound(to: GtkWidget.self)
    scheduleOnMainLoop(afterMs: 1) {
        gtk_widget_unparent(widget)
    }
}
