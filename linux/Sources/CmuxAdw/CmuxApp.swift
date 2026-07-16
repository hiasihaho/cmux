import Adwaita
import Foundation

@main
struct CmuxApp: App {

    static let initialTab = TerminalTab(title: "Terminal 1")

    let app = AdwaitaApp(id: "com.manaflow.cmux")

    @State private var tabs: [TerminalTab] = [CmuxApp.initialTab]
    @State private var selection: UUID = CmuxApp.initialTab.id
    @State private var notifications: [TerminalNotification] = []
    @State private var sidebarVisible = true
    @State private var tabCounter = 1

    init() {
        let handler = ControlCommandHandler(
            tabs: $tabs,
            selection: $selection,
            notifications: $notifications,
            tabCounter: $tabCounter
        )
        ControlSocketServer.shared.dispatcher = { line in handler.handle(line: line) }
        ControlSocketServer.shared.start()
    }

    var scene: Scene {
        Window(id: "main") { _ in
            OverlaySplitView(visible: $sidebarVisible) {
                SidebarView(tabs: tabs, selection: selectionBinding)
                    .topToolbar {
                        HeaderBar.end {
                            Button(icon: .custom(name: "tab-new-symbolic")) {
                                newTab()
                            }
                            .tooltip("New tab")
                        }
                        .headerBarTitle {
                            WindowTitle(subtitle: "", title: "cmux")
                        }
                    }
            } content: {
                EitherView(tabs.isEmpty, view1: {
                    ContentAreaView(
                        tab: nil,
                        unreadCount: notifications.filter { !$0.isRead }.count,
                        socketPath: ControlSocketServer.shared.path
                    )
                }, else: {
                    TerminalStackWidget(
                        tabs: tabs,
                        selection: selection,
                        onTitleChanged: handleTitleChange,
                        onBell: handleBell,
                        onSurfaceFocused: handleSurfaceFocused
                    )
                })
                .topToolbar {
                    HeaderBar {
                        Button(icon: .custom(name: "sidebar-show-symbolic")) {
                            sidebarVisible.toggle()
                        }
                        .tooltip("Toggle sidebar")
                        Button(icon: .custom(name: "pan-end-symbolic")) {
                            splitFocused(direction: "right")
                        }
                        .tooltip("Split right")
                        Button(icon: .custom(name: "pan-down-symbolic")) {
                            splitFocused(direction: "down")
                        }
                        .tooltip("Split down")
                    } end: {
                        Button(icon: .custom(name: "software-update-urgent-symbolic")) {
                            simulateAttention()
                        }
                        .tooltip("Simulate agent attention")
                        Button(icon: .custom(name: "window-close-symbolic")) {
                            closeSelectedTab()
                        }
                        .tooltip("Close tab")
                    }
                }
            }
        }
        .title("cmux")
        .defaultSize(width: 1100, height: 750)
        .quitShortcut()
        .closeShortcut()
    }

    /// Selecting a tab in the sidebar also clears its attention state,
    /// mirroring macOS mark-read-on-focus.
    private var selectionBinding: Binding<UUID> {
        .init {
            selection
        } set: { newValue in
            controlHandler.select(newValue)
        }
    }

    private var controlHandler: ControlCommandHandler {
        ControlCommandHandler(
            tabs: $tabs,
            selection: $selection,
            notifications: $notifications,
            tabCounter: $tabCounter
        )
    }

    private func newTab() {
        tabCounter += 1
        let tab = TerminalTab(title: "Terminal \(tabCounter)")
        tabs.append(tab)
        selection = tab.id
    }

    private func closeSelectedTab() {
        guard let index = tabs.firstIndex(where: { $0.id == selection }) else { return }
        tabs.remove(at: index)
        if let next = tabs[safe: min(index, tabs.count - 1)] ?? tabs.first {
            selection = next.id
        }
    }

    /// Stands in for real detection (libghostty desktop-notification actions)
    /// until the terminal surface is embedded.
    private func simulateAttention() {
        guard let index = tabs.firstIndex(where: { $0.id == selection }) else { return }
        tabs[index].needsAttention.toggle()
    }

    /// OSC title updates from the shell (VTE `window-title-changed`). Only
    /// the focused surface drives the tab title.
    private func handleTitleChange(_ tabId: UUID, _ surfaceId: UUID, _ title: String) {
        guard !title.isEmpty,
              let index = tabs.firstIndex(where: { $0.id == tabId }),
              tabs[index].focusedSurface?.surfaceId == surfaceId,
              tabs[index].title != title else { return }
        tabs[index].title = title
    }

    /// Terminal bell — the first real attention signal (agents ring the bell
    /// or use `cmux notify`; libghostty adds OSC 9/777 later).
    private func handleBell(_ tabId: UUID, _ surfaceId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].needsAttention = true
        notifications.append(TerminalNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: "Bell",
            body: "Terminal bell in \(tabs[index].title)"
        ))
        if tabId != selection {
            DesktopNotifier.send(
                id: "cmux-\(tabId.uuidString)",
                title: tabs[index].title,
                body: "Terminal bell"
            )
        }
    }

    /// Clicking into a terminal makes it the workspace's focused surface.
    private func handleSurfaceFocused(_ tabId: UUID, _ surfaceId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }),
              tabs[index].focusedSurfaceId != surfaceId else { return }
        tabs[index].focusedSurfaceId = surfaceId
    }

    private func splitFocused(direction: String) {
        guard let tab = tabs.first(where: { $0.id == selection }),
              let focused = tab.focusedSurface else { return }
        controlHandler.split(tab: tab, surfaceId: focused.surfaceId, direction: direction)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
