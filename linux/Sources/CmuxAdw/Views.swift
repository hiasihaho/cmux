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
    var closeWorkspace: (UUID) -> Void
    var newWorkspaceInGroup: (UUID) -> Void

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
        if case let .groupHeader(gid, isCollapsed, _, _) = row.kind {
            isHeader = true
            groupId = gid
            collapsed = isCollapsed
        }
        let headerGroupId = groupId
        return EitherView(isHeader, view1: {
            HStack {
                Button(collapsed ? "▸" : "▾") {
                    toggleCollapse(headerGroupId)
                }
                .style("flat")
                Image()
                    .iconName(row.iconName ?? "folder-symbolic")
                Text(headerMarkup(row))
                    .useMarkup()
                    .halign(.start)
                    .padding(6)
                    .hexpand()
                // Hover-revealed "new workspace in group" — the macOS
                // header's hover-＋ (MACOS-UX §2.3), shown via CSS
                // row:hover, so the row structure stays fixed.
                Button(icon: .custom(name: "list-add-symbolic")) {
                    newWorkspaceInGroup(headerGroupId)
                }
                .style("flat")
                .style("cmux-hover-reveal")
                .tooltip("New Workspace in Group")
            }
        }, else: {
            HStack {
                Text(row.title)
                    .halign(.start)
                    .padding(10)
                    .hexpand()
                // Hover-revealed close, the macOS row affordance.
                Button(icon: .custom(name: "window-close-symbolic")) {
                    closeWorkspace(row.id)
                }
                .style("flat")
                .style("cmux-hover-reveal")
                .tooltip("Close Workspace")
            }
        })
    }

    /// The header label renders with Pango markup so the group's color
    /// tints a leading swatch; the title itself is always escaped.
    private func headerMarkup(_ row: SidebarRowModel) -> String {
        let escaped = SidebarRows.markupEscaped(row.title)
        guard let hex = row.colorHex else { return escaped }
        return "<span foreground=\"\(hex)\">■</span>  " + escaped
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
