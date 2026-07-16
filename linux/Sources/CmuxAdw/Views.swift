import Adwaita
import Foundation

/// Vertical tab list — the Linux counterpart of cmux's sidebar with
/// notification rings. Tabs needing attention get a leading dot marker.
struct SidebarView: View {
    var tabs: [TerminalTab]
    @Binding var selection: UUID

    var view: Body {
        ScrollView {
            List(tabs, id: \.id, selection: $selection) { tab in
                Text(tab.needsAttention ? "●  \(tab.title)" : tab.title)
                    .halign(.start)
                    .padding(10)
            }
            .style("navigation-sidebar")
        }
        .vexpand()
    }
}

/// The sidebar's notifications page — Linux counterpart of the macOS
/// `NotificationsPage`. Clicking a row jumps to its workspace (marking its
/// notifications read, like focus does on macOS).
struct NotificationsListView: View {
    var notifications: [TerminalNotification]
    var open: (TerminalNotification) -> Void
    var clearAll: () -> Void

    @State private var rowSelection: UUID = .init()

    var view: Body {
        EitherView(notifications.isEmpty, view1: {
            StatusPage(
                "No notifications",
                icon: .custom(name: "preferences-system-notifications-symbolic"),
                description: "Agent notifications and terminal bells land here."
            )
            .compact()
            .vexpand()
        }, else: {
            ScrollView {
                VStack {
                    List(newestFirst, id: \.id, selection: openBinding) { notification in
                        Text(rowText(notification))
                            .halign(.start)
                            .padding(10)
                    }
                    .style("navigation-sidebar")
                    Button("Clear all") {
                        clearAll()
                    }
                    .padding(10)
                }
            }
            .vexpand()
        })
    }

    private var newestFirst: [TerminalNotification] {
        notifications.reversed()
    }

    private var openBinding: Binding<UUID> {
        .init {
            rowSelection
        } set: { newValue in
            rowSelection = newValue
            if let notification = notifications.first(where: { $0.id == newValue }) {
                open(notification)
            }
        }
    }

    private func rowText(_ notification: TerminalNotification) -> String {
        let marker = notification.isRead ? "" : "●  "
        let detail = [notification.subtitle, notification.body]
            .filter { !$0.isEmpty }
            .joined(separator: " — ")
        return detail.isEmpty ? marker + notification.title : "\(marker)\(notification.title): \(detail)"
    }
}

/// Placeholder for the terminal surface. Phase 2 replaces this with an
/// embedded terminal widget (libghostty surface or VTE) hosted in a GtkGLArea.
struct ContentAreaView: View {
    var tab: TerminalTab?
    var unreadCount: Int
    var socketPath: String

    var view: Body {
        StatusPage(
            tab?.title ?? "No tab selected",
            icon: .custom(name: "utilities-terminal-symbolic"),
            description: description
        )
        .vexpand()
    }

    private var description: String {
        guard let tab else { return "Create a tab with the + button." }
        var lines = ["cwd: \(tab.workingDirectory)"]
        if !socketPath.isEmpty {
            lines.append("control socket: \(socketPath)")
        }
        if unreadCount > 0 {
            lines.append("unread notifications: \(unreadCount)")
        }
        lines.append("")
        lines.append("Terminal surface placeholder — libghostty embedding lands in phase 2.")
        return lines.joined(separator: "\n")
    }
}
