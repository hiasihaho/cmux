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
