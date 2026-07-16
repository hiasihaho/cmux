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
    @State private var showNotifications = false
    @State private var tabCounter = 1

    init() {
        if let restored = SessionStore.restore() {
            _tabs.rawValue = restored.tabs
            _selection.rawValue = restored.selection
            _tabCounter.rawValue = restored.tabCounter
        }

        let handler = ControlCommandHandler(
            tabs: $tabs,
            selection: $selection,
            notifications: $notifications,
            tabCounter: $tabCounter
        )
        ControlSocketServer.shared.dispatcher = { line in handler.handle(line: line) }
        ControlSocketServer.shared.start()

        // Structural changes save immediately (scene body); this periodic
        // pass additionally picks up shell cwd drift (OSC 7) for restores.
        let saveState = { [self] in
            SessionStore.saveIfChanged(tabs: tabs, selection: selection, tabCounter: tabCounter)
        }
        Idle(delay: .seconds(15)) {
            saveState()
            return true
        }
    }

    var scene: Scene {
        let _ = SessionStore.saveIfChanged(tabs: tabs, selection: selection, tabCounter: tabCounter)
        Window(id: "main") { _ in
            OverlaySplitView(visible: $sidebarVisible) {
                EitherView(showNotifications, view1: {
                    NotificationsListView(
                        notifications: notifications,
                        open: openNotification,
                        clearAll: clearAllNotifications
                    )
                }, else: {
                    SidebarView(tabs: tabs, selection: selectionBinding)
                })
                .topToolbar {
                    HeaderBar {
                        Button(icon: .custom(
                            name: showNotifications
                                ? "go-previous-symbolic"
                                : "preferences-system-notifications-symbolic"
                        )) {
                            showNotifications.toggle()
                        }
                        .tooltip(showNotifications
                            ? "Back to workspaces"
                            : unreadCount > 0
                                ? "Notifications (\(unreadCount) unread)"
                                : "Notifications")
                    } end: {
                        Button(icon: .custom(name: "tab-new-symbolic")) {
                            newTab()
                        }
                        .keyboardShortcut("t".ctrl().shift())
                        .tooltip("New tab (Ctrl+Shift+T)")
                    }
                    .headerBarTitle {
                        WindowTitle(
                            subtitle: unreadCount > 0 ? "\(unreadCount) unread" : "",
                            title: showNotifications ? "Notifications" : "cmux"
                        )
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
                        .keyboardShortcut("d".ctrl().shift())
                        .tooltip("Split right (Ctrl+Shift+D)")
                        Button(icon: .custom(name: "pan-down-symbolic")) {
                            splitFocused(direction: "down")
                        }
                        .keyboardShortcut("s".ctrl().shift())
                        .tooltip("Split down (Ctrl+Shift+S)")
                    } end: {
                        Button(icon: .custom(name: "software-update-urgent-symbolic")) {
                            simulateAttention()
                        }
                        .tooltip("Simulate agent attention")
                        Button(icon: .custom(name: "window-close-symbolic")) {
                            closeFocusedPane()
                        }
                        .keyboardShortcut("w".ctrl().shift())
                        .tooltip("Close pane (Ctrl+Shift+W)")
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

    /// Closes the focused pane; closing the last pane closes the workspace.
    private func closeFocusedPane() {
        guard let tab = tabs.first(where: { $0.id == selection }),
              let focused = tab.focusedSurface else { return }
        controlHandler.closeSurface(tabId: tab.id, surfaceId: focused.surfaceId)
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

    private var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }

    /// Jump to the notification's workspace (marks its notifications read);
    /// focuses the exact surface when it still exists.
    private func openNotification(_ notification: TerminalNotification) {
        if let index = tabs.firstIndex(where: { $0.id == notification.tabId }) {
            controlHandler.select(notification.tabId)
            if let surfaceId = notification.surfaceId,
               tabs[index].contains(surfaceId: surfaceId) {
                tabs[index].focusedSurfaceId = surfaceId
            }
        } else if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            // Workspace is gone — just mark the entry read.
            notifications[index].isRead = true
        }
        showNotifications = false
    }

    private func clearAllNotifications() {
        notifications.removeAll()
        tabs = tabs.map { tab in
            var copy = tab
            copy.needsAttention = false
            return copy
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
