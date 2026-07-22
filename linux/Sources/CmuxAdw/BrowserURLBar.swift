import CWebKit
import Foundation

/// The address bar in a browser pane.
///
/// Until now a browser pane could only be pointed somewhere by `cmux
/// browser goto` or by following a link — a human could not type a URL
/// into it at all, which macOS panes have always allowed.
///
/// Typed text is resolved with the *same* heuristic as macOS
/// (`resolveBrowserNavigableURL`), deliberately rather than approximately,
/// so the two behave alike on the awkward cases: `localhost:3000` is
/// checked before generic URL parsing (otherwise "localhost" parses as a
/// *scheme*), anything with a space is a search rather than a URL, and a
/// bare `example.com` is promoted to https. Non-URL text falls through to
/// a search engine, as it does there.
enum BrowserURLBar {

    static var states: [UUID: BrowserURLBarState] = [:]

    /// macOS's rule set, ported. Returns nil when the input is not a URL,
    /// which is the signal to search instead.
    static func resolveNavigable(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }

        // Before generic parsing: URL("localhost:3777") reads "localhost"
        // as the scheme, which is never what the user meant.
        let lower = trimmed.lowercased()
        if lower.hasPrefix("localhost") || lower.hasPrefix("127.0.0.1") || lower.hasPrefix("[::1]") {
            return "http://\(trimmed)"
        }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() {
            if scheme == "http" || scheme == "https" { return trimmed }
            if scheme == "file", trimmed.hasPrefix("file:///") { return trimmed }
            // A scheme we do not navigate (javascript:, data:, …).
            return nil
        }
        if trimmed.contains(":") || trimmed.contains("/") || trimmed.contains(".") {
            return "https://\(trimmed)"
        }
        return nil
    }

    /// Search URL for text that is not a URL — template from the settings
    /// file (or CMUX_SEARCH_URL), resolved per use so a change applies to
    /// the next search immediately.
    static func searchURL(for query: String) -> String? {
        guard let escaped = query.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) else { return nil }
        return LinuxSettings.searchURL.replacingOccurrences(of: "%s", with: escaped)
    }

    /// What Enter in the bar should load: a URL if it looks like one, a
    /// search otherwise.
    static func destination(for input: String) -> String? {
        resolveNavigable(input) ?? searchURL(for: input)
    }

    /// Reflects a navigation back into the bar. Skipped while the entry has
    /// focus so a page load cannot overwrite what someone is typing.
    static func update(surfaceId: UUID, url: String) {
        guard let state = states[surfaceId] else { return }
        // Never overwrite what someone is mid-way through typing.
        guard gtk_widget_has_focus(state.entry) == 0 else { return }
        gtk_editable_set_text(OpaquePointer(state.entry), url)
    }

    static func focus(surfaceId: UUID) {
        guard let state = states[surfaceId] else { return }
        gtk_widget_grab_focus(state.entry)
        gtk_editable_select_region(OpaquePointer(state.entry), 0, -1)
    }

    static func forget(_ surfaceId: UUID) {
        states.removeValue(forKey: surfaceId)
    }

    /// Builds the bar for a browser surface; the caller puts it above the
    /// web view.
    static func build(
        webView: UnsafeMutablePointer<WebKitWebView>,
        surfaceId: UUID
    ) -> UnsafeMutablePointer<GtkWidget>? {
        guard let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6),
              let entry = gtk_entry_new() else { return nil }
        gtk_widget_set_hexpand(entry, 1)
        gtk_entry_set_placeholder_text(
            UnsafeMutableRawPointer(entry).assumingMemoryBound(to: GtkEntry.self),
            "Enter address or search")
        gtk_widget_set_margin_top(row, 4)
        gtk_widget_set_margin_bottom(row, 4)
        gtk_widget_set_margin_start(row, 6)
        gtk_widget_set_margin_end(row, 6)
        gtk_box_append(
            UnsafeMutableRawPointer(row).assumingMemoryBound(to: GtkBox.self),
            entry
        )

        let state = BrowserURLBarState(surfaceId: surfaceId, webView: webView, entry: entry)
        states[surfaceId] = state
        g_signal_connect_data(
            UnsafeMutableRawPointer(entry), "activate",
            unsafeBitCast(browserURLBarActivate, to: GCallback.self),
            Unmanaged.passRetained(state).toOpaque(),
            browserURLBarStateDestroy, GConnectFlags(0)
        )
        return row
    }
}

final class BrowserURLBarState {
    let surfaceId: UUID
    let webView: UnsafeMutablePointer<WebKitWebView>
    let entry: UnsafeMutablePointer<GtkWidget>
    init(surfaceId: UUID, webView: UnsafeMutablePointer<WebKitWebView>, entry: UnsafeMutablePointer<GtkWidget>) {
        self.surfaceId = surfaceId
        self.webView = webView
        self.entry = entry
    }
}

let browserURLBarStateDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<BrowserURLBarState>.fromOpaque(data).release()
}

/// Enter in the address bar.
let browserURLBarActivate: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { entryPtr, userData in
    guard let entryPtr, let userData else { return }
    let state = Unmanaged<BrowserURLBarState>.fromOpaque(userData).takeUnretainedValue()
    guard let raw = gtk_editable_get_text(OpaquePointer(entryPtr)) else { return }
    let typed = String(cString: raw)
    guard let destination = BrowserURLBar.destination(for: typed) else { return }
    webkit_web_view_load_uri(state.webView, destination)
    // Hand focus back to the page, or the next keystroke goes to the bar.
    gtk_widget_grab_focus(
        UnsafeMutableRawPointer(state.webView).assumingMemoryBound(to: GtkWidget.self)
    )
}
