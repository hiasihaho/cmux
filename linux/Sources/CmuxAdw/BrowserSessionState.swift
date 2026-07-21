import CWebKit
import Foundation

/// Capture and restore of a browser surface's persisted state.
///
/// Two representations, deliberately layered:
///
/// - **Portable** (`url`, `zoom`, `backURLs`, `forwardURLs`) — the baseline,
///   mirroring what macOS cmux stores (`SessionBrowserPanelSnapshot`).
///   Plain strings: inspectable in the JSON, diffable, and stable across
///   WebKit upgrades.
/// - **Rich** (`sessionState`) — WebKitGTK's own serialized session blob,
///   which restores the real back/forward list rather than a re-navigation.
///   macOS has no equivalent in use (it deliberately does not persist
///   `WKWebView.interactionState`), so this is Linux-only extra.
///
/// The layering rule that makes the blob safe to ship: **it is never
/// load-bearing.** It is written when available and tried first on restore,
/// but a missing, truncated, or version-rejected blob costs nothing — the
/// portable fields still restore the surface. That is what lets us adopt an
/// opaque format whose compatibility across WebKit releases we do not
/// control, and drop it again without a migration.
enum BrowserSessionState {

    // MARK: capture

    /// Last URL each surface was seen at. A save is triggered *by* the model
    /// change that adopts a popup, and at that instant WebKit has not yet
    /// committed a URI to the new view — so a naive capture writes url="" and
    /// the tab comes back blank. Remembering the last non-empty value makes a
    /// save that races surface creation harmless.
    private static var lastKnownURL: [UUID: String] = [:]

    static func setLastKnownURL(_ url: String, for surfaceId: UUID) {
        lastKnownURL[surfaceId] = url
    }

    static func capture(surfaceId: UUID, fallbackURL: String) -> SessionStore.BrowserSnapshot? {
        guard let raw = SurfaceRegistry.shared.browser(for: surfaceId) else {
            let url = fallbackURL.isEmpty ? (lastKnownURL[surfaceId] ?? "") : fallbackURL
            return url.isEmpty ? nil : SessionStore.BrowserSnapshot(url: url)
        }
        let webView = UnsafeMutablePointer<WebKitWebView>(raw)
        let live = webkit_web_view_get_uri(webView).map { String(cString: $0) } ?? ""
        let url = !live.isEmpty ? live
            : (lastKnownURL[surfaceId] ?? (fallbackURL.isEmpty ? "" : fallbackURL))
        if !url.isEmpty { lastKnownURL[surfaceId] = url }
        var snapshot = SessionStore.BrowserSnapshot(url: url)

        let zoom = webkit_web_view_get_zoom_level(webView)
        if abs(zoom - 1.0) > 0.001 { snapshot.zoom = zoom }

        if let list = webkit_web_view_get_back_forward_list(webView) {
            snapshot.backURLs = historyURLs(webkit_back_forward_list_get_back_list(list))
            snapshot.forwardURLs = historyURLs(webkit_back_forward_list_get_forward_list(list))
        }
        snapshot.sessionState = serializedSessionState(webView)
        return snapshot
    }

    private static func historyURLs(_ list: UnsafeMutablePointer<GList>?) -> [String]? {
        var urls: [String] = []
        var node = list
        while let current = node {
            if let item = current.pointee.data,
               let uri = webkit_back_forward_list_item_get_uri(OpaquePointer(item)) {
                urls.append(String(cString: uri))
            }
            node = current.pointee.next
        }
        g_list_free(list)
        return urls.isEmpty ? nil : urls
    }

    /// Best-effort: any failure here just means the portable fields carry
    /// the surface instead.
    private static func serializedSessionState(
        _ webView: UnsafeMutablePointer<WebKitWebView>
    ) -> String? {
        guard let state = webkit_web_view_get_session_state(webView) else { return nil }
        defer { webkit_web_view_session_state_unref(state) }
        guard let bytes = webkit_web_view_session_state_serialize(state) else { return nil }
        defer { g_bytes_unref(bytes) }
        var size: gsize = 0
        guard let pointer = g_bytes_get_data(bytes, &size), size > 0 else { return nil }
        // Cap it: this rides in the session file, which is rewritten every
        // 15s. A pathological history should not turn saves into IO churn.
        guard size <= 512 * 1024 else { return nil }
        return Data(bytes: pointer, count: Int(size)).base64EncodedString()
    }

    // MARK: restore (pluggable chain)

    /// Restore strategies, richest first. Each reports whether it handled
    /// the surface; the first success wins and the rest are skipped.
    /// Adding a strategy later is one function and one array entry.
    private static let strategies: [(String, (SessionStore.BrowserSnapshot, UnsafeMutablePointer<WebKitWebView>) -> Bool)] = [
        ("session-state", applySessionState),
        ("url", applyURL)
    ]

    static func restore(_ snapshot: SessionStore.BrowserSnapshot, into webView: UnsafeMutablePointer<WebKitWebView>) {
        if let zoom = snapshot.zoom, zoom > 0 {
            webkit_web_view_set_zoom_level(webView, zoom)
        }
        for (_, strategy) in strategies where strategy(snapshot, webView) {
            return
        }
    }

    /// Richest: hands WebKit back its own serialized history. Restoring the
    /// state alone does not navigate, so the current entry is loaded after.
    private static func applySessionState(
        _ snapshot: SessionStore.BrowserSnapshot,
        _ webView: UnsafeMutablePointer<WebKitWebView>
    ) -> Bool {
        guard let encoded = snapshot.sessionState,
              let data = Data(base64Encoded: encoded), !data.isEmpty else { return false }
        let restored: Bool = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let bytes = g_bytes_new(base, gsize(data.count)) else { return false }
            defer { g_bytes_unref(bytes) }
            // Returns NULL for a blob this WebKit does not understand —
            // exactly the case the portable fallback exists for.
            guard let state = webkit_web_view_session_state_new(bytes) else { return false }
            defer { webkit_web_view_session_state_unref(state) }
            webkit_web_view_restore_session_state(webView, state)
            return true
        }
        guard restored else { return false }
        // The restored list has no loaded document yet, so the current entry
        // still has to be navigated to — but NOT with load_uri, which pushes
        // a *new* entry on top of the list we just restored. The duplicate
        // makes "back" land on the page you are already looking at, which
        // looks exactly like history restore not working at all.
        // go_to_back_forward_list_item navigates within the restored list.
        if let list = webkit_web_view_get_back_forward_list(webView),
           let item = webkit_back_forward_list_get_current_item(list) {
            webkit_web_view_go_to_back_forward_list_item(webView, item)
            return true
        }
        // No usable list (blob restored nothing): fall through to the
        // portable URL rather than claiming success.
        guard !snapshot.url.isEmpty else { return false }
        webkit_web_view_load_uri(webView, snapshot.url)
        return true
    }

    /// Always works, as long as there is a URL: the macOS-equivalent path.
    private static func applyURL(
        _ snapshot: SessionStore.BrowserSnapshot,
        _ webView: UnsafeMutablePointer<WebKitWebView>
    ) -> Bool {
        guard !snapshot.url.isEmpty else { return false }
        webkit_web_view_load_uri(webView, snapshot.url)
        return true
    }
}

/// Browser state parked by a session restore until the surface factory
/// builds the web view — the same shape as `BrowserAdoption` and
/// `InspectorAdoption`, for the same reason: the factory runs on the
/// model's schedule, not ours.
enum BrowserRestoreStore {
    static var pending: [UUID: SessionStore.BrowserSnapshot] = [:]
}

/// Records a browser surface's URL as soon as WebKit commits it, and asks
/// for a (debounced) session save. Without this, browser state only
/// reached disk on the 15s timer, because a navigation is not a model
/// change — so quitting seconds after navigating persisted the old URL.
let browserLoadChangedForSession: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Void = { viewPtr, loadEvent, userData in
    guard let viewPtr, let userData else { return }
    // Only once the load has committed: earlier events still report the
    // previous document's URI, which is the very staleness being fixed.
    guard loadEvent == WEBKIT_LOAD_COMMITTED.rawValue
            || loadEvent == WEBKIT_LOAD_FINISHED.rawValue else { return }
    let box = Unmanaged<PopupOpenerBox>.fromOpaque(userData).takeUnretainedValue()
    let webView = UnsafeMutableRawPointer(viewPtr).assumingMemoryBound(to: WebKitWebView.self)
    if let uri = webkit_web_view_get_uri(webView) {
        let url = String(cString: uri)
        if !url.isEmpty {
            BrowserSessionState.noteURL(url, for: box.surfaceId)
            BrowserURLBar.update(surfaceId: box.surfaceId, url: url)
        }
    }
    SessionStore.requestSave()
}

extension BrowserSessionState {
    /// Exposed for the load-changed handler; keeps the cache private.
    static func noteURL(_ url: String, for surfaceId: UUID) {
        setLastKnownURL(url, for: surfaceId)
    }
}
