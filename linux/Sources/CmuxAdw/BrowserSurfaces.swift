import Adwaita
import CWebKit
import Foundation

extension SurfaceRegistry {
    /// Live page URL of a browser surface.
    func currentURL(for surfaceId: UUID) -> String? {
        guard let webView = browsers[surfaceId],
              let uri = webkit_web_view_get_uri(UnsafeMutablePointer<WebKitWebView>(webView)) else {
            return nil
        }
        return String(cString: uri)
    }

    /// Live page title of a browser surface.
    func currentBrowserTitle(for surfaceId: UUID) -> String? {
        guard let webView = browsers[surfaceId],
              let title = webkit_web_view_get_title(UnsafeMutablePointer<WebKitWebView>(webView)) else {
            return nil
        }
        let string = String(cString: title)
        return string.isEmpty ? nil : string
    }
}

/// Creates WebKitGTK browser surfaces for `.browser` pane leaves — the Linux
/// counterpart of the macOS `BrowserPanel`/`CmuxWebView` (WKWebView) stack.
/// Kept in its own CWebKit-bound file; the shared registry speaks
/// `OpaquePointer` so CVte-bound code never sees WebKit types.
enum BrowserSurfaceFactory {

    static func create(
        for leaf: PaneSurface,
        in tab: TerminalTab,
        storage: ViewStorage,
        onTitleChanged: @escaping (UUID, UUID, String) -> Void,
        onSurfaceFocused: @escaping (UUID, UUID) -> Void
    ) {
        // A WebDriver automation session may have pre-created this view
        // (roadmap/06 split adoption); adopt it rather than constructing
        // a second one, so the driver and cmux drive the same surface.
        let adopted = BrowserAdoption.pending.removeValue(forKey: leaf.surfaceId)
        let widgetOrNil: UnsafeMutablePointer<GtkWidget>? = adopted.map {
            UnsafeMutableRawPointer($0).assumingMemoryBound(to: GtkWidget.self)
        } ?? webkit_web_view_new()
        guard let widget = widgetOrNil else { return }
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        let webView = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: WebKitWebView.self)

        // A session restore parks the full browser state (zoom, history,
        // WebKit's own blob) here, since SurfaceKind can only carry a URL.
        // Falls back to the plain URL when there is nothing parked.
        if let restored = BrowserRestoreStore.pending.removeValue(forKey: leaf.surfaceId) {
            BrowserSessionState.restore(restored, into: webView)
        } else if case .browser(let initialURL) = leaf.kind, !initialURL.isEmpty {
            webkit_web_view_load_uri(webView, initialURL)
        }

        let tabId = tab.id
        let surfaceId = leaf.surfaceId
        storage.connectSignal(
            name: "notify::title",
            id: "browser-title-\(surfaceId.uuidString)",
            argCount: 1,
            pointer: OpaquePointer(widget)
        ) {
            if let title = webkit_web_view_get_title(webView) {
                let string = String(cString: title)
                if !string.isEmpty {
                    onTitleChanged(tabId, surfaceId, string)
                }
            }
            // The workspace title only follows the FOCUSED surface; a tab
            // label has to update whoever it belongs to.
            PaneTabs.refreshTitle(surfaceId: surfaceId)
        }
        if let controller = gtk_event_controller_focus_new() {
            gtk_widget_add_controller(widget, controller)
            storage.connectSignal(
                name: "enter",
                id: "browser-focus-\(surfaceId.uuidString)",
                pointer: controller
            ) {
                onSurfaceFocused(tabId, surfaceId)
            }
        }

        // Console/error capture v2: CSP-exempt document-start user
        // script + script message handler (roadmap/06 increment 1).
        // Installed before any load so capture starts at page load.
        installBrowserConsoleCapture(webView, surfaceId: surfaceId)

        // Popup routing (roadmap/06 increment 5). The settings flag is the
        // load-bearing part: it defaults to FALSE, and while it is off
        // `create` never fires, so window.open silently does nothing.
        if let settings = webkit_web_view_get_settings(webView) {
            webkit_settings_set_javascript_can_open_windows_automatically(settings, 1)
        }
        // Capture browser state as soon as a navigation commits (see
        // browserLoadChangedForSession) rather than waiting for the 15s
        // session timer.
        g_signal_connect_data(
            UnsafeMutableRawPointer(widget), "load-changed",
            unsafeBitCast(browserLoadChangedForSession, to: GCallback.self),
            Unmanaged.passRetained(PopupOpenerBox(surfaceId: surfaceId)).toOpaque(),
            popupOpenerBoxDestroy, GConnectFlags(0)
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(widget), "create",
            unsafeBitCast(popupCreate, to: GCallback.self),
            Unmanaged.passRetained(PopupOpenerBox(surfaceId: surfaceId)).toOpaque(),
            popupOpenerBoxDestroy, GConnectFlags(0)
        )

        // The pane's container is a box, not the bare web view, so the
        // find bar (hidden until Ctrl+Shift+F) has somewhere to live above
        // the page. registerBrowser already keeps the two pointers apart.
        let containerOrNil = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        guard let container = containerOrNil else { return }
        gtk_widget_set_hexpand(container, 1)
        gtk_widget_set_vexpand(container, 1)
        if let urlBar = BrowserURLBar.build(webView: webView, surfaceId: surfaceId) {
            gtk_box_append(UnsafeMutableRawPointer(container).assumingMemoryBound(to: GtkBox.self), urlBar)
        }
        if let findBar = BrowserFindBar.build(webView: webView, surfaceId: surfaceId) {
            gtk_box_append(UnsafeMutableRawPointer(container).assumingMemoryBound(to: GtkBox.self), findBar)
        }
        gtk_box_append(UnsafeMutableRawPointer(container).assumingMemoryBound(to: GtkBox.self), widget)

        SurfaceRegistry.shared.registerBrowser(
            OpaquePointer(webView),
            container: OpaquePointer(container),
            for: surfaceId
        )
    }
}

// MARK: - browser.* control-protocol verbs

extension ControlCommandHandler {

    func v2BrowserOpenSplit(id: Any?, params: [String: Any]) -> String {
        guard let target = v2TargetSurfaceForBrowser(params) else {
            return v2BrowserError(id: id, code: "not_found", message: "Surface not found")
        }
        let url = (params["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
        guard let newLeaf = split(
            tab: target.tab,
            surfaceId: target.surfaceId,
            direction: "right",
            kind: .browser(initialURL: url)
        ) else {
            return v2BrowserError(id: id, code: "internal_error", message: "Failed to create split")
        }
        let registry = RefRegistry.shared
        return v2BrowserOk(id: id, result: [
            "workspace_id": target.tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: target.tab.id),
            "surface_id": newLeaf.surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: newLeaf.surfaceId),
            "pane_id": newLeaf.paneId.uuidString,
            "pane_ref": registry.ref(kind: "pane", uuid: newLeaf.paneId),
            "created_split": true,
            "url": url
        ])
    }

    // `browser.navigate` / back / forward / reload live in
    // BrowserAutomation.swift: they complete asynchronously now, holding the
    // response until the new document is committed.

    func v2BrowserGetURL(id: Any?, params: [String: Any]) -> String {
        guard let webView = browserWebView(params) else {
            return v2BrowserError(id: id, code: "not_found", message: "Browser surface not found")
        }
        let url = webkit_web_view_get_uri(webView).map { String(cString: $0) } ?? ""
        return v2BrowserOk(id: id, result: ["url": url])
    }

    func v2BrowserIdentify(id: Any?, params: [String: Any]) -> String {
        guard let raw = params["surface_id"] as? String,
              let uuid = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
              let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: uuid) }),
              let webView = SurfaceRegistry.shared.browser(for: uuid)
                  .map({ UnsafeMutablePointer<WebKitWebView>($0) }) else {
            return v2BrowserError(id: id, code: "not_found", message: "Browser surface not found")
        }
        let registry = RefRegistry.shared
        return v2BrowserOk(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
            "surface_id": uuid.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: uuid),
            "type": "browser",
            "url": webkit_web_view_get_uri(webView).map { String(cString: $0) } ?? "",
            "title": webkit_web_view_get_title(webView).map { String(cString: $0) } ?? ""
        ])
    }

    func v2BrowserGetTitle(id: Any?, params: [String: Any]) -> String {
        guard let webView = browserWebView(params) else {
            return v2BrowserError(id: id, code: "not_found", message: "Browser surface not found")
        }
        let title = webkit_web_view_get_title(webView).map { String(cString: $0) } ?? ""
        return v2BrowserOk(id: id, result: ["title": title])
    }

    // MARK: helpers (CWebKit-bound)

    private func browserWebView(_ params: [String: Any]) -> UnsafeMutablePointer<WebKitWebView>? {
        guard let raw = params["surface_id"] as? String,
              let uuid = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
              let webView = SurfaceRegistry.shared.browser(for: uuid) else { return nil }
        return UnsafeMutablePointer<WebKitWebView>(webView)
    }

    /// Same defaulting as `v2TargetSurface` (kept private in the main file).
    private func v2TargetSurfaceForBrowser(_ params: [String: Any]) -> (tab: TerminalTab, surfaceId: UUID)? {
        if let raw = params["surface_id"] as? String, !raw.isEmpty {
            guard let uuid = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
                  let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: uuid) }) else {
                return nil
            }
            return (tab, uuid)
        }
        let wsId = (params["workspace_id"] as? String).flatMap {
            UUID(uuidString: $0) ?? RefRegistry.shared.resolve($0)
        } ?? selection.wrappedValue
        guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }),
              let focused = tab.focusedSurface else { return nil }
        return (tab, focused.surfaceId)
    }

    private func v2BrowserOk(id: Any?, result: [String: Any]) -> String {
        v2EncodeBrowser(["id": id ?? NSNull(), "ok": true, "result": result])
    }

    private func v2BrowserError(id: Any?, code: String, message: String) -> String {
        v2EncodeBrowser(["id": id ?? NSNull(), "ok": false, "error": ["code": code, "message": message]])
    }

    private func v2EncodeBrowser(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }
        return string.replacingOccurrences(of: "\n", with: "\\n")
    }
}

// MARK: - browser.inspect (Web Inspector pane, roadmap/06 increment 3)

extension ControlCommandHandler {

    /// Opens DevTools for a browser surface in a split beside it.
    ///
    /// Completes asynchronously: WebKit decides where the inspector goes
    /// (`attach` or `open-window`) on its own schedule, so the split can
    /// land while the embedding is still pending. Reporting OK at that
    /// point would claim a DevTools pane that is in fact empty, so the verb
    /// waits for the real outcome and returns it as `attached`.
    func v2BrowserInspect(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = v2TargetSurfaceForBrowser(params),
              let webViewPtr = SurfaceRegistry.shared.browser(for: target.surfaceId) else {
            return respond(v2BrowserError(
                id: id, code: "not_found", message: "Browser surface not found"
            ))
        }
        let webView = UnsafeMutablePointer<WebKitWebView>(webViewPtr)

        // Developer extras gate the inspector entirely; without this
        // `get_inspector()` yields an object that never shows anything.
        if let settings = webkit_web_view_get_settings(webView) {
            webkit_settings_set_enable_developer_extras(settings, 1)
        }
        guard let inspector = webkit_web_view_get_inspector(webView) else {
            return respond(v2BrowserError(
                id: id, code: "internal_error", message: "Inspector unavailable for this surface"
            ))
        }

        let direction = (params["direction"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "down"
        guard let newLeaf = split(
            tab: target.tab,
            surfaceId: target.surfaceId,
            direction: direction,
            kind: .inspector(targetSurfaceId: target.surfaceId)
        ) else {
            return respond(v2BrowserError(
                id: id, code: "internal_error", message: "Failed to create split"
            ))
        }

        // Registered BEFORE the split lands so the surface factory can run
        // it; see InspectorAdoption for why "after the call returns" is not
        // safe in an Adwaita re-render.
        let box = InspectorAttachBox(surfaceId: newLeaf.surfaceId)
        InspectorAdoption.pending[newLeaf.surfaceId] = {
            guard let container = SurfaceRegistry.shared.containers[newLeaf.surfaceId] else {
                inspectorLog("no container for surface \(newLeaf.surfaceId)")
                return
            }
            box.container = container
            g_signal_connect_data(
                UnsafeMutableRawPointer(inspector), "attach",
                unsafeBitCast(inspectorAttach, to: GCallback.self),
                Unmanaged.passRetained(box).toOpaque(),
                inspectorAttachBoxDestroy, GConnectFlags(0)
            )
            g_signal_connect_data(
                UnsafeMutableRawPointer(inspector), "open-window",
                unsafeBitCast(inspectorOpenWindow, to: GCallback.self),
                Unmanaged.passRetained(box).toOpaque(),
                inspectorAttachBoxDestroy, GConnectFlags(0)
            )
            inspectorLog("show() for surface \(newLeaf.surfaceId)")
            webkit_web_inspector_show(inspector)
            // show() alone let WebKit pick a separate window; attach()
            // explicitly requests docking and emits the `attach` signal.
            webkit_web_inspector_attach(inspector)
        }

        // If the factory already ran (re-render can beat us), run it now.
        if SurfaceRegistry.shared.containers[newLeaf.surfaceId] != nil,
           let pending = InspectorAdoption.pending.removeValue(forKey: newLeaf.surfaceId) {
            pending()
        }

        let registry = RefRegistry.shared
        let deadline = Date().addingTimeInterval(3)
        func reply() {
            guard box.attached || Date() >= deadline else {
                scheduleOnMainLoop(afterMs: 50) { reply() }
                return
            }
            respond(v2BrowserOk(id: id, result: [
                "workspace_id": target.tab.id.uuidString,
                "workspace_ref": registry.ref(kind: "workspace", uuid: target.tab.id),
                "surface_id": newLeaf.surfaceId.uuidString,
                "surface_ref": registry.ref(kind: "surface", uuid: newLeaf.surfaceId),
                "pane_id": newLeaf.paneId.uuidString,
                "pane_ref": registry.ref(kind: "pane", uuid: newLeaf.paneId),
                "inspected_surface_id": target.surfaceId.uuidString,
                "inspected_surface_ref": registry.ref(kind: "surface", uuid: target.surfaceId),
                "created_split": true,
                "attached": box.attached
            ]))
        }
        reply()
    }
}

// MARK: - browser.tab.* (per-pane browser tabs)

/// Mirrors macOS `v2BrowserTabList/New/Switch/Close`. Those verbs existed
/// there long before Linux had anywhere to put a tab; now that panes hold
/// several surfaces, they map straight onto the model: a "browser tab" is
/// a browser surface inside a pane, and switching one is selecting it.
extension ControlCommandHandler {

    func v2BrowserTabList(id: Any?, params: [String: Any]) -> String {
        let wsId = (params["workspace_id"] as? String)
            .flatMap { UUID(uuidString: $0) ?? RefRegistry.shared.resolve($0) }
            ?? selection.wrappedValue
        guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }) else {
            return v2BrowserError(id: id, code: "not_found", message: "Workspace not found")
        }
        let registry = RefRegistry.shared
        var entries: [[String: Any]] = []
        for pane in tab.panes {
            for (index, surface) in pane.surfaces.enumerated() {
                guard case .browser = surface.kind else { continue }
                entries.append([
                    "id": surface.surfaceId.uuidString,
                    "ref": registry.ref(kind: "surface", uuid: surface.surfaceId),
                    "pane_id": pane.paneId.uuidString,
                    "pane_ref": registry.ref(kind: "pane", uuid: pane.paneId),
                    // Index WITHIN the pane — that is what "tab 2" means to
                    // someone looking at a tab strip.
                    "index": index,
                    "selected": pane.selected.surfaceId == surface.surfaceId,
                    "focused": tab.focusedSurfaceId == surface.surfaceId,
                    "title": SurfaceRegistry.shared.currentBrowserTitle(for: surface.surfaceId) ?? "",
                    "url": SurfaceRegistry.shared.currentURL(for: surface.surfaceId) ?? ""
                ])
            }
        }
        return v2BrowserOk(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
            "tabs": entries
        ])
    }

    func v2BrowserTabNew(id: Any?, params: [String: Any]) -> String {
        let url = (params["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
        // Anchor resolution follows macOS: explicit pane, else explicit
        // surface, else the focused surface of the target workspace.
        let anchor: UUID? = {
            if let raw = params["pane_id"] as? String ?? params["target_pane_id"] as? String,
               let paneId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
               let tab = tabs.wrappedValue.first(where: { $0.panes.contains { $0.paneId == paneId } }),
               let pane = tab.panes.first(where: { $0.paneId == paneId }) {
                return pane.selected.surfaceId
            }
            if let raw = params["surface_id"] as? String,
               let sid = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw) {
                return sid
            }
            let wsId = (params["workspace_id"] as? String)
                .flatMap { UUID(uuidString: $0) ?? RefRegistry.shared.resolve($0) }
                ?? selection.wrappedValue
            return tabs.wrappedValue.first { $0.id == wsId }?.focusedSurface?.surfaceId
        }()
        guard let anchor else {
            return v2BrowserError(id: id, code: "not_found", message: "No pane to add a tab to")
        }
        guard let surfaceId = addBrowserTab(nextTo: anchor, url: url) else {
            return v2BrowserError(id: id, code: "internal_error", message: "Failed to create browser tab")
        }
        let registry = RefRegistry.shared
        return v2BrowserOk(id: id, result: [
            "surface_id": surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: surfaceId),
            "url": url
        ])
    }

    func v2BrowserTabSwitch(id: Any?, params: [String: Any]) -> String {
        guard let raw = params["surface_id"] as? String ?? params["id"] as? String,
              let surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
              let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: surfaceId) }) else {
            return v2BrowserError(id: id, code: "not_found", message: "Browser tab not found")
        }
        selectSurfaceTab(tabId: tab.id, surfaceId: surfaceId)
        let registry = RefRegistry.shared
        return v2BrowserOk(id: id, result: [
            "surface_id": surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: surfaceId)
        ])
    }

    func v2BrowserTabClose(id: Any?, params: [String: Any]) -> String {
        guard let raw = params["surface_id"] as? String ?? params["id"] as? String,
              let surfaceId = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
              let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: surfaceId) }) else {
            return v2BrowserError(id: id, code: "not_found", message: "Browser tab not found")
        }
        closeSurface(tabId: tab.id, surfaceId: surfaceId)
        return v2BrowserOk(id: id, result: ["closed": true, "surface_id": surfaceId.uuidString])
    }
}
