import CVte
import Foundation

/// XDG desktop notifications via GNotification — the Linux counterpart of
/// `UNUserNotificationCenter` delivery in the macOS TerminalNotificationStore.
///
/// Note: GNOME only displays GNotifications for applications with a
/// `.desktop` file matching the application id (com.manaflow.cmux.desktop);
/// `linux/scripts/install-desktop-entry.sh` installs one per user.
enum DesktopNotifier {

    /// True while the sidebar shows the notifications page. Set by the UI
    /// toggle; read by the suppression rules below.
    static var notificationsPanelVisible = false

    /// The full macOS suppression contract (docs/notifications, mirrored in
    /// kb/notifications-contract.md): a desktop alert is suppressed when
    /// (a) the sending workspace is the selected one, (b) the cmux window
    /// itself has keyboard focus, or (c) the notification panel is open —
    /// in all three the user already has an in-app signal (badge, panel
    /// row, pane ring). Rule (a) existed since phase 3; (b) and (c) landed
    /// 2026-07-23 with this single decision path replacing three inline
    /// copies of rule (a), per the shared-behavior rule.
    ///
    /// The outcome breadcrumb is deliberate: suites (and `journalctl`-less
    /// debugging) can assert WHICH rule fired without observing the
    /// desktop itself.
    static func deliver(tabId: UUID, selection: UUID, title: String, body: String) {
        let outcome: String
        if tabId == selection {
            outcome = "suppressed(workspace_active)"
        } else if mainWindowIsActive {
            outcome = "suppressed(window_focused)"
        } else if notificationsPanelVisible {
            outcome = "suppressed(panel_open)"
        } else {
            outcome = "sent"
            send(id: "cmux-\(tabId.uuidString)", title: title, body: body)
        }
        FileHandle.standardError.write(Data("cmux: desktop notify \(outcome)\n".utf8))
    }

    /// Whether the app's window currently has keyboard focus. False under
    /// a bare Xvfb (no WM assigns focus), which keeps the suites on the
    /// "sent" path for the rules they assert.
    private static var mainWindowIsActive: Bool {
        guard let window = UIDialogs.mainWindowWidget() else { return false }
        return gtk_window_is_active(
            UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self)
        ) != 0
    }

    static func send(id: String, title: String, body: String) {
        guard let app = g_application_get_default(),
              let notification = g_notification_new(title) else { return }
        if !body.isEmpty {
            g_notification_set_body(notification, body)
        }
        g_application_send_notification(app, id, notification)
        g_object_unref(UnsafeMutableRawPointer(notification))
    }

    /// Removes a previously sent desktop notification (e.g. when its
    /// workspace closes — a popup for a dead workspace helps nobody).
    static func withdraw(id: String) {
        guard let app = g_application_get_default() else { return }
        g_application_withdraw_notification(app, id)
    }
}
