import Adwaita
import CWebKit
import Foundation

/// Find-in-page for browser panes — the browser half of Ctrl+Shift+F,
/// which until now only worked in terminal panes (Ghostty's own overlay).
///
/// Built on `WebKitFindController`. Probed first
/// (`linux/tests/find-probe.c`), which surfaced the one trap:
///
/// - `search()` reports the **total** match count through `found-text`.
/// - `search_next()`/`search_previous()` also emit `found-text`, but with
///   the count argument set to **1**, not the total. Trusting that
///   argument after the first search would make the counter read "1 of 1"
///   on every step, so the total is kept from the initial search and the
///   current index is tracked here.
/// - `failed-to-find-text` is the no-match signal; `search_finish()`
///   clears the highlight.
enum BrowserFindRegistry {
    static var states: [UUID: BrowserFindState] = [:]

    static func show(surfaceId: UUID) {
        guard let state = states[surfaceId] else { return }
        gtk_revealer_set_reveal_child(state.revealer, 1)
        gtk_widget_grab_focus(state.entry)
    }

    static func hide(surfaceId: UUID) {
        guard let state = states[surfaceId] else { return }
        gtk_revealer_set_reveal_child(state.revealer, 0)
        webkit_find_controller_search_finish(state.controller)
        // Return focus to the page, or the pane keeps eating keystrokes.
        gtk_widget_grab_focus(
            UnsafeMutableRawPointer(state.webView).assumingMemoryBound(to: GtkWidget.self)
        )
    }

    static func isVisible(surfaceId: UUID) -> Bool {
        guard let state = states[surfaceId] else { return false }
        return gtk_revealer_get_reveal_child(state.revealer) != 0
    }

    static func forget(_ surfaceId: UUID) {
        states.removeValue(forKey: surfaceId)
    }
}

final class BrowserFindState {
    let surfaceId: UUID
    let webView: UnsafeMutablePointer<WebKitWebView>
    let controller: OpaquePointer
    let revealer: OpaquePointer
    let entry: UnsafeMutablePointer<GtkWidget>
    let label: OpaquePointer
    /// Total from the initial `search()`; `found-text` stops reporting it
    /// once you start stepping (see the type comment).
    var total = 0
    var current = 0
    var query = ""
    var caseSensitive = false
    /// True between issuing a search and the controller answering. Without
    /// it a caller polling on `total` reads the PREVIOUS query's count and
    /// returns before the new result lands — "no matches" then reports the
    /// old "1 of 3".
    var awaitingResult = false

    init(
        surfaceId: UUID,
        webView: UnsafeMutablePointer<WebKitWebView>,
        controller: OpaquePointer,
        revealer: OpaquePointer,
        entry: UnsafeMutablePointer<GtkWidget>,
        label: OpaquePointer
    ) {
        self.surfaceId = surfaceId
        self.webView = webView
        self.controller = controller
        self.revealer = revealer
        self.entry = entry
        self.label = label
    }

    var options: UInt32 {
        var value = WEBKIT_FIND_OPTIONS_WRAP_AROUND.rawValue
        if !caseSensitive { value |= WEBKIT_FIND_OPTIONS_CASE_INSENSITIVE.rawValue }
        return value
    }

    func updateLabel() {
        let text: String
        if query.isEmpty {
            text = ""
        } else if total == 0 {
            text = "No results"
        } else {
            text = "\(current) of \(total)"
        }
        gtk_label_set_text(label, text)
    }

    func search(_ newQuery: String) {
        query = newQuery
        guard !newQuery.isEmpty else {
            total = 0
            current = 0
            webkit_find_controller_search_finish(controller)
            updateLabel()
            return
        }
        // Reset before issuing: these are the previous query's numbers.
        total = 0
        current = 1
        awaitingResult = true
        webkit_find_controller_search(controller, newQuery, options, 1000)
    }

    func step(forward: Bool) {
        guard !query.isEmpty, total > 0 else { return }
        if forward {
            current = current >= total ? 1 : current + 1
            webkit_find_controller_search_next(controller)
        } else {
            current = current <= 1 ? total : current - 1
            webkit_find_controller_search_previous(controller)
        }
        updateLabel()
    }
}

// MARK: - C callbacks (file scope: they may not capture context)

private func findState(_ userData: UnsafeMutableRawPointer?) -> BrowserFindState? {
    guard let userData else { return nil }
    return Unmanaged<BrowserFindState>.fromOpaque(userData).takeUnretainedValue()
}

let browserFindStateDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<BrowserFindState>.fromOpaque(data).release()
}

/// Entry text changed — run a fresh search.
let browserFindChanged: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { entryPtr, userData in
    guard let state = findState(userData), let entryPtr else { return }
    let raw = gtk_editable_get_text(OpaquePointer(entryPtr))
    state.search(raw.map { String(cString: $0) } ?? "")
}

/// Enter in the entry — next match.
let browserFindActivate: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, userData in
    findState(userData)?.step(forward: true)
}

let browserFindNext: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, userData in
    findState(userData)?.step(forward: true)
}

let browserFindPrevious: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, userData in
    findState(userData)?.step(forward: false)
}

let browserFindClose: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, userData in
    guard let state = findState(userData) else { return }
    BrowserFindRegistry.hide(surfaceId: state.surfaceId)
}

/// Escape closes the bar (`stop-search` is GtkSearchEntry's own signal).
let browserFindStop: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, userData in
    guard let state = findState(userData) else { return }
    BrowserFindRegistry.hide(surfaceId: state.surfaceId)
}

/// `found-text` carries the TOTAL only for the initial search; after a
/// step it is 1. See the type comment — this is why `total` is only taken
/// when we are on the first match.
let browserFindFound: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Void = { _, count, userData in
    guard let state = findState(userData) else { return }
    if state.current <= 1, count > 1 || state.total == 0 {
        state.total = Int(count)
    }
    state.awaitingResult = false
    state.updateLabel()
}

let browserFindFailed: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, userData in
    guard let state = findState(userData) else { return }
    state.total = 0
    state.current = 0
    state.awaitingResult = false
    state.updateLabel()
}

let browserFindCounted: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Void = { _, count, userData in
    guard let state = findState(userData) else { return }
    state.total = Int(count)
    state.updateLabel()
}

// MARK: - construction

/// GTK's Swift import wants exact widget types; these keep the call sites
/// readable instead of repeating assumingMemoryBound everywhere.
private func asBox(_ w: UnsafeMutablePointer<GtkWidget>) -> UnsafeMutablePointer<GtkBox> {
    UnsafeMutableRawPointer(w).assumingMemoryBound(to: GtkBox.self)
}


enum BrowserFindBar {

    /// Builds the find bar and returns the widget to place above the web
    /// view. The browser pane's container therefore becomes a box rather
    /// than the bare web view.
    static func build(
        webView: UnsafeMutablePointer<WebKitWebView>,
        surfaceId: UUID
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let controller = webkit_web_view_get_find_controller(webView),
              let revealer = gtk_revealer_new(),
              let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6),
              let entry = gtk_search_entry_new(),
              let label = gtk_label_new(""),
              let prev = gtk_button_new_from_icon_name("go-up-symbolic"),
              let next = gtk_button_new_from_icon_name("go-down-symbolic"),
              let close = gtk_button_new_from_icon_name("window-close-symbolic")
        else { return nil }

        gtk_widget_set_hexpand(entry, 1)
        gtk_widget_set_margin_top(row, 6)
        gtk_widget_set_margin_bottom(row, 6)
        gtk_widget_set_margin_start(row, 6)
        gtk_widget_set_margin_end(row, 6)
        gtk_box_append(asBox(row), entry)
        gtk_box_append(asBox(row), label)
        gtk_box_append(asBox(row), prev)
        gtk_box_append(asBox(row), next)
        gtk_box_append(asBox(row), close)
        gtk_revealer_set_child(OpaquePointer(revealer), row)
        gtk_revealer_set_reveal_child(OpaquePointer(revealer), 0)

        let state = BrowserFindState(
            surfaceId: surfaceId,
            webView: webView,
            controller: controller,
            revealer: OpaquePointer(revealer),
            entry: entry,
            label: OpaquePointer(label)
        )
        BrowserFindRegistry.states[surfaceId] = state

        // Each connection takes its own retain so a surface teardown that
        // drops the registry entry cannot leave a signal pointing at freed
        // memory.
        func connect(
            _ instance: UnsafeMutableRawPointer,
            _ signal: String,
            _ callback: GCallback?
        ) {
            g_signal_connect_data(
                instance, signal, callback,
                Unmanaged.passRetained(state).toOpaque(),
                browserFindStateDestroy, GConnectFlags(0)
            )
        }

        connect(UnsafeMutableRawPointer(entry), "search-changed",
                unsafeBitCast(browserFindChanged, to: GCallback.self))
        connect(UnsafeMutableRawPointer(entry), "activate",
                unsafeBitCast(browserFindActivate, to: GCallback.self))
        connect(UnsafeMutableRawPointer(entry), "stop-search",
                unsafeBitCast(browserFindStop, to: GCallback.self))
        connect(UnsafeMutableRawPointer(prev), "clicked",
                unsafeBitCast(browserFindPrevious, to: GCallback.self))
        connect(UnsafeMutableRawPointer(next), "clicked",
                unsafeBitCast(browserFindNext, to: GCallback.self))
        connect(UnsafeMutableRawPointer(close), "clicked",
                unsafeBitCast(browserFindClose, to: GCallback.self))
        connect(UnsafeMutableRawPointer(controller), "found-text",
                unsafeBitCast(browserFindFound, to: GCallback.self))
        connect(UnsafeMutableRawPointer(controller), "failed-to-find-text",
                unsafeBitCast(browserFindFailed, to: GCallback.self))
        connect(UnsafeMutableRawPointer(controller), "counted-matches",
                unsafeBitCast(browserFindCounted, to: GCallback.self))

        return revealer
    }
}

// MARK: - browser.find_in_page

extension ControlCommandHandler {

    /// Drives the same find controller the Ctrl+Shift+F bar uses, so an
    /// agent and the human see identical highlighting — and so the feature
    /// is testable without a screenshot.
    ///
    /// Async because `found-text` / `failed-to-find-text` arrive after the
    /// call returns; answering immediately would report the *previous*
    /// query's counts.
    func v2BrowserFindInPage(
        id: Any?, params: [String: Any], respond: @escaping (String) -> Void
    ) {
        guard let raw = params["surface_id"] as? String,
              let uuid = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
              let state = BrowserFindRegistry.states[uuid] else {
            return respond(bfError(id: id, code: "not_found", message: "Browser surface not found"))
        }

        let action = (params["action"] as? String)?.lowercased() ?? "search"
        switch action {
        case "clear":
            state.search("")
            BrowserFindRegistry.hide(surfaceId: uuid)
            return respond(bfOk(id: id, result: ["query": "", "total": 0, "current": 0]))
        case "next", "previous":
            state.step(forward: action == "next")
        default:
            guard let query = params["query"] as? String, !query.isEmpty else {
                return respond(bfError(id: id, code: "invalid_params", message: "Missing query"))
            }
            state.caseSensitive = (params["case_sensitive"] as? Bool)
                ?? (params["case_sensitive"] as? NSNumber)?.boolValue ?? false
            // Reveal it: an agent searching and a human seeing where the
            // matches are should not be different features.
            BrowserFindRegistry.show(surfaceId: uuid)
            state.search(query)
        }

        // Give the controller's signals a moment to land before reporting.
        let deadline = Date().addingTimeInterval(2)
        var settled = false
        func reply() {
            if !settled, state.awaitingResult, Date() < deadline {
                scheduleOnMainLoop(afterMs: 50) { reply() }
                return
            }
            settled = true
            respond(self.bfOk(id: id, result: [
                "query": state.query,
                "total": state.total,
                "current": state.total == 0 ? 0 : state.current
            ]))
        }
        reply()
    }

    fileprivate func bfOk(id: Any?, result: [String: Any]) -> String {
        bfEncode(["id": id ?? NSNull(), "ok": true, "result": result])
    }

    fileprivate func bfError(id: Any?, code: String, message: String) -> String {
        bfEncode(["id": id ?? NSNull(), "ok": false, "error": ["code": code, "message": message]])
    }

    fileprivate func bfEncode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }
        return string.replacingOccurrences(of: "\n", with: "\\n")
    }
}
