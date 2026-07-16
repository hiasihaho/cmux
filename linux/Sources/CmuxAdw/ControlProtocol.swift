import Adwaita
import CVte
import Foundation

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

    func handle(line: String) -> String {
        if line.hasPrefix("{") { return handleV2(line) }

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
            return "ERROR: Unknown command: \(verb)"
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
        tabs.wrappedValue.remove(at: index)
        if selection.wrappedValue == tab.id,
           let next = tabs.wrappedValue.indices.contains(index)
               ? tabs.wrappedValue[index]
               : tabs.wrappedValue.last {
            select(next.id)
        }
        return "OK"
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

    private func handleV2(_ jsonLine: String) -> String {
        guard let data = jsonLine.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let dict = object as? [String: Any] else {
            return v2Encode(["ok": false, "error": ["code": "parse_error", "message": "Invalid JSON"]])
        }
        let id = dict["id"]
        let method = (dict["method"] as? String) ?? ""
        let params = dict["params"] as? [String: Any] ?? [:]

        refreshKnownRefs()

        switch method {
        case "system.ping":
            return v2Ok(id: id, result: ["pong": true])
        case "system.capabilities":
            return v2Ok(id: id, result: [
                "protocol": 2,
                "platform": "linux",
                "port": "phase-1",
                "methods": [
                    "system.ping", "system.capabilities", "window.list",
                    "workspace.list", "workspace.create", "workspace.select",
                    "workspace.current", "workspace.close", "surface.list",
                    "notification.create", "notification.list", "notification.clear"
                ]
            ])
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
        case "surface.close":
            return v2SurfaceClose(id: id, params: params)
        case "pane.list":
            return v2PaneList(id: id, params: params)
        case "pane.focus":
            return v2PaneFocus(id: id, params: params)
        case "notification.create":
            return v2NotificationCreate(id: id, params: params)
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
                "pinned": false
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
        select(tab.id)
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
        tabs.wrappedValue.remove(at: index)
        if selection.wrappedValue == wsId,
           let next = tabs.wrappedValue[safe: min(index, tabs.wrappedValue.count - 1)]
               ?? tabs.wrappedValue.first {
            select(next.id)
        }
        return v2Ok(id: id, result: workspaceRefResult(wsId))
    }

    private func v2SurfaceList(id: Any?, params: [String: Any]) -> String {
        let wsId = v2WorkspaceUUID(params) ?? selection.wrappedValue
        guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        let registry = RefRegistry.shared
        let focusedId = tab.focusedSurface?.surfaceId
        let surfaces: [[String: Any]] = tab.surfaces.enumerated().map { index, leaf in
            [
                "id": leaf.surfaceId.uuidString,
                "ref": registry.ref(kind: "surface", uuid: leaf.surfaceId),
                "index": index,
                "focused": leaf.surfaceId == focusedId,
                "type": "terminal",
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
                "surface_ids": [leaf.surfaceId.uuidString],
                "surface_refs": [registry.ref(kind: "surface", uuid: leaf.surfaceId)],
                "selected_surface_id": leaf.surfaceId.uuidString,
                "selected_surface_ref": registry.ref(kind: "surface", uuid: leaf.surfaceId),
                "surface_count": 1
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

    private func v2SurfaceClose(id: Any?, params: [String: Any]) -> String {
        guard let target = v2TargetSurface(params) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == target.tab.id }) else {
            return v2Error(id: id, code: "not_found", message: "Workspace not found")
        }
        if let remaining = tabs.wrappedValue[index].layout.removing(surfaceId: target.surfaceId) {
            tabs.wrappedValue[index].layout = remaining
            if tabs.wrappedValue[index].focusedSurfaceId == target.surfaceId,
               let first = remaining.leaves.first {
                tabs.wrappedValue[index].focusedSurfaceId = first.surfaceId
            }
        } else {
            // Last surface in the workspace — close the workspace.
            tabs.wrappedValue.remove(at: index)
            if selection.wrappedValue == target.tab.id,
               let next = tabs.wrappedValue[safe: min(index, tabs.wrappedValue.count - 1)]
                   ?? tabs.wrappedValue.first {
                select(next.id)
            }
        }
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "surface_id": target.surfaceId.uuidString
        ])
    }

    /// Splits the pane holding `surfaceId`; the new shell inherits the
    /// split-off shell's current directory (OSC 7) when known. Returns the
    /// new leaf, or nil for an invalid direction/surface.
    @discardableResult
    func split(tab: TerminalTab, surfaceId: UUID, direction: String) -> PaneLeaf? {
        guard let index = tabs.wrappedValue.firstIndex(where: { $0.id == tab.id }) else { return nil }
        let cwd = SurfaceRegistry.shared.currentDirectory(for: surfaceId)
            ?? tab.workingDirectory
        let newLeaf = PaneLeaf(workingDirectory: cwd)
        guard let layout = tabs.wrappedValue[index].layout.splitting(
            surfaceId: surfaceId,
            direction: direction,
            newLeaf: newLeaf
        ) else { return nil }
        tabs.wrappedValue[index].layout = layout
        tabs.wrappedValue[index].focusedSurfaceId = newLeaf.surfaceId
        return newLeaf
    }

    private func v2SurfaceSendText(id: Any?, params: [String: Any]) -> String {
        guard let text = params["text"] as? String else {
            return v2Error(id: id, code: "invalid_params", message: "Missing text")
        }
        guard let target = v2TargetSurface(params),
              let terminal = SurfaceRegistry.shared.terminal(for: target.surfaceId) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        feed(terminal, text)
        return v2Ok(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "surface_id": target.surfaceId.uuidString
        ])
    }

    private func v2SurfaceSendKey(id: Any?, params: [String: Any]) -> String {
        guard let key = params["key"] as? String, !key.isEmpty else {
            return v2Error(id: id, code: "invalid_params", message: "Missing key")
        }
        guard let target = v2TargetSurface(params),
              let terminal = SurfaceRegistry.shared.terminal(for: target.surfaceId) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        guard let bytes = Self.namedKeyBytes(key) else {
            return v2Error(id: id, code: "invalid_params", message: "Unknown key: \(key)")
        }
        feed(terminal, bytes)
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
        guard let target = v2TargetSurface(params),
              let terminal = SurfaceRegistry.shared.terminal(for: target.surfaceId) else {
            return v2Error(id: id, code: "not_found", message: "Surface not found")
        }
        var text = ""
        if let raw = vte_terminal_get_text_format(terminal, VTE_FORMAT_TEXT) {
            text = String(cString: raw)
            g_free(raw)
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

    /// Accepts a UUID string or a `workspace:<n>` handle ref.
    private func v2WorkspaceUUID(_ params: [String: Any]) -> UUID? {
        guard let raw = params["workspace_id"] as? String,
              !raw.isEmpty else { return nil }
        if let uuid = UUID(uuidString: raw) { return uuid }
        return RefRegistry.shared.resolve(raw)
    }

    // MARK: v2 envelope helpers

    private func v2Ok(id: Any?, result: [String: Any]) -> String {
        v2Encode(["id": id ?? NSNull(), "ok": true, "result": result])
    }

    private func v2Error(id: Any?, code: String, message: String) -> String {
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

    /// Selecting a tab clears its attention state and marks its
    /// notifications read (macOS marks-read-on-focus behavior).
    func select(_ tabId: UUID) {
        selection.wrappedValue = tabId
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
