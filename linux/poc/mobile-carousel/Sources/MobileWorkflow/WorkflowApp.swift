import Adwaita
import CAdwShim
import CVte
import CWebKit
import Foundation

/// Spike v2: the web-app workflow shell on a phone-sized RDP window.
///   level 1 — workspaces (one per worktree): AdwTabView + AdwTabOverview
///             (GNOME thumbnail grid replaces the sidebar)
///   level 2 — panes in a workspace: carousel of Shell + Vorschau (WebKit),
///             switched by a bottom toggle, an edge swipe, or the overview
@main
struct WorkflowApp: App {

    let app = AdwaitaApp(id: ProcessInfo.processInfo.environment["MOBILE_APP_ID"]
        ?? "com.manaflow.cmux.poc.workflow")

    @State private var overview = false
    @State private var workspaceCount = Int(ProcessInfo.processInfo.environment["MOBILE_WORKSPACES"] ?? "") ?? 2
    @State private var workspaceIndex = 0
    @State private var paneIndex = 0
    @State private var names: [String] = []
    @State private var fontScale = Double(ProcessInfo.processInfo.environment["MOBILE_FONT_SCALE"] ?? "") ?? 0.8
    @State private var closeRequest = 0

    var scene: Scene {
        let width = Int(ProcessInfo.processInfo.environment["MOBILE_W"] ?? "") ?? 392
        let height = Int(ProcessInfo.processInfo.environment["MOBILE_H"] ?? "") ?? 844
        Window(id: "main") { _ in
            WorkflowShellWidget(
                overview: overview,
                workspaceCount: workspaceCount,
                fontScale: fontScale,
                closeRequest: closeRequest,
                onWorkspaceChanged: { index, count, pane, allNames in
                    workspaceIndex = index
                    workspaceCount = count
                    paneIndex = pane
                    names = allNames
                },
                onPaneChanged: { paneIndex = $0 },
                onExitOverview: { overview = false },
                onFontScale: { fontScale = $0 }
            )
            .topToolbar {
                HeaderBar {
                    Button(icon: .custom(name: overview ? "view-reveal-symbolic" : "view-grid-symbolic")) {
                        overview.toggle()
                    }
                    .tooltip(overview ? "Back to workspace" : "Workspaces")
                } end: {
                    Button(icon: .custom(name: "tab-new-symbolic")) {
                        workspaceCount += 1
                    }
                    .tooltip("New workspace")
                    Button(icon: .custom(name: "window-close-symbolic")) {
                        closeRequest += 1
                    }
                    .tooltip("Close this workspace")
                }
                .headerBarTitle {
                    WindowTitle(
                        subtitle: overview
                            ? "tap a workspace"
                            : "\(workspaceIndex + 1) / \(workspaceCount) · \(paneIndex == 0 ? "Shell" : "Vorschau")",
                        title: workspaceIndex < names.count ? names[workspaceIndex] : "cmux"
                    )
                }
            }
        }
        .defaultSize(width: width, height: height)
    }
}
