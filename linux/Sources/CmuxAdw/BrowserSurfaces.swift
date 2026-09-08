import Adwaita
import CWebKit
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Whether libghostty-gtk is loaded in this process (shim builds link it
/// unconditionally). RTLD_NOLOAD returns a handle only when it is.
let ghosttyShimLoaded: Bool =
    dlopen("libghostty-gtk.so", RTLD_NOLOAD | RTLD_LAZY) != nil

extension SurfaceRegistry {
    /// Reloads a browser surface (tab.action reload) — here because only
    /// CWebKit-bound files may touch WebKit types.
    @discardableResult
    func reloadBrowser(for surfaceId: UUID) -> Bool {
        guard let webView = browsers[surfaceId] else { return false }
        webkit_web_view_reload(UnsafeMutablePointer<WebKitWebView>(webView))
        return true
    }

    /// Live page URL of a browser surface.
    func currentURL(for surfaceId: UUID) -> String? {
        guard let webView = browsers[surfaceId],
              let uri = webkit_web_view_get_uri(UnsafeMutablePointer<WebKitWebView>(webView)) else {
            return nil
        }
        return String(cString: uri)
    }

    /// The page favicon as a GdkTexture — which implements GIcon, so the
    /// (WebKit-free) tab strip can hand it straight to AdwTabPage. The
    /// reference is borrowed from WebKit; do not unref. Opaque so CVte-
    /// bound files never see WebKit/Gdk texture types.
    func currentFavicon(for surfaceId: UUID) -> OpaquePointer? {
        guard let webView = browsers[surfaceId],
              let texture = webkit_web_view_get_favicon(
                  UnsafeMutablePointer<WebKitWebView>(webView)) else {
            return nil
        }
        return texture
    }

    /// Whether the page is mid-load (the tab strip's native spinner).
    func isBrowserLoading(for surfaceId: UUID) -> Bool {
        guard let webView = browsers[surfaceId] else { return false }
        return webkit_web_view_is_loading(UnsafeMutablePointer<WebKitWebView>(webView)) != 0
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

    /// Constructs the web view, honoring a pending profile assignment.
    /// `network-session` is construct-only (like `related-view`), so a
    /// profiled pane must be born into its session — it cannot move later.
    private static func makeWebView(surfaceId: UUID) -> UnsafeMutablePointer<GtkWidget>? {
        // Before the first view exists: a scheme registered afterwards is
        // unknown to views already alive.
        BrowserURIScheme.ensureRegistered()
        let assigned = BrowserProfileAssignments.pending.removeValue(forKey: surfaceId)
        guard let profileId = assigned,
              let session = BrowserProfiles.session(for: profileId) else {
            // Default profile (or a profile whose session failed): WebKit's
            // default session, which is where pre-profile state lives.
            return webkit_web_view_new()
        }
        BrowserProfileAssignments.live[surfaceId] = profileId
        var sessionValue = GValue()
        _ = g_value_init(&sessionValue, webkit_network_session_get_type())
        g_value_set_object(&sessionValue, UnsafeMutableRawPointer(session))
        let name = strdup("network-session")
        defer {
            free(name)
            g_value_unset(&sessionValue)
        }
        var names: [UnsafePointer<CChar>?] = [UnsafePointer(name)]
        var values: [GValue] = [sessionValue]
        let created = names.withUnsafeMutableBufferPointer { namePtr in
            values.withUnsafeMutableBufferPointer { valuePtr in
                g_object_new_with_properties(
                    webkit_web_view_get_type(), 1, namePtr.baseAddress, valuePtr.baseAddress
                )
            }
        }
        // An ephemeral session is minted fresh per pane (never cached), so it
        // arrives with a construction ref we own. The web view took its own
        // ref via the construct-only `network-session` property, so drop ours
        // — the session then lives and dies with this one pane. Persistent
        // sessions are cached and intentionally kept alive, so leave them.
        if profileId == BrowserProfiles.ephemeralID {
            g_object_unref(UnsafeMutableRawPointer(session))
        }
        guard let created else { return webkit_web_view_new() }
        return UnsafeMutableRawPointer(created).assumingMemoryBound(to: GtkWidget.self)
    }

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
        } ?? Self.makeWebView(surfaceId: leaf.surfaceId)
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

        // WebAuthn client layer (PASSKEYS.md option B). No-op unless
        // CMUX_WEBAUTHN=1; must run before the first load so the
        // document-start polyfill exists for every page.
        installBrowserWebAuthn(webView)

        // Popup routing (roadmap/06 increment 5). The settings flag is the
        // load-bearing part: it defaults to FALSE, and while it is off
        // `create` never fires, so window.open silently does nothing.
        if let settings = webkit_web_view_get_settings(webView) {
            webkit_settings_set_javascript_can_open_windows_automatically(settings, 1)
        }
        // Favicons only arrive if the session's favicon database is
        // enabled — off by default in WebKitGTK. Idempotent per session;
        // covers the default session and every profile session, since
        // each view enables its own (mirror ⑤: tab favicons).
        //
        // TRAP (2026-07-24, coredump-proven): the ghostty shim exports
        // its bundled libpng (377 png_* symbols in libghostty-gtk.so),
        // and WebKit's IconDatabase decodes favicons in THIS process —
        // its png_* calls resolve into the shim's incompatible copy and
        // SEGV. Page images are safe (they decode in the web process,
        // which never loads the shim). Until the shim localizes its
        // bundled symbols (GAPS), favicons stay off in shim builds.
        if !ghosttyShimLoaded,
           let session = webkit_web_view_get_network_session(webView),
           let manager = webkit_network_session_get_website_data_manager(session) {
            webkit_website_data_manager_set_favicons_enabled(manager, 1)
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
        // Tab-strip decor (mirror ⑤): the favicon and the load spinner
        // live on the AdwTabPage; refresh it when either changes.
        for signal in ["notify::favicon", "notify::is-loading"] {
            g_signal_connect_data(
                UnsafeMutableRawPointer(widget), signal,
                unsafeBitCast(browserTabDecorChanged, to: GCallback.self),
                Unmanaged.passRetained(PopupOpenerBox(surfaceId: surfaceId)).toOpaque(),
                popupOpenerBoxDestroy, GConnectFlags(0)
            )
        }

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
        // Resolve the profile BEFORE mutating the model, so a bad name
        // fails the whole command rather than opening a default-profile
        // pane the caller believes is contained.
        var profileId: UUID?
        if let query = params["profile"] as? String, !query.isEmpty {
            do {
                let profile = try BrowserProfiles.resolve(query)
                profileId = profile.id
            } catch let error as BrowserProfiles.ProfileError {
                return v2BrowserError(id: id, code: "not_found", message: error.message)
            } catch {
                return v2BrowserError(id: id, code: "internal_error", message: "\(error)")
            }
        }
        let url = (params["url"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "about:blank"
        guard let newLeaf = split(
            tab: target.tab,
            surfaceId: target.surfaceId,
            direction: "right",
            kind: .browser(initialURL: url),
            prepare: { newSurfaceId in
                // Before the layout mutation: the view sync can run the
                // surface factory before split() even returns, and the
                // network session is construct-only.
                if let profileId {
                    BrowserProfileAssignments.pending[newSurfaceId] = profileId
                }
            }
        ) else {
            return v2BrowserError(id: id, code: "internal_error", message: "Failed to create split")
        }
        if let profileId {
            BrowserProfiles.noteUsed(profileId)
        }
        let registry = RefRegistry.shared
        var result: [String: Any] = [
            "workspace_id": target.tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: target.tab.id),
            "surface_id": newLeaf.surfaceId.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: newLeaf.surfaceId),
            "pane_id": newLeaf.paneId.uuidString,
            "pane_ref": registry.ref(kind: "pane", uuid: newLeaf.paneId),
            "created_split": true,
            "url": url
        ]
        if let profileId {
            result["profile_id"] = profileId.uuidString
        }
        return v2BrowserOk(id: id, result: result)
    }

    /// `direction: in|out|reset` — steps match the CLI's expectation;
    /// the resulting level rides the existing zoom persistence.
    func v2BrowserZoomSet(id: Any?, params: [String: Any]) -> String {
        guard let webView = browserWebView(params) else {
            return v2BrowserError(id: id, code: "not_found", message: "Browser surface not found")
        }
        let current = webkit_web_view_get_zoom_level(webView)
        let level: Double
        switch (params["direction"] as? String)?.lowercased() {
        case "in": level = min(5.0, current * 1.1)
        case "out": level = max(0.2, current / 1.1)
        case "reset": level = 1.0
        default:
            return v2BrowserError(id: id, code: "invalid_params", message: "zoom requires direction in|out|reset")
        }
        webkit_web_view_set_zoom_level(webView, level)
        SessionStore.requestSave()
        return v2BrowserOk(id: id, result: ["zoom": level])
    }

    // MARK: browser.profiles.* — wire format mirrors macOS's
    // BrowserProfileAutomation exactly, so the shared CLI behaves
    // identically on both platforms.

    private func profilePayload(_ profile: BrowserProfiles.Definition) -> [String: Any] {
        [
            "id": profile.id.uuidString,
            "name": profile.displayName,
            "slug": profile.slug,
            "built_in_default": profile.isBuiltInDefault,
            "current": profile.id == BrowserProfiles.effectiveLastUsedID,
        ]
    }

    private func v2ProfileFailure(id: Any?, _ error: Error) -> String {
        if let profileError = error as? BrowserProfiles.ProfileError {
            let code: String
            switch profileError {
            case .notFound: code = "not_found"
            case .ambiguous: code = "ambiguous"
            case .duplicateName: code = "already_exists"
            case .builtInDefault, .reserved, .inUse: code = "invalid_request"
            }
            return v2BrowserError(id: id, code: code, message: profileError.message)
        }
        return v2BrowserError(id: id, code: "internal_error", message: "\(error)")
    }

    func v2BrowserProfilesList(id: Any?) -> String {
        v2BrowserOk(id: id, result: [
            "current_profile_id": BrowserProfiles.effectiveLastUsedID.uuidString,
            "profiles": BrowserProfiles.all.map(profilePayload),
        ])
    }

    func v2BrowserProfilesCreate(id: Any?, params: [String: Any]) -> String {
        guard let name = params["name"] as? String,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return v2BrowserError(id: id, code: "invalid_request", message: "profile create requires a name")
        }
        do {
            let profile = try BrowserProfiles.create(named: name)
            return v2BrowserOk(id: id, result: ["created": true, "profile": profilePayload(profile)])
        } catch {
            return v2ProfileFailure(id: id, error)
        }
    }

    func v2BrowserProfilesRename(id: Any?, params: [String: Any]) -> String {
        guard let query = params["profile"] as? String,
              let newName = params["new_name"] as? String,
              !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return v2BrowserError(id: id, code: "invalid_request", message: "profile rename requires a profile and a new name")
        }
        do {
            let profile = try BrowserProfiles.rename(query, to: newName)
            return v2BrowserOk(id: id, result: ["renamed": true, "profile": profilePayload(profile)])
        } catch {
            return v2ProfileFailure(id: id, error)
        }
    }

    func v2BrowserProfilesClear(id: Any?, params: [String: Any]) -> String {
        guard let query = params["profile"] as? String else {
            return v2BrowserError(id: id, code: "invalid_request", message: "profile clear requires a profile")
        }
        do {
            let profile = try BrowserProfiles.clear(query, liveCount: BrowserProfileAssignments.liveCount)
            return v2BrowserOk(id: id, result: [
                "cleared": true, "count": 1, "profile": profilePayload(profile),
            ])
        } catch {
            return v2ProfileFailure(id: id, error)
        }
    }

    func v2BrowserProfilesDelete(id: Any?, params: [String: Any]) -> String {
        guard let query = params["profile"] as? String else {
            return v2BrowserError(id: id, code: "invalid_request", message: "profile delete requires a profile")
        }
        do {
            let profile = try BrowserProfiles.delete(query, liveCount: BrowserProfileAssignments.liveCount)
            return v2BrowserOk(id: id, result: ["deleted": true, "profile": profilePayload(profile)])
        } catch {
            return v2ProfileFailure(id: id, error)
        }
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

    /// browser.console.show — macOS's `showBrowserJavaScriptConsole`.
    ///
    /// macOS builds no console UI: it reveals WebKit's inspector and flips
    /// it to the Console tab through *private* selectors
    /// (`BrowserPanel.showDeveloperToolsConsole`). WebKitGTK has no public
    /// equivalent of that flip — the inspector's widget is not even a
    /// `WebKitWebView` (see `InspectorSurfaceFactory`), so no script can
    /// reach the frontend. The honest Linux contract: make the DevTools
    /// pane for the target surface exist and be focused; tab choice stays
    /// WebKit's (the frontend remembers its last tab, and Esc toggles the
    /// quick console on every tab).
    ///
    /// Unlike `browser.inspect`, calling this twice must not stack a second
    /// DevTools pane: an existing inspector for the target is focused, not
    /// duplicated.
    func v2BrowserConsoleShow(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = v2TargetSurfaceForBrowser(params) else {
            return respond(v2BrowserError(
                id: id, code: "not_found", message: "Browser surface not found"
            ))
        }
        for pane in target.tab.panes {
            for surface in pane.surfaces {
                if case .inspector(let inspected) = surface.kind, inspected == target.surfaceId {
                    _ = v2SurfaceFocus(id: nil, params: ["surface_id": surface.surfaceId.uuidString])
                    let registry = RefRegistry.shared
                    return respond(v2BrowserOk(id: id, result: [
                        "shown": true,
                        "created_split": false,
                        "surface_id": surface.surfaceId.uuidString,
                        "surface_ref": registry.ref(kind: "surface", uuid: surface.surfaceId),
                        "inspected_surface_id": target.surfaceId.uuidString,
                        "inspected_surface_ref": registry.ref(kind: "surface", uuid: target.surfaceId)
                    ]))
                }
            }
        }
        v2BrowserInspect(id: id, params: params, respond: respond)
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
