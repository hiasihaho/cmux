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
        for leaf: PaneLeaf,
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

        if case .browser(let initialURL) = leaf.kind, !initialURL.isEmpty {
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

        SurfaceRegistry.shared.registerBrowser(
            OpaquePointer(webView),
            container: OpaquePointer(widget),
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

    func v2BrowserHistory(id: Any?, params: [String: Any], action: String) -> String {
        guard let webView = browserWebView(params) else {
            return v2BrowserError(id: id, code: "not_found", message: "Browser surface not found")
        }
        switch action {
        case "back":
            webkit_web_view_go_back(webView)
        case "forward":
            webkit_web_view_go_forward(webView)
        default:
            webkit_web_view_reload(webView)
        }
        return v2BrowserOk(id: id, result: ["action": action])
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
