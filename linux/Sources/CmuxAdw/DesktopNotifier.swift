import CVte
import Foundation

/// XDG desktop notifications via GNotification — the Linux counterpart of
/// `UNUserNotificationCenter` delivery in the macOS TerminalNotificationStore.
///
/// Note: GNOME only displays GNotifications for applications with a
/// `.desktop` file matching the application id (com.manaflow.cmux.desktop);
/// `linux/scripts/install-desktop-entry.sh` installs one per user.
enum DesktopNotifier {

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
