import Adwaita
import CVte
import Foundation

/// True while a socket command (and its synchronous view update) is being
/// dispatched on the main loop. The sidebar's GtkListBox emits
/// `selected_rows_changed` while its rows are diffed after tab mutations —
/// without this guard such echoes get mistaken for user clicks and steal
/// the human's workspace selection (observed once in dogfood cycle 3).
enum SocketDispatchGuard {
    static var active = false
}

/// Most-recently-selected workspace order (macOS `TabManager` keeps a
/// workspace history too) — closing the selected workspace returns to the
/// previously selected one instead of an arbitrary neighbor.
final class SelectionHistory {
    static let shared = SelectionHistory()
    private var stack: [UUID] = []

    func note(_ id: UUID) {
        stack.removeAll { $0 == id }
        stack.append(id)
    }

    func lastAlive(in tabs: [TerminalTab], excluding: UUID) -> UUID? {
        stack.reversed().first { candidate in
            candidate != excluding && tabs.contains { $0.id == candidate }
        }
    }
}

/// Most-recently-focused pane per workspace — `pane.last` (tmux
/// `last-pane`) pops the previous distinct pane. Fed by the GTK
/// focus-enter funnel in CmuxApp.
final class PaneFocusHistory {
    static let shared = PaneFocusHistory()
    private var stacks: [UUID: [UUID]] = [:]

    func note(tabId: UUID, paneId: UUID) {
        var stack = stacks[tabId] ?? []
        stack.removeAll { $0 == paneId }
        stack.append(paneId)
        stacks[tabId] = stack
    }

    func previous(tabId: UUID, excluding paneId: UUID?, in tab: TerminalTab) -> UUID? {
        (stacks[tabId] ?? []).reversed().first { candidate in
            candidate != paneId && tab.panes.contains { $0.paneId == candidate }
        }
    }
}

/// Implements the cmux control-socket wire protocol (the verb subset that
/// maps onto the Phase-0/1 tab model). Formats follow the macOS
/// `TerminalController` handlers byte-for-byte so the shared CLI works
/// unchanged against the Linux app.
struct ControlCommandHandler {

    var tabs: Binding<[TerminalTab]>
    var selection: Binding<UUID>
    var notifications: Binding<[TerminalNotification]>
    var tabCounter: Binding<Int>

    // MARK: dispatch

    /// Entry point for the socket server. v1 verbs and most v2 methods
    /// answer synchronously; browser-automation verbs complete through
    /// `respond` from WebKit's async JS callbacks (never blocking the main
    /// loop). `respond` must be called exactly once on every path.
    func handle(line: String, respond: @escaping (String) -> Void) {
        if line.hasPrefix("{") {
            handleV2(line, respond: respond)
        } else {
            respond(handleV1(line))
        }
    }

    private func handleV1(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let verb = parts[0]
        let args = parts.count > 1 ? parts[1] : ""

        switch verb {
        case "ping":
            return "PONG"
        case "auth":
            return "OK: Authentication not required"
        case "list_workspaces":
            return listWorkspaces()
        case "new_workspace":
            return newWorkspace()
        case "select_workspace":
            return selectWorkspace(args)
        case "current_workspace":
            return currentWorkspace()
        case "current_window":
            return ControlCommandHandler.windowId.uuidString
        case "list_windows":
            // Single window until the multi-window phase.
            return "* 0: \(ControlCommandHandler.windowId.uuidString) cmux"
        case "focus_window":
            if let window = UIDialogs.mainWindowWidget() {
                gtk_window_present(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
            }
            return "OK"
        case "refresh_surfaces":
            // The Linux view sync is continuous; there is no stale state to
            // rebuild. OK keeps `cmux refresh-surfaces` scriptable.
            return "OK"
        case "reload_config":
            // cmux.json is mtime-gated and re-read on every access, so
            // invalidating the cache IS the reload. Ghostty config: the
            // shim re-reads and propagates to every live surface
            // (ghostty_embed_reload_config, 2026-07-22).
            LinuxSettings.invalidate()
            if SurfaceRegistry.shared.ghosttyReloadConfig() {
                return "OK reloaded cmux.json + ghostty config (live)"
            }
            return "OK reloaded cmux.json (no live ghostty surfaces)"
        case "notify_target_async":
            // Same as notify_target; the CLI variant just does not wait.
            return notifyTarget(args)
        case "close_workspace":
            return closeWorkspace(args)
        case "send":
            return sendInput(args)
        case "new_split":
            return newSplitV1(args)
        case "notify":
            return notifyCurrent(args)
        case "notify_surface":
            return notifySurface(args)
        case "notify_target":
            return notifyTarget(args)
        case "list_notifications":
            return listNotifications()
        case "clear_notifications":
            notifications.wrappedValue.removeAll()
            clearAllAttention()
            return "OK"
        case "help":
            return """
            Available commands (Linux port, phase 1 subset): ping, auth, \
            list_workspaces, new_workspace, select_workspace, current_workspace, \
            close_workspace, notify, notify_surface, notify_target, \
            list_notifications, clear_notifications, help
            """
        default:
            // Same friendly wording as the v2 unknown-method reply — many
            // CLI commands still speak v1 and hit this path (dogfood
            // cycle 6 flagged the bare "Unknown command" as confusing).
            return "ERROR: Method not implemented in the Linux port yet: \(verb)"
        }
    }

    // MARK: v1 verbs

    private func listWorkspaces() -> String {
        let lines = tabs.wrappedValue.enumerated().map { index, tab in
            let selected = tab.id == selection.wrappedValue ? "*" : " "
            return "\(selected) \(index): \(tab.id.uuidString) \(tab.title)"
        }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? "No workspaces" : result
    }

    private func newWorkspace() -> String {
        tabCounter.wrappedValue += 1
        let tab = TerminalTab(title: "Terminal \(tabCounter.wrappedValue)")
        tabs.wrappedValue.append(tab)
        selection.wrappedValue = tab.id
        return "OK \(tab.id.uuidString)"
    }

    private func selectWorkspace(_ arg: String) -> String {
        guard let tab = resolveTab(from: arg.trimmingCharacters(in: .whitespaces)) else {
            return "ERROR: Tab not found"
        }
        select(tab.id)
        return "OK"
    }

    private func currentWorkspace() -> String {
        let current = selection.wrappedValue
        guard tabs.wrappedValue.contains(where: { $0.id == current }) else {
            return "ERROR: No tab selected"
        }
        return current.uuidString
    }

    private func closeWorkspace(_ arg: String) -> String {
        let trimmed = arg.trimmingCharacters(in: .whitespaces)
        let target = trimmed.isEmpty
            ? tabs.wrappedValue.first { $0.id == selection.wrappedValue }
            : resolveTab(from: trimmed)
        guard let tab = target,
              let index = tabs.wrappedValue.firstIndex(of: tab) else {
            return "ERROR: Tab not found"
        }
        removeWorkspace(at: index)
        return "OK"
    }

    /// Removes a workspace, its notifications, and restores the previously
    /// selected workspace when the removed one was selected.
    private func removeWorkspace(at index: Int) {
        let tabId = tabs.wrappedValue[index].id
        notifications.wrappedValue.removeAll { $0.tabId == tabId }
        DesktopNotifier.withdraw(id: "cmux-\(tabId.uuidString)")
        tabs.wrappedValue.remove(at: index)
        if selection.wrappedValue == tabId,
           let next = SelectionHistory.shared.lastAlive(in: tabs.wrappedValue, excluding: tabId)
               ?? (tabs.wrappedValue[safe: min(index, tabs.wrappedValue.count - 1)]
                   ?? tabs.wrappedValue.first)?.id {
            select(next)
        }
    }

    /// Same escape handling as the macOS `sendInput`: `\n` becomes Enter.
    private func sendInput(_ args: String) -> String {
        guard let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }),
              let focused = tab.focusedSurface,
              let terminal = SurfaceRegistry.shared.terminal(for: focused.surfaceId) else {
            return "ERROR: No focused terminal"
        }
        let unescaped = args
            .replacingOccurrences(of: "\\n", with: "\r")
            .replacingOccurrences(of: "\\r", with: "\r")
            .replacingOccurrences(of: "\\t", with: "\t")
        feed(terminal, unescaped)
        return "OK"
    }

    private func newSplitV1(_ args: String) -> String {
        let parts = args.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").map(String.init)
        guard let direction = parts.first else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }
        guard let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }),
              let focused = tab.focusedSurface else {
            return "ERROR: No surface to split"
        }
        guard let leaf = split(tab: tab, surfaceId: focused.surfaceId, direction: direction) else {
            return "ERROR: Invalid direction. Use left, right, up, or down."
        }
        return "OK \(leaf.surfaceId.uuidString)"
    }

    private func feed(_ terminal: UnsafeMutablePointer<VteTerminal>, _ text: String) {
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                vte_terminal_feed_child(terminal, $0, bytes.count)
            }
        }
    }

    private func notifyCurrent(_ args: String) -> String {
        guard let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }) else {
            return "ERROR: No tab selected"
        }
        addNotification(tabId: tab.id, surfaceId: nil, payload: args)
        return "OK"
    }

    /// Surfaces don't exist yet in the Linux tab model (Phase 2); the surface
    /// argument is accepted for CLI compatibility and recorded verbatim.
    private func notifySurface(_ args: String) -> String {
        let parts = args.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1).map(String.init)
        guard let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }) else {
            return "ERROR: No tab selected"
        }
        let payload = parts.count > 1 ? parts[1] : ""
        addNotification(tabId: tab.id, surfaceId: parts.first.flatMap(UUID.init), payload: payload)
        return "OK"
    }

    private func notifyTarget(_ args: String) -> String {
        let trimmed = args.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>"
        }
        let parts = trimmed.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            return "ERROR: Usage: notify_target <workspace_id> <surface_id> <title>|<subtitle>|<body>"
        }
        guard let tab = resolveTab(from: parts[0]) else {
            return "ERROR: Tab not found"
        }
        let payload = parts.count > 2 ? parts[2] : ""
        addNotification(tabId: tab.id, surfaceId: UUID(uuidString: parts[1]), payload: payload)
        return "OK"
    }

    private func listNotifications() -> String {
        let lines = notifications.wrappedValue.enumerated().map { index, notification in
            let surfaceText = notification.surfaceId?.uuidString ?? "none"
            let readText = notification.isRead ? "read" : "unread"
            return "\(index):\(notification.id.uuidString)|\(notification.tabId.uuidString)|\(surfaceText)|\(readText)|\(notification.title)|\(notification.subtitle)|\(notification.body)"
        }
        let result = lines.joined(separator: "\n")
        return result.isEmpty ? "No notifications" : result
    }

    // MARK: v2 (JSON envelope)

    /// Stable app-lifetime identity of the single window (multi-window comes
    /// with a later phase).
    static let windowId = UUID()

    private func handleV2(_ jsonLine: String, respond: @escaping (String) -> Void) {
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            respond(v2Encode(["ok": false, "error": ["code": "parse_error", "message": "Invalid JSON"]]))
            return
        }
        let id = dict["id"]
        let method = (dict["method"] as? String) ?? ""
        let params = dict["params"] as? [String: Any] ?? [:]

        refreshKnownRefs()

        // Async-completing verbs first: these reply from WebKit JS callbacks.
        switch method {
        case "browser.eval":
            return v2BrowserEval(id: id, params: params, respond: respond)
        case "browser.snapshot":
            return v2BrowserSnapshot(id: id, params: params, respond: respond)
        case "browser.find_in_page":
            return v2BrowserFindInPage(id: id, params: params, respond: respond)
        case "search.panes":
            return v2SearchPanes(id: id, params: params, respond: respond)
        case "browser.wait":
            return v2BrowserWait(id: id, params: params, respond: respond)
        case "browser.inspect", "browser.devtools.toggle":
            return v2BrowserInspect(id: id, params: params, respond: respond)
        case "browser.console.show":
            return v2BrowserConsoleShow(id: id, params: params, respond: respond)
        case "browser.navigate":
            return v2BrowserNavigate(id: id, params: params, respond: respond)
        case "browser.back":
            return v2BrowserHistory(id: id, params: params, action: "back", respond: respond)
        case "browser.forward":
            return v2BrowserHistory(id: id, params: params, action: "forward", respond: respond)
        case "browser.reload":
            return v2BrowserHistory(id: id, params: params, action: "reload", respond: respond)
        case "browser.click", "browser.dblclick", "browser.hover", "browser.focus",
             "browser.fill", "browser.type", "browser.check", "browser.uncheck",
             "browser.select", "browser.scroll_into_view", "browser.highlight",
             "browser.get.text", "browser.get.html", "browser.get.value",
             "browser.get.attr", "browser.get.box", "browser.get.styles",
             "browser.is.visible", "browser.is.enabled", "browser.is.checked":
            return v2BrowserSelectorVerb(method: method, id: id, params: params, respond: respond)
        case "browser.press", "browser.keydown", "browser.keyup":
            return v2BrowserKeyVerb(method: method, id: id, params: params, respond: respond)
        case "browser.scroll":
            return v2BrowserScroll(id: id, params: params, respond: respond)
        case "browser.get.count":
            return v2BrowserGetCount(id: id, params: params, respond: respond)
        case "browser.screenshot":
            return v2BrowserScreenshot(id: id, params: params, respond: respond)
        case "browser.find.role", "browser.find.text", "browser.find.label",
             "browser.find.placeholder", "browser.find.alt", "browser.find.title",
             "browser.find.testid", "browser.find.first", "browser.find.last",
             "browser.find.nth":
            return v2BrowserFindVerb(method: method, id: id, params: params, respond: respond)
        case "browser.frame.select":
            return v2BrowserFrameSelect(id: id, params: params, respond: respond)
        case "browser.frame.main":
            return v2BrowserFrameMain(id: id, params: params, respond: respond)
        case "browser.dialog.accept":
            return v2BrowserDialogRespond(id: id, params: params, accept: true, respond: respond)
        case "browser.dialog.dismiss":
            return v2BrowserDialogRespond(id: id, params: params, accept: false, respond: respond)
        case "browser.storage.get", "browser.storage.set", "browser.storage.clear":
            return v2BrowserStorageVerb(method: method, id: id, params: params, respond: respond)
        case "browser.console.list", "browser.console.clear", "browser.errors.list":
            return v2BrowserTelemetryVerb(method: method, id: id, params: params, respond: respond)
        case "browser.download.wait":
            return v2BrowserDownloadWait(id: id, params: params, respond: respond)
        case "browser.cookies.get":
            return v2BrowserCookiesGet(id: id, params: params, respond: respond)
        case "browser.cookies.set":
            return v2BrowserCookiesSet(id: id, params: params, respond: respond)
        case "browser.cookies.clear":
            return v2BrowserCookiesClear(id: id, params: params, respond: respond)
        default:
            break
        }

        respond(handleV2Sync(id: id, method: method, params: params))
    }

    private func handleV2Sync(id: Any?, method: String, params: [String: Any]) -> String {
        switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: id, result: [
                "protocol": 2,
                "platform": "linux",
                "port": "phase-5c",
                "methods": [
                    "system.ping", "system.capabilities", "system.identify",
                    "window.list",
                    "workspace.list", "workspace.create", "workspace.select",
                    "workspace.current", "workspace.close", "workspace.rename",
                    "workspace.next", "workspace.previous", "workspace.last",
                    "surface.list", "surface.create", "surface.send_text",
                    "surface.send_key", "surface.read_text", "surface.split",
                    "surface.close", "surface.focus", "surface.trigger_flash",
                    "session.save", "settings.open", "system.tree",
                    "pane.last", "surface.clear_history", "tab.action",
                    "surface.reorder", "surface.move",
                    "pane.swap", "pane.break", "pane.join", "pane.resize",
                    "surface.respawn", "debug.surfaces",
                    "notification.jump_to_unread", "notification.mark_read",
                    "notification.dismiss", "notification.open",
                    "window.current", "window.focus", "browser.zoom.set",
                    "browser.devtools.toggle",
                    "pane.create", "pane.list", "pane.focus", "pane.surfaces",
                    "browser.open_split", "browser.navigate", "browser.url.get",
                    "browser.back", "browser.forward", "browser.reload",
                    "browser.identify",
                    "browser.eval", "browser.snapshot", "browser.wait",
                    "browser.click", "browser.dblclick", "browser.hover",
                    "browser.focus", "browser.fill", "browser.type",
                    "browser.check", "browser.uncheck", "browser.select",
                    "browser.press", "browser.keydown", "browser.keyup",
                    "browser.scroll", "browser.scroll_into_view",
                    "browser.get.text", "browser.get.html", "browser.get.value",
                    "browser.get.attr", "browser.get.title", "browser.get.count",
                    "browser.get.box", "browser.get.styles",
                    "browser.is.visible", "browser.is.enabled", "browser.is.checked",
                    "browser.screenshot",
                    "browser.find.role", "browser.find.text", "browser.find.label",
                    "browser.find.placeholder", "browser.find.alt", "browser.find.title",
                    "browser.find.testid", "browser.find.first", "browser.find.last",
                    "browser.find.nth",
                    "browser.frame.select", "browser.frame.main",
                    "browser.dialog.accept", "browser.dialog.dismiss",
                    "browser.cookies.get", "browser.cookies.set", "browser.cookies.clear",
                    "browser.storage.get", "browser.storage.set", "browser.storage.clear",
                    "browser.console.list", "browser.console.clear", "browser.errors.list",
                    "browser.console.show",
                    "browser.download.wait",
                    "notification.create", "notification.create_for_surface",
                    "notification.create_for_target",
                    "notification.list", "notification.clear"
                ]
            ])
        case "system.identify":
            return v2SystemIdentify(id: id, params: params)
        case "window.list":
            return v2Ok(id: id, result: ["windows": [[
                "id": Self.windowId.uuidString,
                "ref": RefRegistry.shared.ref(kind: "window", uuid: Self.windowId),
                "title": "cmux",
                "main": true
            ]]])
        case "workspace.list":
            return v2Ok(id: id, result: workspaceListResult())
        case "workspace.create":
            return v2WorkspaceCreate(id: id, params: params)
        case "workspace.select":
            return v2WorkspaceSelect(id: id, params: params)
        case "workspace.current":
            guard tabs.wrappedValue.contains(where: { $0.id == selection.wrappedValue }) else {
                return v2Error(id: id, code: "not_found", message: "No workspace selected")
            }
            return v2Ok(id: id, result: workspaceRefResult(selection.wrappedValue))
        case "workspace.close":
            return v2WorkspaceClose(id: id, params: params)
        case "workspace.rename":
            return v2WorkspaceRename(id: id, params: params)
        case "workspace.next":
            return v2WorkspaceStep(id: id, forward: true)
        case "workspace.previous":
            return v2WorkspaceStep(id: id, forward: false)
        case "workspace.last":
            return v2WorkspaceLast(id: id)
        case "surface.list":
            return v2SurfaceList(id: id, params: params)
        case "surface.send_text":
            return v2SurfaceSendText(id: id, params: params)
        case "surface.send_key":
            return v2SurfaceSendKey(id: id, params: params)
        case "surface.read_text":
            return v2SurfaceReadText(id: id, params: params)
        case "surface.split":
            return v2SurfaceSplit(id: id, params: params)
        case "pane.create", "surface.create":
            return v2PaneCreate(id: id, params: params)
        case "surface.close":
            return v2SurfaceClose(id: id, params: params)
        case "pane.list":
            return v2PaneList(id: id, params: params)
        case "pane.focus":
            return v2PaneFocus(id: id, params: params)
        case "surface.focus":
            return v2SurfaceFocus(id: id, params: params)
        case "session.save":
            return v2SessionSave(id: id)
        case "surface.respawn":
            return v2SurfaceRespawn(id: id, params: params)
        case "debug.surfaces":
            // The doctor verb: widget-lifecycle state of every surface
            // (backend, parent type, realized/mapped, refcount, readable).
            // Grew out of hand-instrumented probes during the pane-verb
            // work; extend it rather than re-instrumenting.
            let reports = tabs.wrappedValue.flatMap { tab in
                tab.allSurfaces.map { entry -> [String: Any] in
                    var report = SurfaceRegistry.shared.doctorReport(for: entry.surface.surfaceId)
                    report["workspace_id"] = tab.id.uuidString
                    report["ref"] = RefRegistry.shared.ref(kind: "surface", uuid: entry.surface.surfaceId)
                    return report
                }
            }
            return v2Ok(id: id, result: ["surfaces": reports])
        case "system.tree":
            return v2SystemTree(id: id, params: params)
        case "pane.last":
            return v2PaneLast(id: id, params: params)
        case "surface.clear_history":
            return v2SurfaceClearHistory(id: id, params: params)
        case "tab.action", "surface.action":
            return v2TabAction(id: id, params: params)
        case "surface.reorder":
            return v2SurfaceReorder(id: id, params: params)
        case "surface.move":
            return v2SurfaceMove(id: id, params: params)
        case "pane.swap":
            return v2PaneSwap(id: id, params: params)
        case "pane.break":
            return v2PaneBreak(id: id, params: params)
        case "pane.join":
            return v2PaneJoin(id: id, params: params)
        case "pane.resize":
            return v2PaneResize(id: id, params: params)
        case "notification.jump_to_unread":
            return v2NotificationJumpToUnread(id: id)
        case "notification.mark_read":
            return v2NotificationMarkRead(id: id, params: params)
        case "notification.dismiss":
            return v2NotificationDismiss(id: id, params: params)
        case "notification.open":
            return v2NotificationOpen(id: id, params: params)
        case "window.current":
            return v2WindowCurrent(id: id)
        case "window.focus":
            return v2WindowFocus(id: id)
        case "settings.open":
            PreferencesWindow.present()
            return v2Ok(id: id, result: ["opened": true, "target": (params["target"] as? String) ?? "general"])
        case "browser.zoom.set":
            return v2BrowserZoomSet(id: id, params: params)
        case "surface.trigger_flash":
            return v2SurfaceTriggerFlash(id: id, params: params)
        case "pane.surfaces":
            return v2PaneSurfaces(id: id, params: params)
        case "pane.zoom":
            return v2PaneZoom(id: id, params: params)
        case "browser.open_split":
            return v2BrowserOpenSplit(id: id, params: params)
        case "browser.profiles.list":
            return v2BrowserProfilesList(id: id)
        case "browser.profiles.create":
            return v2BrowserProfilesCreate(id: id, params: params)
        case "browser.profiles.rename":
            return v2BrowserProfilesRename(id: id, params: params)
        case "browser.profiles.clear":
            return v2BrowserProfilesClear(id: id, params: params)
        case "browser.profiles.delete":
            return v2BrowserProfilesDelete(id: id, params: params)
        case "browser.tab.list":
            return v2BrowserTabList(id: id, params: params)
        case "browser.tab.new":
            return v2BrowserTabNew(id: id, params: params)
        case "browser.tab.switch":
            return v2BrowserTabSwitch(id: id, params: params)
        case "browser.tab.close":
            return v2BrowserTabClose(id: id, params: params)
        case "browser.url.get":
            return v2BrowserGetURL(id: id, params: params)
        case "browser.get.title":
            return v2BrowserGetTitle(id: id, params: params)
        case "browser.identify":
            return v2BrowserIdentify(id: id, params: params)
        case "notification.create":
            return v2NotificationCreate(id: id, params: params)
        case "notification.create_for_surface":
            return v2NotificationCreateFor(id: id, params: params, requireWorkspace: false)
        case "notification.create_for_target":
            return v2NotificationCreateFor(id: id, params: params, requireWorkspace: true)
        case "notification.create_for_caller":
            return v2NotificationCreateForCaller(id: id, params: params)
        case "notification.list":
            let items: [[String: Any]] = notifications.wrappedValue.map { notification in
                [
                    "id": notification.id.uuidString,
                    "workspace_id": notification.tabId.uuidString,
                    "surface_id": notification.surfaceId?.uuidString as Any? ?? NSNull(),
                    "is_read": notification.isRead,
                    "title": notification.title,
                    "subtitle": notification.subtitle,
                    "body": notification.body
                ]
            }
            return v2Ok(id: id, result: ["notifications": items])
        case "notification.clear":
            notifications.wrappedValue.removeAll()
            clearAllAttention()
            return v2Ok(id: id, result: ["cleared": true])
        default:
            return v2Error(
                id: id,
                code: "unknown_method",
                message: "Method not implemented in the Linux port yet: \(method)"
            )
        }
    }

    /// Caller identification. The CLI nests the caller's workspace/surface
    /// under `params["caller"]` — resolve that first; only fall back to the
    /// selected workspace when no caller info was sent.
    private func v2SystemIdentify(id: Any?, params: [String: Any]) -> String {
        let registry = RefRegistry.shared
        var result: [String: Any] = [
            "platform": "linux",
            "port": "phase-5",
            "window_id": Self.windowId.uuidString,
            "window_ref": registry.ref(kind: "window", uuid: Self.windowId)
        ]
        let caller = params["caller"] as? [String: Any] ?? [:]
        let target = (caller.isEmpty ? nil : v2TargetSurface(caller)) ?? v2TargetSurface([:])
        if let target {
            let block: [String: Any] = [
                "workspace_id": target.tab.id.uuidString,
                "workspace_ref": registry.ref(kind: "workspace", uuid: target.tab.id),
                "surface_id": target.surfaceId.uuidString,
                "surface_ref": registry.ref(kind: "surface", uuid: target.surfaceId)
            ]
            result.merge(block) { current, _ in current }
            if !caller.isEmpty {
                result["caller"] = block
            }
        }
        return v2Ok(id: id, result: result)
    }

    /// Like the macOS `v2RefreshKnownRefs`: make sure every live entity has
    /// a handle ref before any params are resolved, so clients can use refs
    /// they haven't seen in a listing yet.
    private func refreshKnownRefs() {
        let registry = RefRegistry.shared
        _ = registry.ref(kind: "window", uuid: Self.windowId)
        for tab in tabs.wrappedValue {
            _ = registry.ref(kind: "workspace", uuid: tab.id)
            for leaf in tab.surfaces {
                _ = registry.ref(kind: "pane", uuid: leaf.paneId)
                _ = registry.ref(kind: "surface", uuid: leaf.surfaceId)
            }
        }
    }

    // MARK: v2 method implementations

    private func workspaceListResult() -> [String: Any] {
        let registry = RefRegistry.shared
        let workspaces: [[String: Any]] = tabs.wrappedValue.enumerated().map { index, tab in
            [
                "id": tab.id.uuidString,
                "ref": registry.ref(kind: "workspace", uuid: tab.id),
                "index": index,
                "title": tab.title,
                "selected": tab.id == selection.wrappedValue,
                "pinned": false,
                // Linux extension (not in the macOS payload): lets agents
                // poll bell/notification attention without a second call.
                "needs_attention": tab.needsAttention
            ]
        }
        return [
            "window_id": Self.windowId.uuidString,
            "window_ref": registry.ref(kind: "window", uuid: Self.windowId),
            "workspaces": workspaces
        ]
    }

    private func workspaceRefResult(_ wsId: UUID) -> [String: Any] {
        let registry = RefRegistry.shared
        return [
            "window_id": Self.windowId.uuidString,
            "window_ref": registry.ref(kind: "window", uuid: Self.windowId),
            "workspace_id": wsId.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: wsId)
        ]
    }

    private func v2WorkspaceCreate(id: Any?, params: [String: Any]) -> String {
        if let raw = params["cwd"], !(raw is String) {
            return v2Error(id: id, code: "invalid_params", message: "cwd must be a string")
        }
        tabCounter.wrappedValue += 1
        let tab = TerminalTab(
            title: "Terminal \(tabCounter.wrappedValue)",
            workingDirectory: (params["cwd"] as? String)
                ?? FileManager.default.homeDirectoryForCurrentUser.path
        )
        tabs.wrappedValue.append(tab)
        // `focus: false` creates in the background (agents/automation must
        // not steal the human's view — macOS gates this on socket policy).
        if (params["focus"] as? Bool) ?? true {
            select(tab.id)
        }
        return v2Ok(id: id, result: workspaceRefResult(tab.id))
    }

    private func v2WorkspaceSelect(id: Any?, params: [String: Any]) -> String {
        guard let wsId = v2WorkspaceUUID(params),
              tabs.wrappedValue.contains(where: { $0.id == wsId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        select(wsId)
        return v2Ok(id: id, result: workspaceRefResult(wsId))
    }

    private func v2WorkspaceClose(id: Any?, params: [String: Any]) -> String {
        guard let wsId = v2WorkspaceUUID(params),
              let index = tabs.wrappedValue.firstIndex(where: { $0.id == wsId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        removeWorkspace(at: index)
        return v2Ok(id: id, result: workspaceRefResult(wsId))
    }

    /// Pins a custom title (macOS `setCustomTitle`): OSC updates from the
    /// shell stop overwriting it. Requires an explicit workspace_id, like
    /// the macOS handler — no caller-default fallback.
    private func v2WorkspaceRename(id: Any?, params: [String: Any]) -> String {
        guard let wsId = v2WorkspaceUUID(params),
              let index = tabs.wrappedValue.firstIndex(where: { $0.id == wsId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        guard let titleRaw = params["title"] as? String,
              !titleRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing or invalid title")
        }
        let title = titleRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs.wrappedValue[index].customTitle = title
        tabs.wrappedValue[index].title = title
        var result = workspaceRefResult(wsId)
        result["title"] = title
        return v2Ok(id: id, result: result)
    }

    /// Focus-intent verbs (socket focus policy allows selection changes):
    /// cycle to the neighboring workspace, wrapping at the ends.
    private func v2WorkspaceStep(id: Any?, forward: Bool) -> String {
        let allTabs = tabs.wrappedValue
        guard let index = allTabs.firstIndex(where: { $0.id == selection.wrappedValue }) else {
            return v2Error(id: id, code: "not_found", message: "No workspace selected")
        }
        let count = allTabs.count
        let target = allTabs[forward ? (index + 1) % count : (index + count - 1) % count].id
        select(target)
        return v2Ok(id: id, result: workspaceRefResult(target))
    }

    /// Most-recently-selected workspace (macOS `navigateBack`).
    private func v2WorkspaceLast(id: Any?) -> String {
        guard let target = SelectionHistory.shared.lastAlive(
            in: tabs.wrappedValue, excluding: selection.wrappedValue
        ) else {
            return v2Error(id: id, code: "not_found", message: "No previous workspace in history")
        }
        select(target)
        return v2Ok(id: id, result: workspaceRefResult(target))
    }

    private func v2SurfaceList(id: Any?, params: [String: Any]) -> String {
        let wsId = v2WorkspaceUUID(params) ?? selection.wrappedValue
        guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        let registry = RefRegistry.shared
        let focusedId = tab.focusedSurfaceId
        // allSurfaces, not surfaces: a pane's background TABS are real
        // surfaces too, and the shared CLI resolves surface targets
        // against this listing — enumerating only each pane's leaf made
        // `respawn-pane`/`--surface` fail with "Surface ref not found"
        // for any non-selected tab (found 2026-07-22 bisecting a suite
        // red; macOS lists every surface).
        let surfaces: [[String: Any]] = tab.allSurfaces.enumerated().map { index, entry in
            [
                "id": entry.surface.surfaceId.uuidString,
                "ref": registry.ref(kind: "surface", uuid: entry.surface.surfaceId),
                "index": index,
                "focused": entry.surface.surfaceId == focusedId,
                "type": entry.surface.kind.typeName,
                "title": tab.title
            ]
        }
        return v2Ok(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
            "surfaces": surfaces
        ])
    }

    private func v2PaneList(id: Any?, params: [String: Any]) -> String {
        let wsId = v2WorkspaceUUID(params) ?? selection.wrappedValue
        guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        let registry = RefRegistry.shared
        let focusedId = tab.focusedSurface?.surfaceId
        let panes: [[String: Any]] = tab.surfaces.enumerated().map { index, leaf in
            [
                "id": leaf.paneId.uuidString,
                "ref": registry.ref(kind: "pane", uuid: leaf.paneId),
                "index": index,
                "focused": leaf.surfaceId == focusedId,
                // Real lists now that a pane can hold tabs. These fields
                // were always plural in the protocol; only the model was
                // limited to one, and hardcoding 1 here would hide tabs
                // from every client.
                "surface_ids": leaf.surfaces.map(\.surfaceId.uuidString),
                "surface_refs": leaf.surfaces.map { registry.ref(kind: "surface", uuid: $0.surfaceId) },
                "selected_surface_id": leaf.surfaceId.uuidString,
                "selected_surface_ref": registry.ref(kind: "surface", uuid: leaf.surfaceId),
                "surface_count": leaf.surfaces.count
            ]
        }
        return v2Ok(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
            "window_id": Self.windowId.uuidString,
            "window_ref": registry.ref(kind: "window", uuid: Self.windowId),
            "panes": panes
        ])
    }

    private func v2PaneSurfaces(id: Any?, params: [String: Any]) -> String {
        let wsId = v2WorkspaceUUID(params) ?? selection.wrappedValue
        guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        let leaf: PaneLeaf?
        if let raw = params["pane_id"] as? String, !raw.isEmpty {
            let paneId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
            leaf = tab.surfaces.first { $0.paneId == paneId }
        } else {
            leaf = tab.focusedSurface
        }
        guard let leaf else {
            return v2Error(id: id, code: "not_found", message: "Pane not found")
        }
        let registry = RefRegistry.shared
        return v2Ok(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
            "pane_id": leaf.paneId.uuidString,
            "pane_ref": registry.ref(kind: "pane", uuid: leaf.paneId),
            "surfaces": [[
                "id": leaf.surfaceId.uuidString,
                "ref": registry.ref(kind: "surface", uuid: leaf.surfaceId),
                "index": 0,
                "selected": true,
                "focused": leaf.surfaceId == tab.focusedSurface?.surfaceId,
                "type": leaf.kind.typeName,
                "title": tab.title
            ]]
        ])
    }

    /// One-call topology: windows → workspaces → panes → surfaces, plus
    /// the active path (selection + focused surface) and the caller's own
    /// position — `cmux tree`, the agent's map of the app.
    private func v2SystemTree(id: Any?, params: [String: Any]) -> String {
        let registry = RefRegistry.shared
        func surfaceNode(_ surface: PaneSurface) -> [String: Any] {
            var node: [String: Any] = [
                "id": surface.surfaceId.uuidString,
                "ref": registry.ref(kind: "surface", uuid: surface.surfaceId),
            ]
            switch surface.kind {
            case .browser:
                node["type"] = "browser"
                if let url = SurfaceRegistry.shared.currentURL(for: surface.surfaceId) {
                    node["url"] = url
                }
                if let title = SurfaceRegistry.shared.currentBrowserTitle(for: surface.surfaceId) {
                    node["title"] = title
                }
            case .inspector:
                node["type"] = "inspector"
            case .terminal:
                node["type"] = "terminal"
                if let title = SurfaceRegistry.shared.currentTerminalTitle(for: surface.surfaceId) {
                    node["title"] = title
                }
            }
            return node
        }
        let workspaces: [[String: Any]] = tabs.wrappedValue.map { tab in
            [
                "id": tab.id.uuidString,
                "ref": registry.ref(kind: "workspace", uuid: tab.id),
                "title": tab.customTitle ?? tab.title,
                "panes": tab.panes.map { pane in
                    [
                        "id": pane.paneId.uuidString,
                        "ref": registry.ref(kind: "pane", uuid: pane.paneId),
                        "surfaces": pane.surfaces.map(surfaceNode),
                    ] as [String: Any]
                },
            ]
        }
        let window: [String: Any] = [
            "id": ControlCommandHandler.windowId.uuidString,
            "ref": registry.ref(kind: "window", uuid: ControlCommandHandler.windowId),
            "workspaces": workspaces,
        ]
        var active: [String: Any] = [
            "window_id": ControlCommandHandler.windowId.uuidString,
            "window_ref": registry.ref(kind: "window", uuid: ControlCommandHandler.windowId),
        ]
        if let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }) {
            active["workspace_id"] = tab.id.uuidString
            active["workspace_ref"] = registry.ref(kind: "workspace", uuid: tab.id)
            if let focused = tab.focusedSurface {
                active["surface_id"] = focused.surfaceId.uuidString
                active["surface_ref"] = registry.ref(kind: "surface", uuid: focused.surfaceId)
                active["pane_id"] = focused.paneId.uuidString
                active["pane_ref"] = registry.ref(kind: "pane", uuid: focused.paneId)
            }
        }
        var caller: [String: Any] = [:]
        if let callerParams = params["caller"] as? [String: Any] {
            if let raw = callerParams["workspace_id"] as? String,
               let wsId = UUID(uuidString: raw) ?? registry.resolve(raw),
               let tab = tabs.wrappedValue.first(where: { $0.id == wsId }) {
                caller["workspace_id"] = tab.id.uuidString
                caller["workspace_ref"] = registry.ref(kind: "workspace", uuid: tab.id)
                if let raw = callerParams["surface_id"] as? String,
                   let sfId = UUID(uuidString: raw) ?? registry.resolve(raw),
                   let leaf = tab.panes.first(where: { p in p.surfaces.contains { $0.surfaceId == sfId } }) {
                    caller["surface_id"] = sfId.uuidString
                    caller["surface_ref"] = registry.ref(kind: "surface", uuid: sfId)
                    caller["pane_id"] = leaf.paneId.uuidString
                    caller["pane_ref"] = registry.ref(kind: "pane", uuid: leaf.paneId)
                }
            }
        }
        return v2Ok(id: id, result: [
            "windows": [window],
            "active": active,
            "caller": caller,
        ])
    }

    /// tmux `last-pane`: focus the previously focused pane of the
    /// workspace, from the history the GTK focus funnel maintains.
    private func v2PaneLast(id: Any?, params: [String: Any]) -> String {
        let tabId = v2WorkspaceUUID(params) ?? selection.wrappedValue
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        let tab = tabs.wrappedValue[index]
        let currentPane = tab.focusedSurface?.paneId
        guard let previous = PaneFocusHistory.shared.previous(
            tabId: tabId, excluding: currentPane, in: tab
        ), let pane = tab.panes.first(where: { $0.paneId == previous }) else {
            return v2Error(id: id, code: "not_found", message: "No previous pane")
        }
        let target = pane.surfaces[safe: pane.selectedIndex] ?? pane.surfaces[0]
        tabs.wrappedValue[index].focusedSurfaceId = target.surfaceId
        refreshTitle(tabId: tabId)
        return v2Ok(id: id, result: [
            "workspace_id": tabId.uuidString,
            "pane_id": pane.paneId.uuidString,
            "pane_ref": RefRegistry.shared.ref(kind: "pane", uuid: pane.paneId),
            "surface_id": target.surfaceId.uuidString,
        ])
    }

    /// `cmux clear-history` — erases the scrollback of a terminal surface.
    /// One escape works on both backends: ED 3 (CSI 3 J, the xterm
    /// extension) fed as terminal OUTPUT clears scrollback and only
    /// scrollback — the visible screen stays, matching macOS.
    /// tmux `respawn-pane -k`: kill the pane's process, start the given
    /// command (or a login shell) in the same pane. VTE panes respawn in
    /// place (same VteTerminal, buffer intact). Ghostty panes use the
    /// macOS strategy — tear the widget down, mount a replacement under
    /// the SAME surface id, replay the captured scrollback: the shim owns
    /// their spawn, so in-place is not available, but identity and buffer
    /// survive the same way macOS's respawnTerminalSurface keeps them.
    private func v2SurfaceRespawn(id: Any?, params: [String: Any]) -> String {
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        let command = (params["command"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "exec ${SHELL:-/bin/sh} -l"
        let requestedCwd = (params["working_directory"] as? String)
            .flatMap { $0.isEmpty ? nil : $0 }
        let leafCwd = target.tab.allSurfaces
            .first { $0.surface.surfaceId == target.surfaceId }?
            .surface.workingDirectory

        if SurfaceRegistry.shared.ghostty(for: target.surfaceId) != nil {
            // Buffer first — the registry read requires the OLD surface,
            // and force skips the capture throttle. The text goes to the
            // replay queue IN MEMORY, not via the disk file: the
            // replacement surface's own periodic capture overwrites the
            // file before the replay poll would read it.
            ScrollbackStore.capture(surfaceId: target.surfaceId, force: true)
            if let text = SurfaceRegistry.shared.scrollbackText(for: target.surfaceId),
               !text.isEmpty {
                TerminalScrollbackStore.pending[target.surfaceId] = text
            }
            let cwd = requestedCwd
                ?? SurfaceRegistry.shared.currentGhosttyDirectory(for: target.surfaceId)
                ?? leafCwd
            SurfaceRegistry.shared.setPendingRespawn(command, workingDirectory: cwd, for: target.surfaceId)
            // Drop the registry's refs; the old widget now lives only in
            // the old skeleton, which the nonce-forced rebuild destroys —
            // the same teardown close-surface exercises daily. The create
            // pass then mounts the replacement (same id, pending command)
            // and startReplay pours the captured buffer back.
            SurfaceRegistry.shared.unregister(target.surfaceId)
            guard let tabIndex = tabs.wrappedValue.firstIndex(where: { $0.id == target.tab.id }) else {
                return v2Error(id: id, code: "internal_error", message: "Workspace vanished mid-respawn")
            }
            tabs.wrappedValue[tabIndex].respawnNonce += 1
            // The rebuild mounts the replacement in the sync this bump
            // triggers, but a widget mounted and eager-started in the SAME
            // pass can miss its GL init — and an unmapped pane then waits
            // for the next unrelated model change to try again. A few
            // settled main-loop passes close that gap (each is idempotent).
            for delayMs in [200, 700, 1500] as [UInt32] {
                scheduleOnMainLoop(afterMs: delayMs) {
                    SurfaceRegistry.shared.realizeHiddenGhosttys()
                    TerminalScrollbackStore.replayPendingIfReady()
                }
            }
            return v2Ok(id: id, result: [
                "workspace_id": target.tab.id.uuidString,
                "surface_id": target.surfaceId.uuidString,
                "respawned": true,
            ])
        }

        guard SurfaceRegistry.shared.respawnTerminal(
            surfaceId: target.surfaceId,
            workspaceId: target.tab.id,
            command: command,
            workingDirectory: requestedCwd ?? leafCwd
        ) else {
            return v2Error(id: id, code: "unavailable", message: "Surface has no terminal to respawn")
        }
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "surface_id": target.surfaceId.uuidString,
            "respawned": true,
        ])
    }

    private func v2SurfaceClearHistory(id: Any?, params: [String: Any]) -> String {
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        guard SurfaceRegistry.shared.writeDisplay(for: target.surfaceId, text: "\u{1B}[3J") else {
            return v2Error(id: id, code: "unavailable", message: "Surface has no terminal to clear")
        }
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "surface_id": target.surfaceId.uuidString,
            "cleared": true,
        ])
    }

    /// The tab-strip mutations our model supports, mirroring macOS's
    /// `tab.action` (same param names, same unknown-action error shape
    /// listing supported_actions). rename pins a per-surface title the
    /// way workspace.rename pins the workspace's.
    private static let tabActionSupported = [
        "rename", "clear_name",
        "close_left", "close_right", "close_others",
        "new_terminal_right", "new_browser_right",
        "reload",
    ]

    private func v2TabAction(id: Any?, params: [String: Any]) -> String {
        guard let action = (params["action"] as? String)?
            .lowercased().replacingOccurrences(of: "-", with: "_"),
            !action.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing action")
        }
        // Target: explicit surface/tab id, else the workspace's focused
        // surface (workspace explicit or selected).
        var surfaceId: UUID?
        if let raw = (params["surface_id"] as? String) ?? (params["tab_id"] as? String) {
            surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        }
        let tab: TerminalTab?
        if let surfaceId {
            tab = tabs.wrappedValue.first { $0.contains(surfaceId: surfaceId) }
        } else if let wsId = v2WorkspaceUUID(params) {
            tab = tabs.wrappedValue.first { $0.id == wsId }
        } else {
            tab = tabs.wrappedValue.first { $0.id == selection.wrappedValue }
        }
        guard let tab else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        let target = surfaceId ?? tab.focusedSurface?.surfaceId
        guard let target,
              let pane = tab.panes.first(where: { p in p.surfaces.contains { $0.surfaceId == target } }),
              let position = pane.surfaces.firstIndex(where: { $0.surfaceId == target }) else {
            return v2Error(id: id, code: "not_found", message: "Tab not found")
        }
        let registry = RefRegistry.shared
        var result: [String: Any] = [
            "workspace_id": tab.id.uuidString,
            "surface_id": target.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: target),
            "action": action,
        ]

        switch action {
        case "rename":
            guard let title = (params["title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
                return v2Error(id: id, code: "invalid_params", message: "Missing or invalid title")
            }
            PaneTabs.customTitles[target] = title
            PaneTabs.refreshAllTitles(tabs: tabs.wrappedValue)
            result["title"] = title
        case "clear_name":
            PaneTabs.customTitles.removeValue(forKey: target)
            PaneTabs.refreshAllTitles(tabs: tabs.wrappedValue)
        case "close_left", "close_right", "close_others":
            let victims: [PaneSurface]
            switch action {
            case "close_left": victims = Array(pane.surfaces[..<position])
            case "close_right": victims = Array(pane.surfaces[(position + 1)...])
            default: victims = pane.surfaces.filter { $0.surfaceId != target }
            }
            for victim in victims {
                closeSurface(tabId: tab.id, surfaceId: victim.surfaceId)
            }
            result["closed"] = victims.count
        case "new_terminal_right", "new_browser_right":
            let kind: SurfaceKind = action == "new_browser_right"
                ? .browser(initialURL: (params["url"] as? String) ?? "")
                : .terminal
            guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }) else {
                return v2Error(id: id, code: "not_found", message: "Workspace not found")
            }
            let cwd = SurfaceRegistry.shared.currentDirectory(for: target) ?? tab.workingDirectory
            let surface = PaneSurface(kind: kind, workingDirectory: cwd)
            guard let layout = tabs.wrappedValue[index].layout.addingTab(surface, nextTo: target) else {
                return v2Error(id: id, code: "internal_error", message: "Failed to add tab")
            }
            tabs.wrappedValue[index].layout = layout
            if (params["focus"] as? Bool) ?? true, tab.id == selection.wrappedValue {
                tabs.wrappedValue[index].focusedSurfaceId = surface.surfaceId
            }
            result["new_surface_id"] = surface.surfaceId.uuidString
            result["new_surface_ref"] = registry.ref(kind: "surface", uuid: surface.surfaceId)
        case "reload":
            guard SurfaceRegistry.shared.reloadBrowser(for: target) else {
                return v2Error(id: id, code: "invalid_params", message: "reload targets a browser tab")
            }
        default:
            return v2Error(id: id, code: "invalid_params", message: "Unknown tab action")
        }
        return v2Ok(id: id, result: result)
    }

    /// Shared position resolution for reorder/move: explicit `index`, or
    /// relative to a reference surface in the TARGET pane. Positions are
    /// computed against the list WITHOUT the moving surface (standard
    /// move-semantics: remove first, then insert).
    private func resolveTabPosition(
        params: [String: Any], in pane: PaneLeaf, excluding moving: UUID
    ) -> Int? {
        let remaining = pane.surfaces.filter { $0.surfaceId != moving }
        if let index = params["index"] as? Int {
            return min(max(index, 0), remaining.count)
        }
        func position(of raw: String?, offset: Int) -> Int? {
            guard let raw,
                  let refId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
                  let at = remaining.firstIndex(where: { $0.surfaceId == refId }) else { return nil }
            return at + offset
        }
        if let before = position(of: params["before_surface_id"] as? String, offset: 0) { return before }
        if let after = position(of: params["after_surface_id"] as? String, offset: 1) { return after }
        return nil
    }

    private func v2SurfaceReorder(id: Any?, params: [String: Any]) -> String {
        guard let raw = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
              let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: surfaceId) }),
              let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }),
              let pane = tab.panes.first(where: { p in p.surfaces.contains { $0.surfaceId == surfaceId } })
        else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        guard let position = resolveTabPosition(params: params, in: pane, excluding: surfaceId) else {
            return v2Error(id: id, code: "invalid_params", message: "reorder requires index, before, or after")
        }
        guard let layout = tabs.wrappedValue[index].layout
            .reorderingTab(surfaceId: surfaceId, to: position) else {
            return v2Error(id: id, code: "internal_error", message: "Reorder failed")
        }
        tabs.wrappedValue[index].layout = layout
        return v2Ok(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "surface_id": surfaceId.uuidString,
            "pane_id": pane.paneId.uuidString,
            "index": position,
        ])
    }

    /// Moves a surface (tab) into another pane — possibly in another
    /// workspace. Purely a model mutation: the pane-tab reconciliation
    /// closes the page on the source strip (isReconciling guards the
    /// surface itself) and unparent-appends the SAME container on the
    /// target strip, so the terminal or browser keeps running across the
    /// move.
    private func v2SurfaceMove(id: Any?, params: [String: Any]) -> String {
        guard let raw = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
              let sourceTab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: surfaceId) }),
              let sourceIndex = tabs.wrappedValue.firstIndex(where: { $0.id == sourceTab.id }),
              let sourcePane = sourceTab.panes.first(where: { p in p.surfaces.contains { $0.surfaceId == surfaceId } }),
              let surface = sourcePane.surfaces.first(where: { $0.surfaceId == surfaceId })
        else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }

        // Target pane: explicit pane_id, else the target workspace's
        // focused pane.
        var targetTabIndex: Int?
        var targetPane: PaneLeaf?
        if let paneRaw = params["pane_id"] as? String,
           let paneId = UUID(uuidString: paneRaw) ?? RefRegistry.shared.resolve(paneRaw) {
            for (tabIdx, tab) in tabs.wrappedValue.enumerated() {
                if let pane = tab.panes.first(where: { $0.paneId == paneId }) {
                    targetTabIndex = tabIdx
                    targetPane = pane
                    break
                }
            }
        } else if let wsId = v2WorkspaceUUID(params),
                  let tabIdx = tabs.wrappedValue.firstIndex(where: { $0.id == wsId }) {
            let tab = tabs.wrappedValue[tabIdx]
            targetTabIndex = tabIdx
            targetPane = tab.panes.first { p in
                p.surfaces.contains { $0.surfaceId == tab.focusedSurfaceId }
            } ?? tab.panes.first
        }
        guard let targetTabIndex, let targetPane else {
            return v2Error(id: id, code: "invalid_params", message: "move requires a target pane or workspace")
        }

        if targetPane.paneId == sourcePane.paneId {
            // Same pane: this is a reorder.
            return v2SurfaceReorder(id: id, params: params)
        }
        let position = resolveTabPosition(params: params, in: targetPane, excluding: surfaceId)

        // Detach the container BEFORE the model changes: the source
        // workspace's rebuild destroys its old skeleton, and a container
        // still inside it dies with it (a destroyed Ghostty widget kills
        // its shell — "pty fd closed"). Parentless, it just waits for the
        // target workspace's build to adopt it.
        PaneTabs.detachIfLive(surfaceId)
        // Remove from the source. nil = the source workspace has no panes
        // left; it closes after the surface is safely inserted elsewhere.
        let sourceRemainder = tabs.wrappedValue[sourceIndex].layout.removing(surfaceId: surfaceId)
        if sourceIndex == targetTabIndex {
            guard let sourceRemainder,
                  let layout = sourceRemainder.addingTab(surface, toPane: targetPane.paneId, at: position) else {
                return v2Error(id: id, code: "internal_error", message: "Move failed")
            }
            tabs.wrappedValue[sourceIndex].layout = layout
        } else {
            guard let targetLayout = tabs.wrappedValue[targetTabIndex].layout
                .addingTab(surface, toPane: targetPane.paneId, at: position) else {
                return v2Error(id: id, code: "internal_error", message: "Move failed")
            }
            tabs.wrappedValue[targetTabIndex].layout = targetLayout
            if let sourceRemainder {
                tabs.wrappedValue[sourceIndex].layout = sourceRemainder
                // The moved surface may have been the source's focus.
                if tabs.wrappedValue[sourceIndex].focusedSurfaceId == surfaceId,
                   let fallback = tabs.wrappedValue[sourceIndex].panes.first?.selected.surfaceId {
                    tabs.wrappedValue[sourceIndex].focusedSurfaceId = fallback
                }
            } else {
                // Moving the last surface out empties the workspace.
                removeWorkspace(at: sourceIndex)
            }
        }

        let registry = RefRegistry.shared
        let targetTabId = tabs.wrappedValue.first { $0.contains(surfaceId: surfaceId) }?.id
        if (params["focus"] as? Bool) == true, let targetTabId {
            if selection.wrappedValue != targetTabId { select(targetTabId) }
            if let idx = tabs.wrappedValue.firstIndex(where: { $0.id == targetTabId }) {
                tabs.wrappedValue[idx].focusedSurfaceId = surfaceId
            }
        }
        refreshTitle(tabId: targetTabId ?? sourceTab.id)
        return v2Ok(id: id, result: [
            "workspace_id": (targetTabId ?? sourceTab.id).uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: targetTabId ?? sourceTab.id),
            "surface_id": surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: surfaceId),
            "pane_id": targetPane.paneId.uuidString,
            "pane_ref": registry.ref(kind: "pane", uuid: targetPane.paneId),
        ])
    }

    private func resolvePane(_ raw: String?) -> (tabIndex: Int, pane: PaneLeaf)? {
        guard let raw, let paneId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        else { return nil }
        for (index, tab) in tabs.wrappedValue.enumerated() {
            if let pane = tab.panes.first(where: { $0.paneId == paneId }) {
                return (index, pane)
            }
        }
        return nil
    }

    /// tmux swap-pane: exchange two panes' contents; identities and
    /// divider geometry stay, the reconciliation reparents the tabs.
    private func v2PaneSwap(id: Any?, params: [String: Any]) -> String {
        guard let target = resolvePane(params["target_pane_id"] as? String) else {
            return v2Error(id: id, code: "invalid_params", message: "swap requires target_pane_id")
        }
        let source: (tabIndex: Int, pane: PaneLeaf)?
        if params["pane_id"] != nil {
            source = resolvePane(params["pane_id"] as? String)
        } else if let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }),
                  let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }),
                  let focused = tab.focusedSurface {
            source = tab.panes.first { $0.paneId == focused.paneId }.map { (index, $0) }
        } else {
            source = nil
        }
        guard let source else {
            return v2Error(id: id, code: "not_found", message: "Source pane not found")
        }
        guard source.tabIndex == target.tabIndex else {
            return v2Error(id: id, code: "invalid_params", message: "swap-pane works within one workspace")
        }
        guard let layout = tabs.wrappedValue[source.tabIndex].layout
            .swappingPanes(source.pane.paneId, target.pane.paneId) else {
            return v2Error(id: id, code: "internal_error", message: "Swap failed")
        }
        tabs.wrappedValue[source.tabIndex].layout = layout
        return v2Ok(id: id, result: [
            "workspace_id": tabs.wrappedValue[source.tabIndex].id.uuidString,
            "pane_id": source.pane.paneId.uuidString,
            "target_pane_id": target.pane.paneId.uuidString,
        ])
    }

    /// tmux break-pane: the surface leaves its pane and becomes a new
    /// workspace of its own.
    private func v2PaneBreak(id: Any?, params: [String: Any]) -> String {
        // Target surface: explicit, else the given pane's visible tab,
        // else the selected workspace's focused surface.
        var surfaceId: UUID?
        if let raw = params["surface_id"] as? String {
            surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        } else if let pane = resolvePane(params["pane_id"] as? String) {
            surfaceId = pane.pane.selected.surfaceId
        } else if let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }) {
            surfaceId = tab.focusedSurface?.surfaceId
        }
        guard let surfaceId,
              let sourceTab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: surfaceId) }),
              let sourceIndex = tabs.wrappedValue.firstIndex(where: { $0.id == sourceTab.id }),
              let sourcePane = sourceTab.panes.first(where: { p in p.surfaces.contains { $0.surfaceId == surfaceId } }),
              let surface = sourcePane.surfaces.first(where: { $0.surfaceId == surfaceId })
        else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        // Breaking the only surface of a single-pane workspace is a no-op
        // that would churn workspaces; refuse like tmux does.
        if sourceTab.panes.count == 1 && sourcePane.surfaces.count == 1 {
            return v2Error(id: id, code: "invalid_params", message: "Pane is already the only pane of its workspace")
        }
        // Same rule as surface.move: parentless before the model changes,
        // or the source rebuild destroys the widget (and the shell).
        PaneTabs.detachIfLive(surfaceId)
        guard let remainder = tabs.wrappedValue[sourceIndex].layout.removing(surfaceId: surfaceId) else {
            return v2Error(id: id, code: "internal_error", message: "Break failed")
        }
        tabs.wrappedValue[sourceIndex].layout = remainder
        if tabs.wrappedValue[sourceIndex].focusedSurfaceId == surfaceId,
           let fallback = tabs.wrappedValue[sourceIndex].panes.first?.selected.surfaceId {
            tabs.wrappedValue[sourceIndex].focusedSurfaceId = fallback
        }
        tabCounter.wrappedValue += 1
        var newTab = TerminalTab(
            title: PaneTabs.customTitles[surfaceId] ?? "Terminal \(tabCounter.wrappedValue)",
            workingDirectory: surface.workingDirectory
        )
        // The init creates a fresh empty pane; replace it with the broken-
        // out surface and point focus at it.
        newTab.layout = .leaf(PaneLeaf(surfaces: [surface], selectedIndex: 0))
        newTab.focusedSurfaceId = surfaceId
        tabs.wrappedValue.append(newTab)
        if (params["focus"] as? Bool) ?? true {
            select(newTab.id)
        }
        let registry = RefRegistry.shared
        return v2Ok(id: id, result: [
            "workspace_id": newTab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: newTab.id),
            "surface_id": surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: surfaceId),
        ])
    }

    /// tmux join-pane: the inverse of break — the source surface joins the
    /// target pane as a tab. Delegates to surface.move (identical
    /// semantics, identical reconciliation path).
    private func v2PaneJoin(id: Any?, params: [String: Any]) -> String {
        guard let targetRaw = params["target_pane_id"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "join requires target_pane_id")
        }
        var surfaceRaw = params["surface_id"] as? String
        if surfaceRaw == nil, let source = resolvePane(params["pane_id"] as? String) {
            surfaceRaw = source.pane.selected.surfaceId.uuidString
        }
        if surfaceRaw == nil,
           let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }) {
            surfaceRaw = tab.focusedSurface?.surfaceId.uuidString
        }
        guard let surfaceRaw else {
            return v2Error(id: id, code: "not_found", message: "Source surface not found")
        }
        var moveParams: [String: Any] = ["surface_id": surfaceRaw, "pane_id": targetRaw]
        if let focus = params["focus"] { moveParams["focus"] = focus }
        return v2SurfaceMove(id: id, params: moveParams)
    }

    /// tmux resize-pane: walk from the pane's container up to the nearest
    /// GtkPaned of the matching orientation and shift its divider. Amounts
    /// are cells, approximated at 10px horizontal / 18px vertical — the
    /// same order tmux users expect per step.
    private func v2PaneResize(id: Any?, params: [String: Any]) -> String {
        guard let direction = params["direction"] as? String,
              ["left", "right", "up", "down"].contains(direction) else {
            return v2Error(id: id, code: "invalid_params", message: "resize requires direction left|right|up|down")
        }
        let amount = (params["amount"] as? Int) ?? 1
        let pane: PaneLeaf?
        if let resolved = resolvePane(params["pane_id"] as? String) {
            pane = resolved.pane
        } else if let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }),
                  let focused = tab.focusedSurface {
            pane = tab.panes.first { $0.paneId == focused.paneId }
        } else {
            pane = nil
        }
        guard let pane,
              let container = SurfaceRegistry.shared.containers[pane.selected.surfaceId] else {
            return v2Error(id: id, code: "not_found", message: "Pane not found")
        }
        let horizontal = direction == "left" || direction == "right"
        // Nearest ancestor paned of the right orientation owns the divider
        // this pane's edge belongs to.
        var widget: UnsafeMutablePointer<GtkWidget>? = UnsafeMutablePointer<GtkWidget>(container)
        var paned: OpaquePointer?
        while let current = widget {
            if g_type_check_instance_is_a(
                UnsafeMutableRawPointer(current).assumingMemoryBound(to: GTypeInstance.self),
                gtk_paned_get_type()
            ) != 0 {
                let candidate = OpaquePointer(current)
                let isHorizontal = gtk_orientable_get_orientation(candidate) == GTK_ORIENTATION_HORIZONTAL
                if isHorizontal == horizontal {
                    paned = candidate
                    break
                }
            }
            widget = gtk_widget_get_parent(current)
        }
        guard let paned else {
            return v2Error(id: id, code: "not_found", message: "No divider in that direction")
        }
        let pixels = amount * (horizontal ? 10 : 18)
        let delta = (direction == "left" || direction == "up") ? -pixels : pixels
        let panedWidget = UnsafeMutablePointer<GtkWidget>(paned)
        let total = horizontal ? gtk_widget_get_width(panedWidget) : gtk_widget_get_height(panedWidget)
        let position = gtk_paned_get_position(paned)
        let clamped = max(20, min(Int(total) - 20, Int(position) + delta))
        gtk_paned_set_position(paned, Int32(clamped))
        return v2Ok(id: id, result: [
            "pane_id": pane.paneId.uuidString,
            "position": clamped,
            "total": Int(total),
        ])
    }

    private func v2PaneFocus(id: Any?, params: [String: Any]) -> String {
        guard let raw = params["pane_id"] as? String,
              let paneId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw) else {
            return v2Error(id: id, code: "invalid_params", message: "Missing or invalid pane_id")
        }
        for (index, tab) in tabs.wrappedValue.enumerated() {
            if let leaf = tab.surfaces.first(where: { $0.paneId == paneId }) {
                if selection.wrappedValue != tab.id {
                    select(tab.id)
                }
                tabs.wrappedValue[index].focusedSurfaceId = leaf.surfaceId
                refreshTitle(tabId: tab.id)
                return v2Ok(id: id, result: [
                    "workspace_id": tab.id.uuidString,
                    "pane_id": leaf.paneId.uuidString,
                    "surface_id": leaf.surfaceId.uuidString
                ])
            }
        }
        return v2Error(id: id, code: "not_found", message: "Pane not found")
    }

    private func v2SurfaceSplit(id: Any?, params: [String: Any]) -> String {
        guard let direction = params["direction"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing direction")
        }
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        guard let newLeaf = split(tab: target.tab, surfaceId: target.surfaceId, direction: direction) else {
            return v2Error(id: id, code: "invalid_params", message: "Invalid direction. Use left, right, up, or down.")
        }
        let registry = RefRegistry.shared
        return v2Ok(id: id, result: [
            "window_id": Self.windowId.uuidString,
            "window_ref": registry.ref(kind: "window", uuid: Self.windowId),
            "workspace_id": target.tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: target.tab.id),
            "surface_id": newLeaf.surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: newLeaf.surfaceId),
            "pane_id": newLeaf.paneId.uuidString,
            "pane_ref": registry.ref(kind: "pane", uuid: newLeaf.paneId)
        ])
    }

    /// `pane.create`/`surface.create` (CLI `new-pane`/`new-surface`) — with
    /// one surface per pane these are both "split with a typed surface".
    private func v2PaneCreate(id: Any?, params: [String: Any]) -> String {
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        let direction = (params["direction"] as? String) ?? "right"
        let kind: SurfaceKind
        if (params["type"] as? String) == "browser" {
            let url = (params["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
            kind = .browser(initialURL: url)
        } else {
            kind = .terminal
        }
        guard let newLeaf = split(
            tab: target.tab,
            surfaceId: target.surfaceId,
            direction: direction,
            kind: kind
        ) else {
            return v2Error(id: id, code: "invalid_params", message: "Invalid direction. Use left, right, up, or down.")
        }
        let registry = RefRegistry.shared
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: target.tab.id),
            "pane_id": newLeaf.paneId.uuidString,
            "pane_ref": registry.ref(kind: "pane", uuid: newLeaf.paneId),
            "surface_id": newLeaf.surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: newLeaf.surfaceId),
            "type": newLeaf.kind.typeName
        ])
    }

    private func v2SurfaceClose(id: Any?, params: [String: Any]) -> String {
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        closeSurface(tabId: target.tab.id, surfaceId: target.surfaceId)
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "surface_id": target.surfaceId.uuidString
        ])
    }

    /// Removes a surface's pane; closing the last pane closes the workspace.
    /// Notifications belonging to the closed surface (or the whole closed
    /// workspace) are dropped so the list never points at dead targets.
    func closeSurface(tabId: UUID, surfaceId: UUID) {
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) else { return }
        if tabs.wrappedValue[index].layout.removing(surfaceId: surfaceId) != nil {
            notifications.wrappedValue.removeAll { $0.surfaceId == surfaceId }
        } else {
            notifications.wrappedValue.removeAll { $0.tabId == tabId }
        }
        if let remaining = tabs.wrappedValue[index].layout.removing(surfaceId: surfaceId) {
            tabs.wrappedValue[index].layout = remaining
            if tabs.wrappedValue[index].focusedSurfaceId == surfaceId,
               let first = remaining.leaves.first {
                tabs.wrappedValue[index].focusedSurfaceId = first.surfaceId
            }
            refreshTitle(tabId: tabId)
        } else {
            removeWorkspace(at: index)
        }
    }

    /// Splits the pane holding `surfaceId`; a new terminal inherits the
    /// split-off shell's current directory (OSC 7) when known. Returns the
    /// new leaf, or nil for an invalid direction/surface.
    @discardableResult
    /// `prepare` runs after the leaf exists but BEFORE the layout mutation:
    /// mutating the tab layout can re-render (and run the surface factory)
    /// before this function returns, so anything the factory must find —
    /// a pending profile assignment, say — has to be parked first. Same
    /// rule as `adoptBrowserSplit`'s register closure, learned there.
    func split(
        tab: TerminalTab,
        surfaceId: UUID,
        direction: String,
        kind: SurfaceKind = .terminal,
        prepare: (UUID) -> Void = { _ in }
    ) -> PaneLeaf? {
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }) else { return nil }
        let cwd = SurfaceRegistry.shared.currentDirectory(for: surfaceId)
            ?? tab.workingDirectory
        let newLeaf = PaneLeaf(kind: kind, workingDirectory: cwd)
        prepare(newLeaf.surfaceId)
        guard let layout = tabs.wrappedValue[index].layout.splitting(
            surfaceId: surfaceId,
            direction: direction,
            newLeaf: newLeaf
        ) else { return nil }
        tabs.wrappedValue[index].layout = layout
        tabs.wrappedValue[index].focusedSurfaceId = newLeaf.surfaceId
        return newLeaf
    }

    /// Create an empty browser pane in the selected workspace for a
    /// WebDriver automation view to be adopted into.
    ///
    /// `register` runs BEFORE the model mutation on purpose: mutating the
    /// tab layout can trigger a re-render (and thus the surface factory)
    /// before this function returns, so the pending view must already be
    /// registered or the factory builds its own blank view and the
    /// driver ends up driving an orphan (observed exactly that way).
    /// Splits along the pane's longer axis, so repeated splits stay usable.
    /// Always splitting "right" halves the width every time: two popups are
    /// comfortable, five are unreadable slivers. Falls back to "right" for
    /// a pane that has no allocation yet (not realized).
    func preferredSplitDirection(for surfaceId: UUID) -> String {
        guard let container = SurfaceRegistry.shared.containers[surfaceId] else { return "right" }
        let widget = UnsafeMutableRawPointer(container).assumingMemoryBound(to: GtkWidget.self)
        let width = gtk_widget_get_width(widget)
        let height = gtk_widget_get_height(widget)
        guard width > 0, height > 0 else { return "right" }
        return width >= height ? "right" : "down"
    }

    /// Adopts a pre-created web view as a new TAB in the pane hosting the
    /// anchor. This is what popups use: a second page is a tab, not another
    /// split, so opening five of them no longer shreds the layout.
    func adoptBrowserTab(nextTo anchor: UUID, register: (UUID) -> Void) -> UUID? {
        addBrowserTab(nextTo: anchor, url: "", register: register)
    }

    /// Adds a browser surface as a tab in the pane hosting `anchor`. Shared
    /// by popup adoption (which pre-creates the web view and registers it)
    /// and `browser.tab.new` (which just wants a URL).
    @discardableResult
    func addBrowserTab(
        nextTo anchor: UUID, url: String, register: (UUID) -> Void = { _ in }
    ) -> UUID? {
        guard let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: anchor) }),
              let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id })
        else { return nil }
        let cwd = SurfaceRegistry.shared.currentDirectory(for: anchor) ?? tab.workingDirectory
        let surface = PaneSurface(kind: .browser(initialURL: url), workingDirectory: cwd)
        register(surface.surfaceId)
        guard let layout = tabs.wrappedValue[index].layout.addingTab(surface, nextTo: anchor) else {
            return nil
        }
        tabs.wrappedValue[index].layout = layout
        if tab.id == selection.wrappedValue {
            tabs.wrappedValue[index].focusedSurfaceId = surface.surfaceId
        }
        return surface.surfaceId
    }

    /// Toggles pane zoom (macOS `toggleSplitZoom`): the target's pane
    /// fills the workspace, or returns to the split tree if it already
    /// does. Zooming a different pane while one is zoomed switches to it
    /// rather than un-zooming, which is what "zoom this one" means.
    @discardableResult
    func toggleZoom(tabId: UUID, surfaceId: UUID?) -> UUID? {
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) else { return nil }
        let target = surfaceId ?? tabs.wrappedValue[index].focusedSurface?.surfaceId
        guard let target, tabs.wrappedValue[index].contains(surfaceId: target) else { return nil }
        let current = tabs.wrappedValue[index].zoomedSurfaceId
        let zoomed = (current != nil && tabs.wrappedValue[index]
            .panes.first { $0.contains(surfaceId: target) }?
            .contains(surfaceId: current!) == true) ? nil : target
        tabs.wrappedValue[index].zoomedSurfaceId = zoomed
        if zoomed != nil { tabs.wrappedValue[index].focusedSurfaceId = target }
        return zoomed
    }

    /// Selects the next/previous workspace (macOS `nextSidebarTab` /
    /// `prevSidebarTab`). Shares the wrap-around behaviour of the
    /// `workspace.next` verb rather than reimplementing it.
    @discardableResult
    func stepWorkspace(forward: Bool) -> UUID? {
        let allTabs = tabs.wrappedValue
        guard let index = allTabs.firstIndex(where: { $0.id == selection.wrappedValue }),
              allTabs.count > 1 else { return nil }
        let count = allTabs.count
        let target = allTabs[forward ? (index + 1) % count : (index + count - 1) % count].id
        select(target)
        return target
    }

    /// Cycles the focused surface within a workspace (macOS `nextSurface`
    /// / `prevSurface`). Walks every surface including background tabs, so
    /// a tabbed pane is not skipped over as if it held one.
    func stepFocusedSurface(tabId: UUID, forward: Bool) {
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) else { return }
        let all = tabs.wrappedValue[index].allSurfaces.map(\.surface.surfaceId)
        guard all.count > 1 else { return }
        let current = all.firstIndex(of: tabs.wrappedValue[index].focusedSurfaceId) ?? 0
        let next = forward
            ? (current + 1) % all.count
            : (current - 1 + all.count) % all.count
        let target = all[next]
        // Selecting the surface also brings its tab to the front, so
        // cycling through a tabbed pane actually shows each one.
        tabs.wrappedValue[index].layout = tabs.wrappedValue[index].layout.selecting(surfaceId: target)
        tabs.wrappedValue[index].focusedSurfaceId = target
    }

    /// A tab strip changed selection.
    func selectSurfaceTab(tabId: UUID, surfaceId: UUID) {
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) else { return }
        tabs.wrappedValue[index].layout = tabs.wrappedValue[index].layout.selecting(surfaceId: surfaceId)
        tabs.wrappedValue[index].focusedSurfaceId = surfaceId
    }

    /// Adopts a pre-created web view into a new split.
    ///
    /// `nextTo` anchors the split to a specific surface — a popup must land
    /// beside its opener, which is not necessarily the focused surface and
    /// may sit in a workspace the human is not looking at. Passing nil
    /// keeps the original behavior (split the selected workspace's focused
    /// surface), which is what WebDriver adoption wants.
    func adoptBrowserSplit(nextTo anchor: UUID? = nil, register: (UUID) -> Void) -> UUID? {
        let resolved: (tab: TerminalTab, surfaceId: UUID)?
        if let anchor, let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: anchor) }) {
            resolved = (tab, anchor)
        } else if let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }),
                  let focused = tab.focusedSurface {
            resolved = (tab, focused.surfaceId)
        } else {
            resolved = nil
        }
        guard let resolved,
              let index = tabs.wrappedValue.firstIndex(where: { $0.id == resolved.tab.id })
        else { return nil }

        let cwd = SurfaceRegistry.shared.currentDirectory(for: resolved.surfaceId)
            ?? resolved.tab.workingDirectory
        let newLeaf = PaneLeaf(kind: .browser(initialURL: ""), workingDirectory: cwd)
        register(newLeaf.surfaceId)

        guard let layout = tabs.wrappedValue[index].layout.splitting(
            surfaceId: resolved.surfaceId,
            direction: preferredSplitDirection(for: resolved.surfaceId),
            newLeaf: newLeaf
        ) else { return nil }
        tabs.wrappedValue[index].layout = layout
        // Focus the new pane only within a workspace the human is already
        // looking at; a popup in a background workspace must not reach out
        // and move focus (socket focus policy).
        if resolved.tab.id == selection.wrappedValue {
            tabs.wrappedValue[index].focusedSurfaceId = newLeaf.surfaceId
        }
        return newLeaf.surfaceId
    }

    private func v2SurfaceSendText(id: Any?, params: [String: Any]) -> String {
        guard let text = params["text"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing text")
        }
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        if let error = sendBytes(text, to: target.surfaceId) {
            return v2Error(id: id, code: error.code, message: error.message)
        }
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "surface_id": target.surfaceId.uuidString
        ])
    }

    /// Raw PTY write dispatched by surface kind (VTE feed / ghostty shim).
    /// Returns nil on success.
    private func sendBytes(_ text: String, to surfaceId: UUID) -> (code: String, message: String)? {
        #if canImport(CGhosttyEmbed)
        if SurfaceRegistry.shared.ghostty(for: surfaceId) != nil {
            if SurfaceRegistry.shared.ghosttyChildExited(for: surfaceId) {
                return ("unavailable", "Surface shell has exited")
            }
            guard SurfaceRegistry.shared.ghosttySendText(text, to: surfaceId) else {
                return ("unavailable", "Surface shell not running yet (select its workspace to start it)")
            }
            return nil
        }
        #endif
        guard let terminal = SurfaceRegistry.shared.terminal(for: surfaceId) else {
            return ("not_found", "Surface not found")
        }
        feed(terminal, text)
        return nil
    }

    private func v2SurfaceSendKey(id: Any?, params: [String: Any]) -> String {
        guard let key = params["key"] as? String, !key.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing key")
        }
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        guard let bytes = Self.namedKeyBytes(key) else {
            return v2Error(id: id, code: "invalid_params", message: "Unknown key: \(key)")
        }
        if let error = sendBytes(bytes, to: target.surfaceId) {
            return v2Error(id: id, code: error.code, message: error.message)
        }
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "surface_id": target.surfaceId.uuidString,
            "key": key
        ])
    }

    /// Named keys → PTY bytes. Same names as the macOS `sendNamedKey`, plus
    /// arrow keys (which VTE takes as escape sequences rather than keycodes).
    static func namedKeyBytes(_ name: String) -> String? {
        switch name.lowercased() {
        case "enter", "return":
            return "\r"
        case "tab":
            return "\t"
        case "escape", "esc":
            return "\u{1b}"
        case "backspace":
            return "\u{7f}"
        case "space":
            return " "
        case "up":
            return "\u{1b}[A"
        case "down":
            return "\u{1b}[B"
        case "right":
            return "\u{1b}[C"
        case "left":
            return "\u{1b}[D"
        case "sigint":
            return "\u{03}"
        case "eof":
            return "\u{04}"
        case "sigtstp":
            return "\u{1a}"
        case "sigquit":
            return "\u{1c}"
        default:
            let lowered = name.lowercased()
            if lowered.hasPrefix("ctrl-") || lowered.hasPrefix("ctrl+") {
                let rest = lowered.dropFirst(5)
                if rest == "\\" {
                    return "\u{1c}"
                }
                if rest.count == 1, let char = rest.first,
                   let ascii = char.asciiValue, ascii >= 97, ascii <= 122 {
                    return String(UnicodeScalar(ascii - 96))
                }
            }
            return nil
        }
    }

    private func v2SurfaceReadText(id: Any?, params: [String: Any]) -> String {
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        #if canImport(CGhosttyEmbed)
        if SurfaceRegistry.shared.ghostty(for: target.surfaceId) != nil {
            let scrollback = (params["scrollback"] as? Bool)
                ?? (params["scrollback"] as? NSNumber)?.boolValue
                ?? false
            guard var text = SurfaceRegistry.shared.ghosttyReadText(
                for: target.surfaceId, includeScrollback: scrollback
            ) else {
                return v2Error(id: id, code: "unavailable", message: "Surface shell not running yet (select its workspace to start it)")
            }
            if let lines = params["lines"] as? Int, lines > 0 {
                let all = text.split(separator: "\n", omittingEmptySubsequences: false)
                text = all.suffix(lines).joined(separator: "\n")
            }
            return v2Ok(id: id, result: [
                "workspace_id": target.tab.id.uuidString,
                "surface_id": target.surfaceId.uuidString,
                "text": text
            ])
        }
        #endif
        guard let terminal = SurfaceRegistry.shared.terminal(for: target.surfaceId) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        // `scrollback:true` returns the whole retained buffer — parity
        // with the Ghostty path (this closed a PARITY gap on 2026-07-22).
        if (params["scrollback"] as? Bool) == true,
           var text = SurfaceRegistry.shared.vteScrollbackText(for: target.surfaceId) {
            if let lines = params["lines"] as? Int, lines > 0 {
                let all = text.split(separator: "\n", omittingEmptySubsequences: false)
                text = all.suffix(lines).joined(separator: "\n")
            }
            return v2Ok(id: id, result: [
                "workspace_id": target.tab.id.uuidString,
                "surface_id": target.surfaceId.uuidString,
                "text": text
            ])
        }
        // Read the screenful ending at the cursor, not the viewport: an
        // unmapped terminal (background workspace) never scrolls its
        // viewport, which would return a stale first screenful forever.
        var cursorCol: glong = 0
        var cursorRow: glong = 0
        vte_terminal_get_cursor_position(terminal, &cursorCol, &cursorRow)
        let visibleRows = glong(vte_terminal_get_row_count(terminal))
        let startRow = max(0, cursorRow - visibleRows + 1)
        var text = ""
        if let raw = vte_terminal_get_text_range_format(
            terminal, VTE_FORMAT_TEXT, startRow, 0, cursorRow, -1, nil
        ) {
            text = String(cString: raw)
            g_free(raw)
        }
        // `lines` limits to the last N lines (macOS-compatible); scrollback
        // beyond the visible screen is not captured yet on Linux.
        if let lines = params["lines"] as? Int, lines > 0 {
            let all = text.split(separator: "\n", omittingEmptySubsequences: false)
            text = all.suffix(lines).joined(separator: "\n")
        }
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "surface_id": target.surfaceId.uuidString,
            "text": text
        ])
    }

    /// Resolves the target surface from `surface_id`/`workspace_id` params
    /// (UUIDs or handle refs), defaulting to the selected tab's focused
    /// surface.
    private func v2TargetSurface(_ params: [String: Any]) -> (tab: TerminalTab, surfaceId: UUID)? {
        if let raw = params["surface_id"] as? String, !raw.isEmpty {
            guard let uuid = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
                  let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: uuid) }) else {
                return nil
            }
            return (tab, uuid)
        }
        let wsId = v2WorkspaceUUID(params) ?? selection.wrappedValue
        guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }),
              let focused = tab.focusedSurface else { return nil }
        return (tab, focused.surfaceId)
    }

    private func v2NotificationCreate(id: Any?, params: [String: Any]) -> String {
        guard let tab = tabs.wrappedValue.first(where: { $0.id == selection.wrappedValue }) else {
            return v2Error(id: id, code: "not_found", message: "No workspace selected")
        }
        let title = (params["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "cmux"
        let notification = TerminalNotification(
            tabId: tab.id,
            surfaceId: tab.focusedSurface?.surfaceId,
            title: title,
            subtitle: params["subtitle"] as? String ?? "",
            body: params["body"] as? String ?? ""
        )
        notifications.wrappedValue.append(notification)
        if let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }) {
            tabs.wrappedValue[index].needsAttention = true
        }
        return v2Ok(id: id, result: ["notification_id": notification.id.uuidString])
    }

    /// v2 aliases of the v1 notify_surface / notify_target verbs — explicit
    /// workspace+surface targeting with the macOS param/result shapes.
    /// `create_for_surface` falls back to the selected workspace;
    /// `create_for_target` requires workspace_id.
    /// Upstream's evolved notify flow (2026 CLI): target the CALLER's
    /// workspace/surface, resolved from the params the CLI collects —
    /// `preferred_workspace_id`/`preferred_surface_id` when the caller
    /// knows them (CMUX_WORKSPACE_ID env), else the caller block, else the
    /// selected workspace. Found by ui-commands-smoke: `cmux notify`
    /// silently stopped working after the catch-up merge renamed the
    /// method it sends.
    private func v2NotificationCreateForCaller(id: Any?, params: [String: Any]) -> String {
        var tabId: UUID?
        if let raw = params["preferred_workspace_id"] as? String {
            tabId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        }
        if tabId == nil, let caller = params["caller"] as? [String: Any],
           let raw = caller["workspace_id"] as? String {
            tabId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        }
        let tab = tabId.flatMap { candidate in tabs.wrappedValue.first { $0.id == candidate } }
            ?? tabs.wrappedValue.first { $0.id == selection.wrappedValue }
        guard let tab, let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        var surfaceId: UUID?
        if let raw = (params["preferred_surface_id"] as? String)
            ?? ((params["caller"] as? [String: Any])?["surface_id"] as? String) {
            surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw)
        }
        notifications.wrappedValue.append(TerminalNotification(
            tabId: tab.id,
            surfaceId: surfaceId,
            title: (params["title"] as? String) ?? "Notification",
            subtitle: (params["subtitle"] as? String) ?? "",
            body: (params["body"] as? String) ?? ""
        ))
        tabs.wrappedValue[index].needsAttention = true
        // Desktop delivery only for tabs the user isn't looking at,
        // approximating macOS's suppress-when-focused behavior.
        if tab.id != selection.wrappedValue {
            DesktopNotifier.send(
                id: "cmux-\(tab.id.uuidString)",
                title: (params["title"] as? String) ?? "Notification",
                body: [(params["subtitle"] as? String) ?? "", (params["body"] as? String) ?? ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
            )
        }
        return v2Ok(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "notification_created": true
        ])
    }

    private func v2NotificationCreateFor(id: Any?, params: [String: Any], requireWorkspace: Bool) -> String {
        guard let surfaceRaw = params["surface_id"] as? String,
              let surfaceId = UUID(uuidString: surfaceRaw) ?? RefRegistry.shared.resolve(surfaceRaw) else {
            return v2Error(id: id, code: "invalid_params", message: "Missing or invalid surface_id")
        }
        let tab: TerminalTab?
        if let wsId = v2WorkspaceUUID(params) {
            tab = tabs.wrappedValue.first { $0.id == wsId }
        } else if requireWorkspace {
            return v2Error(id: id, code: "invalid_params", message: "Missing or invalid workspace_id")
        } else {
            tab = tabs.wrappedValue.first { $0.id == selection.wrappedValue }
        }
        guard let tab else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        guard tab.contains(surfaceId: surfaceId) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }

        notifications.wrappedValue.append(TerminalNotification(
            tabId: tab.id,
            surfaceId: surfaceId,
            title: (params["title"] as? String) ?? "Notification",
            subtitle: (params["subtitle"] as? String) ?? "",
            body: (params["body"] as? String) ?? ""
        ))
        if let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }) {
            tabs.wrappedValue[index].needsAttention = true
        }

        let registry = RefRegistry.shared
        var result = workspaceRefResult(tab.id)
        result["surface_id"] = surfaceId.uuidString
        result["surface_ref"] = registry.ref(kind: "surface", uuid: surfaceId)
        return v2Ok(id: id, result: result)
    }

    /// Accepts a UUID string or a `workspace:<n>` handle ref.
    private func v2WorkspaceUUID(_ params: [String: Any]) -> UUID? {
        guard let raw = params["workspace_id"] as? String,
              !raw.isEmpty else { return nil }
        if let uuid = UUID(uuidString: raw) { return uuid }
        return RefRegistry.shared.resolve(raw)
    }

    // MARK: v2 envelope helpers

    /// Forces a full session save with final-save semantics (scrollback
    /// read unthrottled). The promotion script calls this before
    /// restarting the daily instance, so a scripted restart loses nothing
    /// even on binaries whose close path predates the exit save.
    private func v2SessionSave(id: Any?) -> String {
        SessionStore.isFinalSave = true
        SessionStore.saveIfChanged(
            tabs: tabs.wrappedValue,
            selection: selection.wrappedValue,
            tabCounter: tabCounter.wrappedValue
        )
        SessionStore.isFinalSave = false
        return v2Ok(id: id, result: ["saved": true])
    }

    func v2Ok(id: Any?, result: [String: Any]) -> String {
        v2Encode(["id": id ?? NSNull(), "ok": true, "result": result])
    }

    func v2Error(id: Any?, code: String, message: String) -> String {
        v2Encode(["id": id ?? NSNull(), "ok": false, "error": ["code": code, "message": message]])
    }

    private func v2Encode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }
        return string.replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: helpers

    /// Accepts a UUID or a list index, like the macOS `resolveTab(from:)`.
    private func resolveTab(from arg: String) -> TerminalTab? {
        if let uuid = UUID(uuidString: arg) {
            return tabs.wrappedValue.first { $0.id == uuid }
        }
        if let index = Int(arg), tabs.wrappedValue.indices.contains(index) {
            return tabs.wrappedValue[index]
        }
        return nil
    }

    /// The tab title follows the focused surface — refresh it from live
    /// widget state (VTE window title / WebKit page title) so closing or
    /// refocusing surfaces never leaves a dead surface's title behind.
    func refreshTitle(tabId: UUID) {
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }),
              let focused = tabs.wrappedValue[index].focusedSurface else { return }
        let registry = SurfaceRegistry.shared
        guard let title = registry.currentTerminalTitle(for: focused.surfaceId)
            ?? registry.currentBrowserTitle(for: focused.surfaceId) else { return }
        if tabs.wrappedValue[index].title != title {
            tabs.wrappedValue[index].title = title
        }
    }

    /// Selecting a tab clears its attention state and marks its
    /// notifications read (macOS marks-read-on-focus behavior).
    func select(_ tabId: UUID) {
        selection.wrappedValue = tabId
        SelectionHistory.shared.note(tabId)
        if let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) {
            tabs.wrappedValue[index].needsAttention = false
        }
        notifications.wrappedValue = notifications.wrappedValue.map { notification in
            var copy = notification
            if copy.tabId == tabId { copy.isRead = true }
            return copy
        }
    }

    /// `title|subtitle|body`, matching the macOS `parseNotificationPayload`.
    private func addNotification(tabId: UUID, surfaceId: UUID?, payload: String) {
        let parts = payload.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            .map(String.init)
        let title = parts.first.flatMap { $0.isEmpty ? nil : $0 } ?? "cmux"
        notifications.wrappedValue.append(TerminalNotification(
            tabId: tabId,
            surfaceId: surfaceId,
            title: title,
            subtitle: parts.count > 1 ? parts[1] : "",
            body: parts.count > 2 ? parts[2] : ""
        ))
        if let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) {
            tabs.wrappedValue[index].needsAttention = true
        }
        // Desktop delivery only for tabs the user isn't looking at,
        // approximating macOS's suppress-when-focused behavior.
        if tabId != selection.wrappedValue {
            DesktopNotifier.send(
                id: "cmux-\(tabId.uuidString)",
                title: title,
                body: [parts.count > 1 ? parts[1] : "", parts.count > 2 ? parts[2] : ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: " — ")
            )
        }
    }

    private func clearAllAttention() {
        tabs.wrappedValue = tabs.wrappedValue.map { tab in
            var copy = tab
            copy.needsAttention = false
            return copy
        }
    }
}
