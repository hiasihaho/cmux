import CWebKit
import Foundation

/// E1: a page is never the authority on where a pane goes.
///
/// THE GAP (measured, browser-scheme-smoke 2026-09-06, ruled closed by
/// hias 2026-09-08): a remote page executing `window.location =
/// "cmux://about"` moved the pane onto app-owned state, and an iframe
/// did the same to a subframe. Reading stayed blocked — the scheme is
/// `as_no_access` and not cors-enabled — so this was a DISPLAY
/// capability, not a read. But a remote page steering the pane onto the
/// human's own state is a capability question, and the same constitution
/// that keeps export off the page bridge answers it: the page decides
/// nothing.
///
/// WHY A TOKEN AND NOT AN ORIGIN CHECK: WebKitGTK's
/// `WebKitNavigationAction` exposes navigation type, user gesture,
/// mouse button, modifiers and redirect flag — and no initiator origin.
/// There is nothing to compare against. So "cmux initiated this" is not
/// read off the navigation; it is ESTABLISHED by cmux, by arming a
/// one-shot token for the exact URI immediately before asking WebKit to
/// go there. Every cmux-initiated navigation therefore goes through this
/// type. That is the point of the seam, not an inconvenience: the set of
/// places cmux can move a pane to `cmux://` is now enumerable and small.
///
/// WHAT IT DOES NOT DO: a navigation to any other scheme is not our
/// business — the handler returns false and the existing behavior of
/// every browser pane is untouched. It refuses one class; it removes no
/// capability. `browser-scheme-smoke` asserts both halves, because a
/// policy that closed the gap by making `cmux://` unreachable for
/// everyone would satisfy the refusal legs and destroy the seam.
enum BrowserNavigationPolicy {

    /// One armed URI per web view, consumed by the next decision on it.
    /// Keyed by the view pointer; dropped when the widget dies.
    private static var armed: [UInt: String] = [:]

    /// Views already carrying the handler. A popup gets it at creation
    /// (see `popupCreate`) and again when the pane adopts it, and a
    /// double connection would be merely wasteful rather than wrong —
    /// but the set makes the intent explicit and keeps one view to one
    /// handler.
    private static var installed: Set<UInt> = []

    /// Connects the policy to a web view. MUST run before the view's
    /// first load: a navigation decided before the handler exists is a
    /// navigation nobody judged, and it leaves an armed token behind for
    /// a later page-initiated navigation to spend.
    static func install(_ widget: UnsafeMutableRawPointer) {
        let k = UInt(bitPattern: UnsafeRawPointer(widget))
        guard !installed.contains(k) else { return }
        installed.insert(k)
        g_signal_connect_data(
            widget, "decide-policy",
            unsafeBitCast(browserDecidePolicy, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        g_signal_connect_data(
            widget, "destroy",
            unsafeBitCast(browserNavPolicyForget, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
    }

    /// True when this URI may only be reached because cmux asked for it.
    /// `popupCreate` needs the question before a view exists to ask it of.
    static func isAppOwned(_ uri: String) -> Bool { isCmuxScheme(uri) }

    // MARK: - The cmux-initiated navigation seam

    /// `load_uri`, with cmux vouching for the destination.
    static func load(_ webView: UnsafeMutablePointer<WebKitWebView>, _ uri: String) {
        arm(webView, uri)
        webkit_web_view_load_uri(webView, uri)
    }

    /// Back/forward are cmux-initiated too when they come from a verb or
    /// the URL bar, and their destination is knowable before the jump —
    /// it is the neighbouring item in the list.
    static func goBack(_ webView: UnsafeMutablePointer<WebKitWebView>) {
        if let list = webkit_web_view_get_back_forward_list(webView),
           let item = webkit_back_forward_list_get_back_item(list) {
            armItem(webView, item)
        }
        webkit_web_view_go_back(webView)
    }

    static func goForward(_ webView: UnsafeMutablePointer<WebKitWebView>) {
        if let list = webkit_web_view_get_back_forward_list(webView),
           let item = webkit_back_forward_list_get_forward_item(list) {
            armItem(webView, item)
        }
        webkit_web_view_go_forward(webView)
    }

    /// Session restore navigates INTO the restored list rather than
    /// pushing a new entry (BrowserSessionState). Without arming here, a
    /// pane restored onto `cmux://` would come back refused — the policy
    /// would have narrowed a seam the running environment depends on.
    static func goToItem(_ webView: UnsafeMutablePointer<WebKitWebView>,
                         _ item: OpaquePointer) {
        armItem(webView, item)
        webkit_web_view_go_to_back_forward_list_item(webView, item)
    }

    // Reload deliberately has no wrapper: reloading a `cmux://` document
    // is allowed by the same-document rule below, and reloading anything
    // else was never our business.

    private static func armItem(_ webView: UnsafeMutablePointer<WebKitWebView>,
                                _ item: OpaquePointer) {
        guard let uri = webkit_back_forward_list_item_get_uri(item) else { return }
        arm(webView, String(cString: uri))
    }

    /// Only `cmux://` needs a token; arming for anything else would be
    /// noise, since the handler ignores every other scheme.
    private static func arm(_ webView: UnsafeMutablePointer<WebKitWebView>, _ uri: String) {
        guard isCmuxScheme(uri) else { return }
        armed[key(webView)] = normalize(uri)
    }

    // MARK: - The decision

    /// Called from the `decide-policy` handler. Returns true when we
    /// answered the decision, false to leave it to WebKit's default —
    /// which is every navigation that is not headed for `cmux://`.
    static func decide(view: UnsafeMutablePointer<WebKitWebView>,
                       decision: UnsafeMutablePointer<WebKitPolicyDecision>,
                       destination: String) -> Bool {
        guard isCmuxScheme(destination) else { return false }

        let target = normalize(destination)
        if armed[key(view)] == target {
            armed.removeValue(forKey: key(view))
            webkit_policy_decision_use(decision)
            return true
        }

        // A document already served from `cmux://` may navigate within
        // it — that is reload and in-page links, and the content there is
        // this process's own JSON and text, never a remote script. It is
        // also not an entry: a page can only get here if cmux put it here.
        // The MAIN frame's uri is the right question even for a subframe:
        // a remote page with a `cmux://` iframe has an http main frame.
        if let current = webkit_web_view_get_uri(view),
           isCmuxScheme(String(cString: current)) {
            webkit_policy_decision_use(decision)
            return true
        }

        webkit_policy_decision_ignore(decision)
        navPolicyLog("refused an unvouched navigation to \(target)")
        return true
    }

    // MARK: - Small helpers

    /// The view's ADDRESS, not its hashValue: two live views colliding in
    /// a seeded hash would let a token armed for one vouch for the other,
    /// which is the one thing this type must never do.
    private static func key(_ webView: UnsafeMutablePointer<WebKitWebView>) -> UInt {
        UInt(bitPattern: UnsafeRawPointer(webView))
    }

    static func forget(_ webView: UnsafeMutablePointer<WebKitWebView>) {
        armed.removeValue(forKey: key(webView))
        installed.remove(key(webView))
    }

    private static func isCmuxScheme(_ uri: String) -> Bool {
        uri.lowercased().hasPrefix("\(BrowserURIScheme.scheme)://")
    }

    /// WebKit may hand the destination back with a trailing slash that
    /// the caller did not write (`cmux://about` -> `cmux://about/`), so
    /// compare on a form where that difference cannot cause a false
    /// refusal of cmux's own load.
    private static func normalize(_ uri: String) -> String {
        var s = uri.lowercased()
        while s.hasSuffix("/") && s != "\(BrowserURIScheme.scheme)://" { s.removeLast() }
        return s
    }
}

/// File scope, like every other `@convention(c)` callback here: written
/// inside the enum it would capture the enclosing type as context and
/// fail to compile (`BrowserAutomation.swift:18`).
///
/// Signature is WebKitWebView::decide-policy — (view, decision, type,
/// user_data) -> gboolean, where returning TRUE stops emission. We return
/// FALSE for everything we do not decide, so any other handler on this
/// signal keeps seeing what it saw before.
let browserDecidePolicy: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Int32 = { viewPtr, decisionPtr, type, _ in
    guard let viewPtr, let decisionPtr else { return 0 }
    // Only navigation-shaped decisions carry a destination; a RESPONSE
    // decision is about a load already allowed.
    guard type == WEBKIT_POLICY_DECISION_TYPE_NAVIGATION_ACTION.rawValue
            || type == WEBKIT_POLICY_DECISION_TYPE_NEW_WINDOW_ACTION.rawValue else { return 0 }
    let decision = decisionPtr.assumingMemoryBound(to: WebKitPolicyDecision.self)
    // The navigation subclass is opaque to Swift while the base decision
    // is a named struct, so the same pointer is handed over in both shapes.
    guard let action = webkit_navigation_policy_decision_get_navigation_action(
              OpaquePointer(decisionPtr)),
          let request = webkit_navigation_action_get_request(action),
          let uri = webkit_uri_request_get_uri(request) else { return 0 }
    let view = viewPtr.assumingMemoryBound(to: WebKitWebView.self)
    let handled = BrowserNavigationPolicy.decide(view: view, decision: decision,
                                                 destination: String(cString: uri))
    return handled ? 1 : 0
}

/// Drops the view's armed token when the widget dies, so the map cannot
/// grow across the lifetime of a long-running instance.
let browserNavPolicyForget: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { viewPtr, _ in
    guard let viewPtr else { return }
    BrowserNavigationPolicy.forget(viewPtr.assumingMemoryBound(to: WebKitWebView.self))
}

func navPolicyLog(_ message: String) {
    FileHandle.standardError.write(Data("cmux nav-policy: \(message)\n".utf8))
}
