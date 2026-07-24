import Adwaita
import Foundation

/// Vertical tab list — the Linux counterpart of cmux's sidebar with
/// notification rings and workspace-group sections (features/04 stage 2).
/// Rows are immutable `SidebarRowModel` snapshots plus one action closure
/// (snapshot-boundary rule); group headers carry a disclosure chevron
/// whose click toggles collapse without changing the selection, while a
/// click on the header row itself selects the group's anchor.
struct SidebarView: View {
    var rows: [SidebarRowModel]
    @Binding var selection: UUID
    var toggleCollapse: (UUID) -> Void

    var view: Body {
        ScrollView {
            List(rows, id: \.id, selection: $selection) { row in
                rowView(row)
            }
            .style("navigation-sidebar")
        }
        .vexpand()
    }

    /// Every row is the SAME top-level structure (an EitherView, i.e. a
    /// ViewStack): the ListBox differ updates row content in place by id,
    /// and a row whose view type changes between renders (workspace ⇄
    /// header) would otherwise keep its stale widget — the ViewStack is
    /// the supported structure-switch container.
    private func rowView(_ row: SidebarRowModel) -> EitherView {
        var isHeader = false
        var groupId = UUID()
        var collapsed = false
        if case let .groupHeader(gid, isCollapsed, _) = row.kind {
            isHeader = true
            groupId = gid
            collapsed = isCollapsed
        }
        return EitherView(isHeader, view1: {
            HStack {
                Button(collapsed ? "▸" : "▾") {
                    toggleCollapse(groupId)
                }
                .style("flat")
                Text(row.title)
                    .halign(.start)
                    .padding(6)
            }
            .halign(.start)
        }, else: {
            Text(row.title)
                .halign(.start)
                .padding(10)
        })
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
