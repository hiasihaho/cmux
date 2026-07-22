import CAdw
import Foundation

/// Keyboard/UI commands that existed on macOS with no Linux way in:
/// directional pane focus, jump-to-unread, rename-workspace dialog,
/// open-folder dialog, and the flash ping. The socket verbs and the
/// window shortcuts share these implementations (shared-behavior rule:
/// one mutation path however the command is reached).
extension ControlCommandHandler {

    // MARK: directional pane focus

    /// Moves focus to the nearest pane in a direction, judged by real
    /// widget geometry — list order cannot express "the pane to the left"
    /// once splits nest. Returns false when nothing lies that way.
    @discardableResult
    func focusDirectional(_ direction: String) -> Bool {
        guard let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }),
              tab.zoomedSurfaceId == nil,   // zoom shows one pane; nowhere to go
              let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }),
              let focused = tab.focusedSurface else { return false }

        func center(of surfaceId: UUID) -> (x: Double, y: Double)? {
            guard let container = SurfaceRegistry.shared.containers[surfaceId] else { return nil }
            let widget = UnsafeMutablePointer<GtkWidget>(container)
            guard gtk_widget_get_mapped(widget) != 0,
                  let root = gtk_widget_get_root(widget) else { return nil }
            var bounds = graphene_rect_t()
            let rootWidget = UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWidget.self)
            guard gtk_widget_compute_bounds(widget, rootWidget, &bounds) != 0 else { return nil }
            return (
                Double(bounds.origin.x) + Double(bounds.size.width) / 2,
                Double(bounds.origin.y) + Double(bounds.size.height) / 2
            )
        }

        guard let origin = center(of: focused.surfaceId) else { return false }

        var best: (surfaceId: UUID, primary: Double, secondary: Double)?
        for pane in tab.panes where pane.paneId != focused.paneId {
            let visible = pane.surfaces[safe: pane.selectedIndex] ?? pane.surfaces[0]
            guard let candidate = center(of: visible.surfaceId) else { continue }
            let dx = candidate.x - origin.x
            let dy = candidate.y - origin.y
            // Primary = distance along the requested axis (must be forward);
            // secondary = drift on the other axis, the tie-breaker that
            // keeps "focus left" from jumping diagonally when a straight
            // neighbor exists.
            let (primary, secondary): (Double, Double)
            switch direction {
            case "left": (primary, secondary) = (-dx, abs(dy))
            case "right": (primary, secondary) = (dx, abs(dy))
            case "up": (primary, secondary) = (-dy, abs(dx))
            case "down": (primary, secondary) = (dy, abs(dx))
            default: return false
            }
            guard primary > 1 else { continue }   // strictly that way
            if let current = best {
                if primary + secondary * 2 < current.primary + current.secondary * 2 {
                    best = (visible.surfaceId, primary, secondary)
                }
            } else {
                best = (visible.surfaceId, primary, secondary)
            }
        }
        guard let best else { return false }
        tabs.wrappedValue[index].focusedSurfaceId = best.surfaceId
        refreshTitle(tabId: tab.id)
        return true
    }

    // MARK: jump to unread

    /// Selects the first workspace (sidebar order) that wants attention —
    /// an agent waiting for input or an unread notification.
    @discardableResult
    func jumpToUnread() -> Bool {
        let unreadTabIds = Set(notifications.wrappedValue.filter { !$0.isRead }.map(\.tabId))
        guard let target = tabs.wrappedValue.first(where: {
            ($0.needsAttention || unreadTabIds.contains($0.id)) && $0.id != selection.wrappedValue
        }) ?? tabs.wrappedValue.first(where: { $0.needsAttention || unreadTabIds.contains($0.id) })
        else { return false }
        select(target.id)
        return true
    }

    // MARK: flash

    /// Visual ping on a surface's pane (macOS `surface.trigger_flash`):
    /// dip the container's opacity briefly, twice. No CSS machinery — an
    /// opacity pulse reads clearly on terminals and browsers alike.
    @discardableResult
    func triggerFlash(tabId: UUID?, surfaceId: UUID?) -> Bool {
        let tab = tabs.wrappedValue.first { $0.id == (tabId ?? selection.wrappedValue) }
        guard let tab else { return false }
        let target = surfaceId ?? tab.focusedSurface?.surfaceId
        guard let target, let container = SurfaceRegistry.shared.containers[target] else {
            return false
        }
        let widget = UnsafeMutablePointer<GtkWidget>(container)
        func dip(_ delayMs: UInt32) {
            scheduleOnMainLoop(afterMs: delayMs) { gtk_widget_set_opacity(widget, 0.35) }
            scheduleOnMainLoop(afterMs: delayMs + 130) { gtk_widget_set_opacity(widget, 1.0) }
        }
        dip(0)
        dip(280)
        return true
    }

    // MARK: dialog-backed mutations (same paths as the socket verbs)

    func renameWorkspace(tabId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) else { return }
        tabs.wrappedValue[index].customTitle = trimmed
        tabs.wrappedValue[index].title = trimmed
    }

    func newWorkspace(cwd: String) {
        tabCounter.wrappedValue += 1
        let tab = TerminalTab(title: "Terminal \(tabCounter.wrappedValue)", workingDirectory: cwd)
        tabs.wrappedValue.append(tab)
        select(tab.id)
    }

    // MARK: surface.focus (parity verb)

    /// Focus a specific surface: selects its workspace, raises its pane
    /// tab when it is a background tab, and moves pane focus.
    func v2SurfaceFocus(id: Any?, params: [String: Any]) -> String {
        guard let raw = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
              let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: surfaceId) }),
              let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        if selection.wrappedValue != tab.id {
            select(tab.id)
        }
        // A background tab in its pane must come to the front, or focus
        // lands on a hidden widget.
        selectSurfaceTab(tabId: tab.id, surfaceId: surfaceId)
        tabs.wrappedValue[index].focusedSurfaceId = surfaceId
        refreshTitle(tabId: tab.id)
        return v2Ok(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "surface_id": surfaceId.uuidString
        ])
    }

    // MARK: verbs found missing by the capabilities sweep (quiet renames)

    func v2NotificationJumpToUnread(id: Any?) -> String {
        guard jumpToUnread() else {
            return v2Error(id: id, code: "not_found", message: "No unread notifications")
        }
        return v2Ok(id: id, result: [
            "workspace_id": selection.wrappedValue.uuidString,
            "jumped": true
        ])
    }

    /// `all` / `tab_id` (+ optional `surface_id`) — marks matching
    /// notifications read and clears the workspace attention dot, the same
    /// state selecting the workspace clears.
    func v2NotificationMarkRead(id: Any?, params: [String: Any]) -> String {
        var tabId: UUID?
        if let raw = params["tab_id"] as? String ?? params["workspace_id"] as? String {
            tabId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        }
        var surfaceId: UUID?
        if let raw = params["surface_id"] as? String {
            surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        }
        var notificationId: UUID?
        if let raw = params["id"] as? String {
            notificationId = UUID(uuidString: raw)
        }
        let all = (params["all"] as? Bool) ?? false
        guard all || tabId != nil || notificationId != nil else {
            return v2Error(id: id, code: "invalid_params", message: "mark_read requires id, all, or a workspace")
        }
        var marked = 0
        notifications.wrappedValue = notifications.wrappedValue.map { notification in
            guard all
                || (notificationId != nil && notification.id == notificationId)
                || (tabId != nil && notification.tabId == tabId
                    && (surfaceId == nil || notification.surfaceId == surfaceId)) else {
                return notification
            }
            var copy = notification
            if !copy.isRead { marked += 1 }
            copy.isRead = true
            return copy
        }
        for (index, tab) in tabs.wrappedValue.enumerated()
        where all || (tabId != nil && tab.id == tabId) {
            tabs.wrappedValue[index].needsAttention = false
            DesktopNotifier.withdraw(id: "cmux-\(tab.id.uuidString)")
        }
        return v2Ok(id: id, result: ["marked_read": marked])
    }

    /// `id` removes one notification; `all_read: true` sweeps the read ones.
    func v2NotificationDismiss(id: Any?, params: [String: Any]) -> String {
        if (params["all_read"] as? Bool) == true {
            let before = notifications.wrappedValue.count
            notifications.wrappedValue.removeAll { $0.isRead }
            return v2Ok(id: id, result: ["dismissed": before - notifications.wrappedValue.count])
        }
        guard let raw = params["id"] as? String, let target = UUID(uuidString: raw) else {
            return v2Error(id: id, code: "invalid_params", message: "dismiss requires id or all_read")
        }
        guard let index = notifications.wrappedValue.firstIndex(where: { $0.id == target }) else {
            return v2Error(id: id, code: "not_found", message: "Notification not found")
        }
        notifications.wrappedValue.remove(at: index)
        return v2Ok(id: id, result: ["dismissed": 1])
    }

    /// Jumps to a notification's workspace (and surface, when it has one)
    /// and marks it read — the sidebar row's click, as a verb.
    func v2NotificationOpen(id: Any?, params: [String: Any]) -> String {
        guard let raw = params["id"] as? String, let target = UUID(uuidString: raw),
              let index = notifications.wrappedValue.firstIndex(where: { $0.id == target }) else {
            return v2Error(id: id, code: "not_found", message: "Notification not found")
        }
        let notification = notifications.wrappedValue[index]
        guard let tabIndex = tabs.wrappedValue.firstIndex(where: { $0.id == notification.tabId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace no longer exists")
        }
        select(notification.tabId)
        if let surfaceId = notification.surfaceId,
           tabs.wrappedValue[tabIndex].contains(surfaceId: surfaceId) {
            selectSurfaceTab(tabId: notification.tabId, surfaceId: surfaceId)
            tabs.wrappedValue[tabIndex].focusedSurfaceId = surfaceId
        }
        notifications.wrappedValue[index].isRead = true
        return v2Ok(id: id, result: [
            "workspace_id": notification.tabId.uuidString,
            "opened": true
        ])
    }

    func v2WindowCurrent(id: Any?) -> String {
        v2Ok(id: id, result: [
            "id": ControlCommandHandler.windowId.uuidString,
            "ref": RefRegistry.shared.ref(kind: "window", uuid: ControlCommandHandler.windowId)
        ])
    }

    /// Present the (single) window — an explicit focus-intent verb, same
    /// policy class as workspace.select.
    func v2WindowFocus(id: Any?) -> String {
        if let window = UIDialogs.mainWindowWidget() {
            gtk_window_present(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
        }
        return v2Ok(id: id, result: ["focused": true])
    }

    func v2SurfaceTriggerFlash(id: Any?, params: [String: Any]) -> String {
        var tabId: UUID?
        if let raw = params["workspace_id"] as? String {
            tabId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        }
        var surfaceId: UUID?
        if let raw = params["surface_id"] as? String {
            surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        }
        guard triggerFlash(tabId: tabId, surfaceId: surfaceId) else {
            return v2Error(id: id, code: "not_found", message: "No surface to flash")
        }
        return v2Ok(id: id, result: ["flashed": true])
    }
}

// MARK: - dialogs (raw GTK; adwaita-swift has no text-input alert)

enum UIDialogs {

    /// Rename-workspace dialog (F2): an AdwAlertDialog with a text entry,
    /// prefilled with the current title. Confirming pins the custom title
    /// exactly like `workspace.rename` over the socket.
    static func renameWorkspace(
        currentTitle: String,
        onRename: @escaping (String) -> Void
    ) {
        guard let dialog = adw_alert_dialog_new("Rename Workspace", nil) else { return }
        let alert = UnsafeMutableRawPointer(dialog).assumingMemoryBound(to: AdwAlertDialog.self)
        adw_alert_dialog_add_response(alert, "cancel", "Cancel")
        adw_alert_dialog_add_response(alert, "rename", "Rename")
        adw_alert_dialog_set_response_appearance(alert, "rename", ADW_RESPONSE_SUGGESTED)
        adw_alert_dialog_set_default_response(alert, "rename")
        adw_alert_dialog_set_close_response(alert, "cancel")

        guard let entry = gtk_entry_new() else { return }
        gtk_editable_set_text(OpaquePointer(entry), currentTitle)
        gtk_editable_select_region(OpaquePointer(entry), 0, -1)
        // Enter in the entry activates the default (Rename) response.
        gtk_entry_set_activates_default(
            UnsafeMutableRawPointer(entry).assumingMemoryBound(to: GtkEntry.self), 1)
        adw_alert_dialog_set_extra_child(alert, entry)

        let box = RenameDialogBox(entry: entry, onRename: onRename)
        g_signal_connect_data(
            UnsafeMutableRawPointer(dialog), "response",
            unsafeBitCast(renameDialogResponse, to: GCallback.self),
            Unmanaged.passRetained(box).toOpaque(),
            renameDialogBoxDestroy, GConnectFlags(0)
        )
        let dialogPtr = UnsafeMutableRawPointer(dialog).assumingMemoryBound(to: AdwDialog.self)
        // Initial focus must be the ENTRY, not the suggested button —
        // otherwise F2-then-type goes to whatever was focused before.
        adw_dialog_set_focus(dialogPtr, entry)
        adw_dialog_present(dialogPtr, mainWindowWidget())
    }

    /// Open-folder dialog (Ctrl+Shift+O): GtkFileDialog folder picker; the
    /// chosen directory becomes a new workspace's cwd — macOS `openFolder`.
    static func openFolder(onOpen: @escaping (String) -> Void) {
        guard let dialog = gtk_file_dialog_new() else { return }
        gtk_file_dialog_set_title(dialog, "Open Folder as Workspace")
        let box = OpenFolderBox(dialog: dialog, onOpen: onOpen)
        let window: UnsafeMutablePointer<GtkWindow>? = mainWindowWidget().map {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWindow.self)
        }
        gtk_file_dialog_select_folder(
            dialog, window, nil,
            openFolderFinished,
            Unmanaged.passRetained(box).toOpaque()
        )
    }

    /// The application's main window, for dialog parenting.
    static func mainWindowWidget() -> UnsafeMutablePointer<GtkWidget>? {
        guard let application = g_application_get_default() else { return nil }
        let gtkApplication = UnsafeMutableRawPointer(application)
            .assumingMemoryBound(to: GtkApplication.self)
        guard let list = gtk_application_get_windows(gtkApplication),
              let data = list.pointee.data else { return nil }
        return data.assumingMemoryBound(to: GtkWidget.self)
    }
}

final class RenameDialogBox {
    let entry: UnsafeMutablePointer<GtkWidget>
    let onRename: (String) -> Void
    init(entry: UnsafeMutablePointer<GtkWidget>, onRename: @escaping (String) -> Void) {
        self.entry = entry
        self.onRename = onRename
    }
}

let renameDialogBoxDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<RenameDialogBox>.fromOpaque(data).release()
}

let renameDialogResponse: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { _, response, userData in
    guard let response, String(cString: response) == "rename",
          let userData else { return }
    let box = Unmanaged<RenameDialogBox>.fromOpaque(userData).takeUnretainedValue()
    guard let raw = gtk_editable_get_text(OpaquePointer(box.entry)) else { return }
    let title = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { return }
    box.onRename(title)
}

final class OpenFolderBox {
    let dialog: OpaquePointer
    let onOpen: (String) -> Void
    init(dialog: OpaquePointer, onOpen: @escaping (String) -> Void) {
        self.dialog = dialog
        self.onOpen = onOpen
    }
}

let openFolderFinished: GAsyncReadyCallback = { _, result, userData in
    guard let userData else { return }
    let box = Unmanaged<OpenFolderBox>.fromOpaque(userData).takeRetainedValue()
    guard let result,
          let file = gtk_file_dialog_select_folder_finish(box.dialog, result, nil),
          let path = g_file_get_path(file) else { return }
    defer { g_free(path) }
    box.onOpen(String(cString: path))
}
