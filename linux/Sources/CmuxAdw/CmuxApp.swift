import Adwaita
import Foundation

@main
struct CmuxApp: App {

    static let initialTab = TerminalTab(title: "Terminal 1")

    /// `CMUX_APP_ID` lets a dev instance run beside the daily one
    /// (GApplication ids are unique per session bus).
    let app = AdwaitaApp(
        id: ProcessInfo.processInfo.environment["CMUX_APP_ID"] ?? "com.manaflow.cmux"
    )

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
        ControlSocketServer.shared.dispatcher = { line, respond in
            // The guard covers the synchronous dispatch window (where tab/
            // selection mutations happen); async continuations only touch
            // WebKit state, never the sidebar model.
            SocketDispatchGuard.active = true
            defer { SocketDispatchGuard.active = false }
            handler.handle(line: line, respond: respond)
        }
        ControlSocketServer.shared.start()

        // W3C WebDriver opt-in (CMUX_WEBDRIVER=1 only) — roadmap/06.
        // Automation views become real cmux panes: the driver drives a
        // split the human can see, and cmux's own verbs address the very
        // same web view. Runs on the main loop (GTK signal), so the same
        // dispatch guard as socket commands applies.
        BrowserAdoption.adoptIntoSplit = { view in
            SocketDispatchGuard.active = true
            defer { SocketDispatchGuard.active = false }
            let surfaceId = handler.adoptBrowserSplit { pendingId in
                BrowserAdoption.pending[pendingId] = view
            }
            guard let surfaceId else { return false }
            _ = surfaceId
            return true
        }
        // window.open / target="_blank" land in a split beside their opener
        // rather than vanishing (roadmap/06 increment 5). Runs on the main
        // loop from WebKit's `create` signal, so it takes the same dispatch
        // guard as socket commands.
        PopupRouting.adopt = { view, openerSurfaceId in
            SocketDispatchGuard.active = true
            defer { SocketDispatchGuard.active = false }
            // A popup becomes a TAB in the opener's pane. Splitting was the
            // stopgap; this is the fix — the layout stops degrading with
            // each popup.
            let surfaceId = handler.adoptBrowserTab(nextTo: openerSurfaceId) { pendingId in
                BrowserAdoption.pending[pendingId] = view
            }
            return surfaceId != nil
        }
        BrowserWebDriver.enableIfRequested()

        // Structural changes save immediately (scene body); this periodic
        // pass additionally picks up shell cwd drift (OSC 7) for restores.
        let saveState = { [self] in
            SessionStore.saveIfChanged(tabs: tabs, selection: selection, tabCounter: tabCounter)
        }
        // Lets non-model code (browser navigation) ask for a save.
        SessionStore.saveHook = saveState
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
                        onSurfaceFocused: handleSurfaceFocused,
                        onCloseRequest: { tabId, surfaceId in
                            // Ghostty surface asked to close (clean shell
                            // exit, Ctrl+D). Same path as the close-pane
                            // shortcut; closing the last pane closes the
                            // workspace.
                            controlHandler.closeSurface(tabId: tabId, surfaceId: surfaceId)
                        },
                        onTabSelected: { tabId, _, surfaceId in
                            controlHandler.selectSurfaceTab(tabId: tabId, surfaceId: surfaceId)
                        },
                        onTabClosed: { tabId, _, surfaceId in
                            controlHandler.closeSurface(tabId: tabId, surfaceId: surfaceId)
                        }
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
                        Button(icon: .custom(name: "edit-find-symbolic")) {
                            findInFocusedPane()
                        }
                        .keyboardShortcut("f".ctrl().shift())
                        .tooltip("Find in terminal (Ctrl+Shift+F)")
                        Button(icon: .custom(name: "view-fullscreen-symbolic")) {
                            controlHandler.toggleZoom(tabId: selection, surfaceId: nil)
                        }
                        .keyboardShortcut("z".ctrl().shift())
                        .tooltip("Zoom pane (Ctrl+Shift+Z)")
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
            // Row-diff echoes during socket-driven tab mutations are not
            // user clicks — ignoring them keeps agents from stealing the
            // human's selection.
            guard !SocketDispatchGuard.active, newValue != selection else { return }
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

    /// Open Ghostty's built-in find-in-terminal overlay on the focused
    /// pane (Ctrl+Shift+F). VTE panes have no overlay — no-op there.
    private func findInFocusedPane() {
        guard let tab = tabs.first(where: { $0.id == selection }),
              let focused = tab.focusedSurface else { return }
        // Browser panes get WebKit's find controller behind our own bar;
        // terminal panes get Ghostty's built-in overlay. Same shortcut,
        // two engines — VTE panes still have neither.
        if case .browser = focused.kind {
            BrowserFindRegistry.show(surfaceId: focused.surfaceId)
            return
        }
        #if canImport(CGhosttyEmbed)
        SurfaceRegistry.shared.ghosttySetSearch(for: focused.surfaceId, active: true)
        #endif
    }

    /// Stands in for real detection (libghostty desktop-notification actions)
    /// until the terminal surface is embedded.
    private func simulateAttention() {
        guard let index = tabs.firstIndex(where: { $0.id == selection }) else { return }
        tabs[index].needsAttention.toggle()
    }

    /// OSC title updates from the shell (VTE `window-title-changed`). Only
    /// the focused surface drives the tab title; a user-pinned title
    /// (workspace.rename) wins over OSC updates entirely.
    private func handleTitleChange(_ tabId: UUID, _ surfaceId: UUID, _ title: String) {
        guard !title.isEmpty,
              let index = tabs.firstIndex(where: { $0.id == tabId }),
              tabs[index].customTitle == nil,
              tabs[index].focusedSurface?.surfaceId == surfaceId,
              tabs[index].title != title else { return }
        tabs[index].title = title
    }

    /// Terminal bell — the first real attention signal (agents ring the bell
    /// or use `cmux notify`; libghostty adds OSC 9/777 later). Startup-banner
    /// bells are suppressed and bursts coalesce into one entry.
    private func handleBell(_ tabId: UUID, _ surfaceId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        switch SurfaceRegistry.shared.bellVerdict(for: surfaceId) {
        case .suppress:
            return
        case .coalesce:
            tabs[index].needsAttention = true
        case .notify:
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

    /// Clicking into a surface makes it the workspace's focused surface;
    /// the tab title follows it.
    private func handleSurfaceFocused(_ tabId: UUID, _ surfaceId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }),
              tabs[index].focusedSurfaceId != surfaceId else { return }
        tabs[index].focusedSurfaceId = surfaceId
        controlHandler.refreshTitle(tabId: tabId)
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
