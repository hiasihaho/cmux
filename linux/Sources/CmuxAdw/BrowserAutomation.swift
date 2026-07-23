import Adwaita
import CWebKit
import Foundation

// Browser automation verbs (browser.eval/snapshot/click/…) over WebKitGTK.
//
// Everything here completes asynchronously: WebKit delivers JS results via
// GAsyncReadyCallback on the GLib main loop, and the socket dispatcher's
// completion (`respond`) is called from that callback — the main loop is
// never blocked, unlike the macOS port which pumps a nested RunLoop.
// Scripts, retry policy, and result shapes are copied from the macOS
// `TerminalController` v2Browser* handlers so the shared CLI sees
// byte-identical payloads.

// MARK: - GLib helpers

/// Closure carriers handed across C callbacks as `user_data` (file scope:
/// a local type inside a @convention(c) closure counts as captured context).
private final class ActionBox {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

private final class JSCallbackBox {
    let webView: UnsafeMutablePointer<WebKitWebView>
    let completion: (BrowserJSOutcome) -> Void
    init(webView: UnsafeMutablePointer<WebKitWebView>,
         completion: @escaping (BrowserJSOutcome) -> Void) {
        self.webView = webView
        self.completion = completion
    }
}

/// One-shot deferred main-loop callback (g_timeout_add); the GTK analog of
/// the macOS nested-RunLoop retry waits.
func scheduleOnMainLoop(afterMs ms: UInt32, _ action: @escaping () -> Void) {
    let box = Unmanaged.passRetained(ActionBox(action)).toOpaque()
    _ = g_timeout_add(guint(ms), { userData in
        guard let userData else { return gboolean(0) }
        Unmanaged<ActionBox>.fromOpaque(userData).takeRetainedValue().action()
        return gboolean(0) // G_SOURCE_REMOVE
    }, box)
}

// MARK: - element refs

/// Element handles allocated by `browser.snapshot` (`@e1`, `@e2`, …) so
/// follow-up actions can target `click @e3` — mirrors the macOS
/// `v2BrowserElementRefs` registry. Main-loop confined.
final class BrowserElementRefs {
    static let shared = BrowserElementRefs()
    private var nextOrdinal = 1
    private var entries: [String: (surfaceId: UUID, selector: String)] = [:]

    func allocate(surfaceId: UUID, selector: String) -> String {
        let ref = "@e\(nextOrdinal)"
        nextOrdinal += 1
        entries[ref] = (surfaceId, selector)
        return ref
    }

    /// Drops all refs of a closed surface (called from
    /// `SurfaceRegistry.unregister` so long automation sessions don't
    /// accumulate entries forever).
    func clear(for surfaceId: UUID) {
        entries = entries.filter { $0.value.surfaceId != surfaceId }
    }

    /// `@e3`/`e3` handle → stored selector (nil when unknown or from another
    /// surface); any other string passes through as a CSS selector.
    func resolve(_ raw: String, surfaceId: UUID) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let refKey: String? = {
            if trimmed.hasPrefix("@e") { return trimmed }
            if trimmed.hasPrefix("e"), Int(trimmed.dropFirst()) != nil { return "@\(trimmed)" }
            return nil
        }()
        if let refKey {
            guard let entry = entries[refKey], entry.surfaceId == surfaceId else { return nil }
            return entry.selector
        }
        return trimmed
    }
}

// MARK: - frame selection

/// Per-surface iframe selector set by `browser.frame.select` — automation
/// scripts run against that frame's document until `browser.frame.main`
/// clears it (macOS `v2BrowserFrameSelectorBySurface`). Main-loop confined.
final class BrowserFrameSelectors {
    static let shared = BrowserFrameSelectors()
    private var bySurface: [UUID: String] = [:]

    func selector(for surfaceId: UUID) -> String? { bySurface[surfaceId] }
    func set(_ selector: String, for surfaceId: UUID) { bySurface[surfaceId] = selector }
    func clear(for surfaceId: UUID) { bySurface.removeValue(forKey: surfaceId) }
}

// MARK: - async JS bridge

enum BrowserJSOutcome {
    /// JSON-decoded value: Dictionary/Array/String/NSNumber/NSNull.
    case success(Any)
    case failure(String)
}

enum BrowserJS {

    /// Isolated script world used to retry automation scripts when the page
    /// CSP forbids string eval in the main world (GitHub: `script-src
    /// github.githubassets.com`). WKWebView exempts user-agent scripts from
    /// page CSP; WebKitGTK main-world evaluation is subject to it, but
    /// isolated worlds share the DOM while bypassing main-world CSP.
    /// Main world stays the first attempt so `browser eval` keeps seeing
    /// page globals wherever the page allows it (macOS parity).
    static let cspFallbackWorld = "cmuxAutomation"

    static func isCSPEvalRefusal(_ message: String) -> Bool {
        message.contains("Refused to evaluate a string as JavaScript")
    }

    /// Runs `script` inside the same envelope the macOS port uses: promises
    /// are awaited, exceptions surface as `.failure`, and `undefined` is
    /// distinguished from `null` via the `__cmux_t` marker. When
    /// `frameSelector` is set, `document` is shadowed with that iframe's
    /// contentDocument (same-origin only), like the macOS frame prelude.
    /// The completion fires on the GLib main loop.
    static func run(
        _ webView: UnsafeMutablePointer<WebKitWebView>,
        script: String,
        frameSelector: String? = nil,
        completion: @escaping (BrowserJSOutcome) -> Void
    ) {
        runInWorld(webView, script: script, frameSelector: frameSelector, worldName: nil) { outcome in
            if case .failure(let message) = outcome, isCSPEvalRefusal(message) {
                runInWorld(
                    webView, script: script, frameSelector: frameSelector,
                    worldName: cspFallbackWorld, completion: completion
                )
                return
            }
            completion(outcome)
        }
    }

    private static func runInWorld(
        _ webView: UnsafeMutablePointer<WebKitWebView>,
        script: String,
        frameSelector: String?,
        worldName: String?,
        completion: @escaping (BrowserJSOutcome) -> Void
    ) {
        let scriptLiteral = jsonLiteral(script)
        let framePrelude: String
        if let frameSelector {
            let selectorLiteral = jsonLiteral(frameSelector)
            framePrelude = """
            let __cmuxDoc = document;
            try {
              const __cmuxFrame = document.querySelector(\(selectorLiteral));
              if (__cmuxFrame && __cmuxFrame.contentDocument) {
                __cmuxDoc = __cmuxFrame.contentDocument;
              }
            } catch (_) {}
            """
        } else {
            framePrelude = "const __cmuxDoc = document;"
        }
        // Function body for call_async_javascript_function (an implicit
        // async function, so `await`/`return` are valid) — the GTK analog
        // of WKWebView.callAsyncJavaScript, same envelope as macOS.
        let body = """
        \(framePrelude)
        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };
        const __cmuxEval = async function() {
          const document = __cmuxDoc;
          const __r = eval(\(scriptLiteral));
          const __value = await __cmuxMaybeAwait(__r);
          return {
            __cmux_t: (typeof __value === 'undefined') ? 'undefined' : 'value',
            __cmux_v: (typeof __value === 'undefined') ? null : __value
          };
        };
        return await __cmuxEval();
        """

        let box = Unmanaged.passRetained(
            JSCallbackBox(webView: webView, completion: completion)
        ).toOpaque()

        let callback: GAsyncReadyCallback = { _, result, userData in
            guard let userData else { return }
            let box = Unmanaged<JSCallbackBox>.fromOpaque(userData).takeRetainedValue()
            finishBrowserJSCall(box: box, result: result)
        }
        if let worldName {
            // WebKit copies the world name during the call; withCString is safe.
            worldName.withCString { world in
                webkit_web_view_call_async_javascript_function(
                    webView, body, -1, nil, world, nil, nil, callback, box
                )
            }
        } else {
            webkit_web_view_call_async_javascript_function(
                webView, body, -1, nil, nil, nil, nil, callback, box
            )
        }
    }

    /// `{__cmux_t, __cmux_v}` envelope → plain value. `undefined` keeps the
    /// marker shape on the wire, exactly like the macOS normalizer.
    static func unwrapEnvelope(_ decoded: Any) -> Any {
        guard let dict = decoded as? [String: Any],
              let type = dict["__cmux_t"] as? String else { return decoded }
        if type == "undefined" {
            return ["__cmux_t": "undefined", "__cmux_v": NSNull()]
        }
        return dict["__cmux_v"] ?? NSNull()
    }

    /// A value as a JS literal (same as the macOS `v2JSONLiteral`).
    static func jsonLiteral(_ value: Any) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: [value], options: []),
           let text = String(data: data, encoding: .utf8),
           text.count >= 2 {
            return String(text.dropFirst().dropLast())
        }
        if let s = value as? String {
            return "\"\(s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        }
        return "null"
    }
}

/// GAsyncReadyCallback completion for `BrowserJS.run` — a file-scope
/// function because the C callback closure may not capture context.
private func finishBrowserJSCall(box: JSCallbackBox, result: OpaquePointer?) {
    var gerror: UnsafeMutablePointer<GError>?
    let jsValue = webkit_web_view_call_async_javascript_function_finish(
        box.webView, result, &gerror
    )
    if let gerror {
        let message = String(cString: gerror.pointee.message)
        g_error_free(gerror)
        box.completion(.failure(message))
        return
    }
    guard let jsValue else {
        box.completion(.failure("JavaScript returned no result"))
        return
    }
    defer { g_object_unref(UnsafeMutableRawPointer(jsValue)) }
    guard let json = jsc_value_to_json(jsValue, 0) else {
        box.completion(.failure("JavaScript result is not JSON-serializable"))
        return
    }
    let text = String(cString: json)
    g_free(json)
    guard let decoded = try? JSONSerialization.jsonObject(
        with: Data(text.utf8), options: [.fragmentsAllowed]
    ) else {
        box.completion(.failure("Failed to decode JavaScript result"))
        return
    }
    box.completion(.success(BrowserJS.unwrapEnvelope(decoded)))
}

// MARK: - snapshot (screenshot) C-callback plumbing

private final class SnapshotCallbackBox {
    let webView: UnsafeMutablePointer<WebKitWebView>
    /// (png_base64, errorMessage) — exactly one is non-nil.
    let completion: (String?, String?) -> Void
    init(webView: UnsafeMutablePointer<WebKitWebView>,
         completion: @escaping (String?, String?) -> Void) {
        self.webView = webView
        self.completion = completion
    }
}

private func finishBrowserSnapshot(box: SnapshotCallbackBox, result: OpaquePointer?) {
    var gerror: UnsafeMutablePointer<GError>?
    let texture = webkit_web_view_get_snapshot_finish(box.webView, result, &gerror)
    if let gerror {
        let message = String(cString: gerror.pointee.message)
        g_error_free(gerror)
        box.completion(nil, message)
        return
    }
    guard let texture else {
        box.completion(nil, "Snapshot returned no image")
        return
    }
    defer { g_object_unref(UnsafeMutableRawPointer(texture)) }
    guard let bytes = gdk_texture_save_to_png_bytes(texture) else {
        box.completion(nil, "Failed to encode PNG")
        return
    }
    defer { g_bytes_unref(bytes) }
    var size: gsize = 0
    guard let data = g_bytes_get_data(bytes, &size), size > 0 else {
        box.completion(nil, "Snapshot produced empty image data")
        return
    }
    guard let encoded = g_base64_encode(data.assumingMemoryBound(to: guchar.self), size) else {
        box.completion(nil, "Failed to base64-encode PNG")
        return
    }
    let base64 = String(cString: encoded)
    g_free(encoded)
    box.completion(base64, nil)
}

// MARK: - cookie C-callback plumbing

/// get_all_cookies carrier. The completion receives OWNED SoupCookie
/// pointers (transfer full from WebKit) — the receiver must
/// `soup_cookie_free` every one of them.
private final class CookieListBox {
    let manager: OpaquePointer
    let completion: ([OpaquePointer]?, String?) -> Void
    init(manager: OpaquePointer,
         completion: @escaping ([OpaquePointer]?, String?) -> Void) {
        self.manager = manager
        self.completion = completion
    }
}

private func finishCookieList(box: CookieListBox, result: OpaquePointer?) {
    var gerror: UnsafeMutablePointer<GError>?
    let list = webkit_cookie_manager_get_all_cookies_finish(box.manager, result, &gerror)
    if let gerror {
        let message = String(cString: gerror.pointee.message)
        g_error_free(gerror)
        box.completion(nil, message)
        return
    }
    var cookies: [OpaquePointer] = []
    var node = list
    while let current = node {
        if let data = current.pointee.data {
            cookies.append(OpaquePointer(data))
        }
        node = current.pointee.next
    }
    // Free only the list nodes; cookie ownership moves to the completion.
    g_list_free(list)
    box.completion(cookies, nil)
}

/// Sequential add/delete over the async cookie manager API. Owns the
/// cookies for the duration and frees all of them when the chain ends
/// (success, per-step error, or empty list).
private final class CookieChainBox {
    let manager: OpaquePointer
    var cookies: [OpaquePointer]
    let isDelete: Bool
    var index = 0
    var succeeded = 0
    /// (succeededCount, errorMessage)
    let onDone: (Int, String?) -> Void

    init(manager: OpaquePointer, cookies: [OpaquePointer], isDelete: Bool,
         onDone: @escaping (Int, String?) -> Void) {
        self.manager = manager
        self.cookies = cookies
        self.isDelete = isDelete
        self.onDone = onDone
    }

    func freeCookies() {
        for cookie in cookies { soup_cookie_free(cookie) }
        cookies = []
    }
}

private func cookieChainStep(_ box: CookieChainBox) {
    guard box.index < box.cookies.count else {
        box.freeCookies()
        box.onDone(box.succeeded, nil)
        return
    }
    let cookie = box.cookies[box.index]
    let userData = Unmanaged.passRetained(box).toOpaque()
    let callback: GAsyncReadyCallback = { _, result, userData in
        guard let userData else { return }
        let box = Unmanaged<CookieChainBox>.fromOpaque(userData).takeRetainedValue()
        var gerror: UnsafeMutablePointer<GError>?
        let ok: gboolean
        if box.isDelete {
            ok = webkit_cookie_manager_delete_cookie_finish(box.manager, result, &gerror)
        } else {
            ok = webkit_cookie_manager_add_cookie_finish(box.manager, result, &gerror)
        }
        if let gerror {
            let message = String(cString: gerror.pointee.message)
            g_error_free(gerror)
            box.freeCookies()
            box.onDone(box.succeeded, message)
            return
        }
        if ok != 0 { box.succeeded += 1 }
        box.index += 1
        cookieChainStep(box)
    }
    if box.isDelete {
        webkit_cookie_manager_delete_cookie(box.manager, cookie, nil, callback, userData)
    } else {
        webkit_cookie_manager_add_cookie(box.manager, cookie, nil, callback, userData)
    }
}

/// Wire shape of one cookie — mirrors the macOS `v2BrowserCookieDict`
/// built from HTTPCookie (name/value/domain/path/secure/session_only/expires).
private func soupCookieDict(_ cookie: OpaquePointer) -> [String: Any] {
    let expires = soup_cookie_get_expires(cookie)
    return [
        "name": soup_cookie_get_name(cookie).map { String(cString: $0) } ?? "",
        "value": soup_cookie_get_value(cookie).map { String(cString: $0) } ?? "",
        "domain": soup_cookie_get_domain(cookie).map { String(cString: $0) } ?? "",
        "path": soup_cookie_get_path(cookie).map { String(cString: $0) } ?? "",
        "secure": soup_cookie_get_secure(cookie) != 0,
        "session_only": expires == nil,
        "expires": expires.map { Int(g_date_time_to_unix($0)) as Any } ?? NSNull()
    ]
}

// MARK: - shared JS helpers

/// `__cmuxCssPath(el)` — stable CSS path for a found element (verbatim from
/// the macOS `v2BrowserFindWithScript`); shared by the find locators.
private let cssPathJSHelper = """
      const __cmuxCssPath = (el) => {
        if (!el || el.nodeType !== 1) return null;
        if (el.id) return '#' + CSS.escape(el.id);
        const parts = [];
        let cur = el;
        while (cur && cur.nodeType === 1) {
          let part = String(cur.tagName || '').toLowerCase();
          if (!part) break;
          if (cur.id) {
            part += '#' + CSS.escape(cur.id);
            parts.unshift(part);
            break;
          }
          const tag = part;
          let siblings = cur.parentElement ? Array.from(cur.parentElement.children).filter((n) => String(n.tagName || '').toLowerCase() === tag) : [];
          if (siblings.length > 1) {
            const pos = siblings.indexOf(cur) + 1;
            part += `:nth-of-type(${pos})`;
          }
          parts.unshift(part);
          cur = cur.parentElement;
        }
        return parts.join(' > ');
      };
"""

// MARK: - telemetry (console/errors) capture v2

/// Per-surface console/error ring buffers filled by the document-start
/// user script below (roadmap/06 increment 1). Replaces the old lazily
/// armed `window.console` wrap, which broke on strict-CSP sites: the
/// arming eval landed in the isolated world and wrapped the wrong
/// world's console, capturing nothing the page logged. User scripts are
/// user-agent scripts — exempt from page CSP, no eval — so capture now
/// starts at page load on every site. Main-loop confined.
final class BrowserConsoleLog {
    static let shared = BrowserConsoleLog()
    private static let limit = 512

    private var console: [UUID: [[String: Any]]] = [:]
    private var errors: [UUID: [[String: Any]]] = [:]

    /// Wire shapes match the previous JS buffers exactly:
    /// console `{level, text, timestamp_ms}`, errors
    /// `{message, source, line, column, timestamp_ms}`.
    func append(_ entry: [String: Any], for surfaceId: UUID) {
        let isError = (entry["kind"] as? String) == "error"
        var row = entry
        row.removeValue(forKey: "kind")
        if isError {
            var list = errors[surfaceId] ?? []
            list.append(row)
            if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
            errors[surfaceId] = list
        } else {
            var list = console[surfaceId] ?? []
            list.append(row)
            if list.count > Self.limit { list.removeFirst(list.count - Self.limit) }
            console[surfaceId] = list
        }
    }

    func entries(for surfaceId: UUID, isErrors: Bool) -> [[String: Any]] {
        (isErrors ? errors[surfaceId] : console[surfaceId]) ?? []
    }

    func clear(for surfaceId: UUID, isErrors: Bool) {
        if isErrors { errors[surfaceId] = [] } else { console[surfaceId] = [] }
    }

    func clearAll(for surfaceId: UUID) {
        console.removeValue(forKey: surfaceId)
        errors.removeValue(forKey: surfaceId)
    }
}

/// Script-message channel name; also the `window.webkit.messageHandlers`
/// key the user script posts through.
private let consoleMessageHandlerName = "cmuxConsole"

/// Document-start user script: wraps console.* and error events and
/// posts each entry to the app. Plain JS (no eval) so strict CSP cannot
/// refuse it, and it runs before any page script.
private let browserConsoleUserScript = """
(() => {
  if (window.__cmuxConsoleInstalled) return;
  window.__cmuxConsoleInstalled = true;
  const post = (payload) => {
    try { window.webkit.messageHandlers.\(consoleMessageHandlerName).postMessage(payload); } catch (_) {}
  };
  const fmt = (args) => Array.from(args || []).map((x) => {
    if (typeof x === 'string') return x;
    try { return JSON.stringify(x); } catch (_) { return String(x); }
  }).join(' ');
  for (const level of ['log', 'info', 'warn', 'error', 'debug']) {
    const orig = (window.console && window.console[level])
      ? window.console[level].bind(window.console) : null;
    window.console[level] = function(...args) {
      post({ kind: 'console', level, text: fmt(args), timestamp_ms: Date.now() });
      if (orig) return orig(...args);
    };
  }
  window.addEventListener('error', (ev) => {
    post({
      kind: 'error',
      message: String((ev && ev.message) || ''),
      source: String((ev && ev.filename) || ''),
      line: Number((ev && ev.lineno) || 0),
      column: Number((ev && ev.colno) || 0),
      timestamp_ms: Date.now()
    });
  });
  window.addEventListener('unhandledrejection', (ev) => {
    const reason = ev && ev.reason;
    const message = typeof reason === 'string'
      ? reason
      : (reason && reason.message ? String(reason.message) : String(reason));
    post({
      kind: 'error', message, source: 'unhandledrejection',
      line: 0, column: 0, timestamp_ms: Date.now()
    });
  });
})();
"""

/// Carries the surface identity across the C signal callback (which may
/// not capture context), released by the closure-notify below.
private final class ConsoleMessageBox {
    let surfaceId: UUID
    init(surfaceId: UUID) { self.surfaceId = surfaceId }
}

/// One navigation in flight. `load-changed` is connected BEFORE the load is
/// requested, so "has it committed yet?" cannot race the request — polling
/// after the fact is what made `goto` return while the *previous* document
/// was still live, which turned into silently reading the wrong page.
private final class NavigationBarrier {
    var handlerId: UInt = 0
    var webView: UnsafeMutablePointer<WebKitWebView>?
    var committed = false
    var onEvent: ((UInt32) -> Void)?
    private var settled = false

    /// Idempotent by design: the load event and the deadline race, and
    /// whichever arrives first owns the single response.
    func settle() -> Bool {
        guard !settled else { return false }
        settled = true
        if let webView, handlerId != 0 {
            g_signal_handler_disconnect(UnsafeMutableRawPointer(webView), handlerId)
            handlerId = 0
        }
        onEvent = nil
        return true
    }
}

private let navigationLoadChanged: @convention(c) (
    UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?
) -> Void = { _, loadEvent, userData in
    guard let userData else { return }
    let barrier = Unmanaged<NavigationBarrier>.fromOpaque(userData).takeUnretainedValue()
    // Copy the closure out first: `settle()` clears `onEvent`, and releasing
    // it while it is still on the stack would be a use-after-free.
    let handler = barrier.onEvent
    handler?(loadEvent)
}

private let navigationBarrierDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<NavigationBarrier>.fromOpaque(data).release()
}

/// Installs console/error capture on a freshly created browser surface:
/// connect the signal FIRST, then register the handler (the WebKitGTK
/// docs warn about the race the other way around), then add the
/// document-start user script.
func installBrowserConsoleCapture(
    _ webView: UnsafeMutablePointer<WebKitWebView>,
    surfaceId: UUID
) {
    guard let manager = webkit_web_view_get_user_content_manager(webView) else { return }

    let box = Unmanaged.passRetained(ConsoleMessageBox(surfaceId: surfaceId)).toOpaque()
    let callback: @convention(c) (
        UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?
    ) -> Void = { _, value, userData in
        guard let userData, let value else { return }
        let box = Unmanaged<ConsoleMessageBox>.fromOpaque(userData).takeUnretainedValue()
        guard let json = jsc_value_to_json(value, 0) else { return }
        let text = String(cString: json)
        g_free(json)
        guard let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
              let entry = decoded as? [String: Any] else { return }
        BrowserConsoleLog.shared.append(entry, for: box.surfaceId)
    }
    let destroy: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<ConsoleMessageBox>.fromOpaque(data).release()
    }
    g_signal_connect_data(
        UnsafeMutableRawPointer(manager),
        "script-message-received::\(consoleMessageHandlerName)",
        unsafeBitCast(callback, to: GCallback.self),
        box,
        destroy,
        GConnectFlags(0)
    )
    _ = webkit_user_content_manager_register_script_message_handler(
        manager, consoleMessageHandlerName, nil
    )

    if let script = webkit_user_script_new(
        browserConsoleUserScript,
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        nil, nil
    ) {
        webkit_user_content_manager_add_script(manager, script)
        webkit_user_script_unref(script)
    }
}

// MARK: - dialog hooks

/// Overrides window.alert/confirm/prompt with queue-recording stubs —
/// verbatim copy of the macOS `dialogTelemetryHookBootstrapScriptSource`.
/// Installed lazily by the first dialog verb (macOS parity): interactive
/// pages keep WebKitGTK's native dialogs until automation arms the hooks.
private let browserDialogHookScript = """
(() => {
  if (window.__cmuxDialogHooksInstalled) return true;
  window.__cmuxDialogHooksInstalled = true;

  window.__cmuxDialogQueue = window.__cmuxDialogQueue || [];
  window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
  const __pushDialog = (type, message, defaultText) => {
    window.__cmuxDialogQueue.push({
      type,
      message: String(message || ''),
      default_text: defaultText == null ? null : String(defaultText),
      timestamp_ms: Date.now()
    });
    if (window.__cmuxDialogQueue.length > 128) {
      window.__cmuxDialogQueue.splice(0, window.__cmuxDialogQueue.length - 128);
    }
  };

  window.alert = function(message) {
    __pushDialog('alert', message, null);
  };
  window.confirm = function(message) {
    __pushDialog('confirm', message, null);
    return !!window.__cmuxDialogDefaults.confirm;
  };
  window.prompt = function(message, defaultValue) {
    __pushDialog('prompt', message, defaultValue == null ? null : defaultValue);
    const v = window.__cmuxDialogDefaults.prompt;
    if (v === null || v === undefined) {
      return defaultValue == null ? '' : String(defaultValue);
    }
    return String(v);
  };

  return true;
})()
"""

// MARK: - automation verbs

extension ControlCommandHandler {

    private struct AutomationTarget {
        let tab: TerminalTab
        let surfaceId: UUID
        let webView: UnsafeMutablePointer<WebKitWebView>

        var refPayload: [String: Any] {
            let registry = RefRegistry.shared
            return [
                "workspace_id": tab.id.uuidString,
                "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
                "surface_id": surfaceId.uuidString,
                "surface_ref": registry.ref(kind: "surface", uuid: surfaceId)
            ]
        }
    }

    // MARK: verbs

    /// Frame-aware script runner: routes through the surface's selected
    /// iframe (browser.frame.select), the macOS `v2RunBrowserJavaScript`.
    private func runTargetJS(
        _ target: AutomationTarget,
        script: String,
        completion: @escaping (BrowserJSOutcome) -> Void
    ) {
        BrowserJS.run(
            target.webView,
            script: script,
            frameSelector: BrowserFrameSelectors.shared.selector(for: target.surfaceId),
            completion: completion
        )
    }

    func v2BrowserEval(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let script = stringParam(params, "script") else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing script"))
        }
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        runTargetJS(target, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message))
            case .success(let value):
                var payload = target.refPayload
                payload["value"] = value
                respond(self.baOk(id: id, result: payload))
            }
        }
    }

    func v2BrowserSnapshot(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let interactive = boolParam(params, "interactive") ?? false
        let cursor = boolParam(params, "cursor") ?? false
        let compact = boolParam(params, "compact") ?? false
        let depthParam: Int = intParam(params, "max_depth") ?? intParam(params, "maxDepth") ?? 12
        let maxDepth = max(0, depthParam)
        let scopeSelector = stringParam(params, "selector")
        runSnapshot(
            target: target,
            interactive: interactive,
            cursor: cursor,
            compact: compact,
            maxDepth: maxDepth,
            scopeSelector: scopeSelector
        ) { result in
            switch result {
            case .failure(let error):
                respond(self.baError(id: id, code: error.code, message: error.message, data: error.data))
            case .success(let snapshot):
                var payload = target.refPayload
                payload.merge(snapshot) { _, new in new }
                respond(self.baOk(id: id, result: payload))
            }
        }
    }

    /// `goto`. Blocks until the new document is live (see `runNavigation`);
    /// `no_wait` restores the old fire-and-forget behavior.
    func v2BrowserNavigate(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        guard let url = stringParam(params, "url") else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing url"))
        }
        runNavigation(id: id, params: params, target: target,
                      baseResult: ["url": url], respond: respond) { webView in
            webkit_web_view_load_uri(webView, url)
        }
    }

    /// back/forward/reload commit a new document exactly like `goto` does,
    /// so they get the same barrier rather than their own race.
    func v2BrowserHistory(
        id: Any?, params: [String: Any], action: String,
        respond: @escaping (String) -> Void
    ) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        runNavigation(id: id, params: params, target: target,
                      baseResult: ["action": action], respond: respond) { webView in
            switch action {
            case "back": webkit_web_view_go_back(webView)
            case "forward": webkit_web_view_go_forward(webView)
            default: webkit_web_view_reload(webView)
            }
        }
    }

    /// Shared navigation barrier. WebKit loads asynchronously, so returning
    /// as soon as the load is *requested* leaves the previous document
    /// answering every follow-up command — success is reported while the
    /// data is from the wrong page. We therefore hold the response until the
    /// new document is committed.
    ///
    /// Resolution, in order of preference: FINISHED (the page is fully
    /// loaded — what a caller means by "go here"), else COMMITTED once the
    /// deadline passes (the stale-document hazard is gone, the page may
    /// still be fetching subresources; reported as `load_state`), else a
    /// real `timeout` error, because with no commit at all the old page is
    /// still the one that would answer.
    private func runNavigation(
        id: Any?,
        params: [String: Any],
        target: AutomationTarget,
        baseResult: [String: Any],
        respond: @escaping (String) -> Void,
        start: (UnsafeMutablePointer<WebKitWebView>) -> Void
    ) {
        var result = baseResult
        if boolParam(params, "no_wait") == true {
            start(target.webView)
            result["load_state"] = "started"
            return respond(baOk(id: id, result: result))
        }

        let timeoutMs = max(1, intParam(params, "timeout_ms") ?? 10_000)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        let barrier = NavigationBarrier()
        barrier.webView = target.webView

        // When the caller also passed a predicate, chain straight into
        // `wait` so `goto --wait-selector` is ONE barrier; issuing them as
        // two commands leaves a gap the old document can still answer in.
        let succeed: (String) -> Void = { loadState in
            result["load_state"] = loadState
            guard let waitParams = self.navigationWaitParams(params, deadline: deadline) else {
                return respond(self.baOk(id: id, result: result))
            }
            self.v2BrowserWait(id: id, params: waitParams, respond: respond)
        }

        barrier.onEvent = { [weak barrier] event in
            guard let barrier else { return }
            switch event {
            case WEBKIT_LOAD_COMMITTED.rawValue:
                barrier.committed = true
            case WEBKIT_LOAD_FINISHED.rawValue:
                // Only OUR load counts. Starting a navigation cancels any
                // in-flight one, and that cancellation also emits FINISHED —
                // honoring it would settle the barrier on the *previous*
                // load and hand back the very staleness this exists to stop.
                // A commit is the earliest point the event is provably ours.
                guard barrier.committed, barrier.settle() else { return }
                succeed("finished")
            default:
                break
            }
        }

        let box = Unmanaged.passRetained(barrier).toOpaque()
        barrier.handlerId = g_signal_connect_data(
            UnsafeMutableRawPointer(target.webView),
            "load-changed",
            unsafeBitCast(navigationLoadChanged, to: GCallback.self),
            box,
            navigationBarrierDestroy,
            GConnectFlags(0)
        )

        start(target.webView)

        scheduleOnMainLoop(afterMs: UInt32(timeoutMs)) {
            guard barrier.settle() else { return }
            if barrier.committed {
                succeed("committed")
            } else {
                // Abandon the attempt, don't just report it: without an
                // explicit stop the provisional load keeps running after
                // the caller was told it failed — and can commit MINUTES
                // later, yanking the pane to a page the caller believes
                // it never reached. The hanging provisional context also
                // answers evals with an empty document until it dies.
                // Found 2026-07-23 when the dev box joined a corporate
                // network and the "unreachable" fixture address turned
                // into a connected-but-silent real host.
                webkit_web_view_stop_loading(target.webView)
                respond(self.baError(
                    id: id, code: "timeout",
                    message: "Navigation did not commit before timeout",
                    data: ["timeout_ms": timeoutMs]
                ))
            }
        }
    }

    /// Maps the navigation-scoped wait flags onto `browser.wait`'s own
    /// parameter names, budgeting whatever is left of the deadline. Returns
    /// nil when the caller asked for no predicate (plain `goto`), since
    /// `wait` would otherwise apply its own readyState default.
    private func navigationWaitParams(
        _ params: [String: Any], deadline: Date
    ) -> [String: Any]? {
        var waitParams = params
        for key in ["url", "selector", "sel", "element_ref", "ref",
                    "function", "url_contains", "text_contains", "load_state"] {
            waitParams.removeValue(forKey: key)
        }
        if let selector = stringParam(params, "wait_selector") {
            waitParams["selector"] = selector
        } else if let fn = stringParam(params, "wait_function") {
            waitParams["function"] = fn
        } else if let state = stringParam(params, "wait_load_state") {
            waitParams["load_state"] = state
        } else {
            return nil
        }
        waitParams["timeout_ms"] = max(250, Int(deadline.timeIntervalSinceNow * 1000))
        return waitParams
    }

    func v2BrowserWait(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        let timeoutMs = max(1, intParam(params, "timeout_ms") ?? 5_000)
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let conditionScript: String = {
            if let selector = selectorParam(params) {
                return "document.querySelector(\(BrowserJS.jsonLiteral(selector))) !== null"
            }
            if let urlContains = stringParam(params, "url_contains") {
                return "String(location.href || '').includes(\(BrowserJS.jsonLiteral(urlContains)))"
            }
            if let textContains = stringParam(params, "text_contains") {
                return "(document.body && String(document.body.innerText || '').includes(\(BrowserJS.jsonLiteral(textContains))))"
            }
            if let loadState = stringParam(params, "load_state") {
                return "String(document.readyState || '').toLowerCase() === \(BrowserJS.jsonLiteral(loadState.lowercased()))"
            }
            if let fn = stringParam(params, "function") {
                return "(() => { return !!(\(fn)); })()"
            }
            return "document.readyState === 'complete'"
        }()
        let wrapped = "(() => { try { return !!(\(conditionScript)); } catch (_) { return false; } })()"
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        func poll() {
            self.runTargetJS(target, script: wrapped) { outcome in
                if case .success(let value) = outcome, self.boolValue(value) == true {
                    var payload = target.refPayload
                    payload["waited"] = true
                    respond(self.baOk(id: id, result: payload))
                    return
                }
                guard Date() < deadline else {
                    respond(self.baError(
                        id: id, code: "timeout",
                        message: "Condition not met before timeout",
                        data: ["timeout_ms": timeoutMs]
                    ))
                    return
                }
                scheduleOnMainLoop(afterMs: 50) { poll() }
            }
        }
        poll()
    }

    /// All single-selector verbs (click/fill/get.*/is.* …) share the macOS
    /// retry-and-diagnose machinery; only the injected script differs.
    func v2BrowserSelectorVerb(method: String, id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        let actionName = String(method.dropFirst("browser.".count))
        let scriptBuilder: (String) -> String

        switch method {
        case "browser.highlight":
            // Agent debugging aid: outline the match for two seconds.
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  el.scrollIntoView({ block: 'center', inline: 'nearest' });
                  const prev = el.style.outline;
                  const prevOffset = el.style.outlineOffset;
                  el.style.outline = '3px solid #f60';
                  el.style.outlineOffset = '2px';
                  setTimeout(() => {
                    el.style.outline = prev;
                    el.style.outlineOffset = prevOffset;
                  }, 2000);
                  return { ok: true };
                })()
                """ }
        case "browser.click":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                  if (typeof el.click === 'function') {
                    el.click();
                  } else {
                    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 1 }));
                  }
                  return { ok: true };
                })()
                """ }
        case "browser.dblclick":
            // Deviation from macOS (which only fires dblclick): a real double
            // click fires click, click, dblclick — dogfood cycle 4 caught
            // onclick handlers never running.
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                  if (typeof el.click === 'function') {
                    el.click();
                    el.click();
                  } else {
                    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 1 }));
                    el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window, detail: 2 }));
                  }
                  el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true, cancelable: true, view: window, detail: 2 }));
                  return { ok: true };
                })()
                """ }
        case "browser.hover":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
                  el.dispatchEvent(new MouseEvent('mouseover', { bubbles: true, cancelable: true, view: window }));
                  el.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true, cancelable: true, view: window }));
                  return { ok: true };
                })()
                """ }
        case "browser.focus":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.focus === 'function') el.focus();
                  return { ok: true };
                })()
                """ }
        case "browser.type":
            guard let text = stringParam(params, "text") else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing text"))
            }
            let textLiteral = BrowserJS.jsonLiteral(text)
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.focus === 'function') el.focus();
                  const chunk = String(\(textLiteral));
                  if ('value' in el) {
                    el.value = (el.value || '') + chunk;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                  } else {
                    el.textContent = (el.textContent || '') + chunk;
                  }
                  return { ok: true };
                })()
                """ }
        case "browser.fill":
            // `fill` allows empty strings so callers can clear inputs.
            guard let text = rawStringParam(params, "text") ?? rawStringParam(params, "value") else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing text/value"))
            }
            let textLiteral = BrowserJS.jsonLiteral(text)
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.focus === 'function') el.focus();
                  const value = String(\(textLiteral));
                  if ('value' in el) {
                    el.value = value;
                    el.dispatchEvent(new Event('input', { bubbles: true }));
                    el.dispatchEvent(new Event('change', { bubbles: true }));
                  } else {
                    el.textContent = value;
                  }
                  return { ok: true };
                })()
                """ }
        case "browser.check", "browser.uncheck":
            let checked = method == "browser.check" ? "true" : "false"
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (!('checked' in el)) return { ok: false, error: 'not_checkable' };
                  el.checked = \(checked);
                  el.dispatchEvent(new Event('input', { bubbles: true }));
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                  return { ok: true };
                })()
                """ }
        case "browser.select":
            guard let value = stringParam(params, "value") ?? stringParam(params, "text") else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing value"))
            }
            let valueLiteral = BrowserJS.jsonLiteral(value)
            // Deviation from macOS: validate the option exists first —
            // assigning a non-matching value to a <select> silently clears
            // the selection while still reporting OK (dogfood cycle 4).
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (!('value' in el)) return { ok: false, error: 'not_select' };
                  const value = String(\(valueLiteral));
                  if (el.options) {
                    const match = Array.from(el.options).some((o) => o.value === value);
                    if (!match) return { ok: false, error: 'option_not_found' };
                  }
                  el.value = value;
                  el.dispatchEvent(new Event('input', { bubbles: true }));
                  el.dispatchEvent(new Event('change', { bubbles: true }));
                  return { ok: true };
                })()
                """ }
        case "browser.scroll_into_view":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  el.scrollIntoView({ block: 'center', inline: 'center', behavior: 'instant' });
                  return { ok: true };
                })()
                """ }
        case "browser.get.text":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  return { ok: true, value: String(el.innerText || el.textContent || '') };
                })()
                """ }
        case "browser.get.html":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  return { ok: true, value: String(el.outerHTML || '') };
                })()
                """ }
        case "browser.get.value":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  const value = ('value' in el) ? el.value : (el.textContent || '');
                  return { ok: true, value: String(value || '') };
                })()
                """ }
        case "browser.get.attr":
            guard let attr = stringParam(params, "attr") ?? stringParam(params, "name") else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing attr/name"))
            }
            let attrLiteral = BrowserJS.jsonLiteral(attr)
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  return { ok: true, value: el.getAttribute(String(\(attrLiteral))) };
                })()
                """ }
        case "browser.get.box":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  const r = el.getBoundingClientRect();
                  return { ok: true, value: { x: r.x, y: r.y, width: r.width, height: r.height, top: r.top, left: r.left, right: r.right, bottom: r.bottom } };
                })()
                """ }
        case "browser.get.styles":
            if let property = stringParam(params, "property") {
                let propLiteral = BrowserJS.jsonLiteral(property)
                scriptBuilder = { sel in """
                    (() => {
                      const el = document.querySelector(\(sel));
                      if (!el) return { ok: false, error: 'not_found' };
                      const style = getComputedStyle(el);
                      return { ok: true, value: style.getPropertyValue(String(\(propLiteral))) };
                    })()
                    """ }
            } else {
                scriptBuilder = { sel in """
                    (() => {
                      const el = document.querySelector(\(sel));
                      if (!el) return { ok: false, error: 'not_found' };
                      const style = getComputedStyle(el);
                      return { ok: true, value: {
                        display: style.display,
                        visibility: style.visibility,
                        opacity: style.opacity,
                        color: style.color,
                        background: style.background,
                        width: style.width,
                        height: style.height
                      } };
                    })()
                    """ }
            }
        case "browser.is.visible":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  const style = getComputedStyle(el);
                  const rect = el.getBoundingClientRect();
                  const visible = style.display !== 'none' && style.visibility !== 'hidden' && parseFloat(style.opacity || '1') > 0 && rect.width > 0 && rect.height > 0;
                  return { ok: true, value: visible };
                })()
                """ }
        case "browser.is.enabled":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  const enabled = !el.disabled;
                  return { ok: true, value: !!enabled };
                })()
                """ }
        case "browser.is.checked":
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  const checked = ('checked' in el) ? !!el.checked : false;
                  return { ok: true, value: checked };
                })()
                """ }
        default:
            return respond(baError(id: id, code: "unknown_method", message: "Unknown browser verb: \(method)"))
        }

        runSelectorAction(
            id: id, params: params, actionName: actionName,
            scriptBuilder: scriptBuilder, respond: respond
        )
    }

    /// press/keydown/keyup — dispatch to the active element, no selector.
    func v2BrowserKeyVerb(method: String, id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let key = stringParam(params, "key") else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing key"))
        }
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let keyLiteral = BrowserJS.jsonLiteral(key)
        // Deviation from macOS for `press`: synthetic KeyboardEvents are
        // untrusted, so the browser never runs the default text-insertion
        // action — `press 'x'` on a focused input was a silent no-op
        // (dogfood cycle 4). Emulate insertion for single printable chars.
        let insertion = method == "browser.press" ? """
            if (k.length === 1) {
                try {
                  if (('value' in target) && !target.disabled && !target.readOnly) {
                    if (target.selectionStart != null && typeof target.setRangeText === 'function') {
                      target.setRangeText(k, target.selectionStart, target.selectionEnd, 'end');
                    } else {
                      target.value = String(target.value || '') + k;
                    }
                    target.dispatchEvent(new Event('input', { bubbles: true }));
                  } else if (target.isContentEditable) {
                    target.textContent = String(target.textContent || '') + k;
                    target.dispatchEvent(new Event('input', { bubbles: true }));
                  }
                } catch (_) {}
              }
            """ : ""
        let events: [String]
        switch method {
        case "browser.keydown": events = ["keydown"]
        case "browser.keyup": events = ["keyup"]
        default: events = ["keydown", "keypress"]
        }
        let dispatches = events
            .map { "target.dispatchEvent(new KeyboardEvent('\($0)', { key: k, bubbles: true, cancelable: true }));" }
            .joined(separator: "\n              ")
        let keyupDispatch = method == "browser.press"
            ? "target.dispatchEvent(new KeyboardEvent('keyup', { key: k, bubbles: true, cancelable: true }));"
            : ""
        let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              \(dispatches)
              \(insertion)
              \(keyupDispatch)
              return { ok: true };
            })()
            """
        runTargetJS(target, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message))
            case .success:
                self.appendPostSnapshot(params: params, target: target, payload: target.refPayload) { merged in
                    respond(self.baOk(id: id, result: merged))
                }
            }
        }
    }

    func v2BrowserScroll(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        let dx = intParam(params, "dx") ?? 0
        let dy = intParam(params, "dy") ?? 0
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let selectorRaw = selectorParam(params)
        let selector = selectorRaw.flatMap { BrowserElementRefs.shared.resolve($0, surfaceId: target.surfaceId) }
        if selectorRaw != nil && selector == nil {
            return respond(baError(
                id: id, code: "not_found", message: "Element reference not found",
                data: ["selector": selectorRaw ?? ""]
            ))
        }
        let script: String
        if let selector {
            let selectorLiteral = BrowserJS.jsonLiteral(selector)
            script = """
                (() => {
                  const el = document.querySelector(\(selectorLiteral));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (typeof el.scrollBy === 'function') {
                    el.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' });
                  } else {
                    el.scrollLeft += \(dx);
                    el.scrollTop += \(dy);
                  }
                  return { ok: true };
                })()
                """
        } else {
            script = "window.scrollBy({ left: \(dx), top: \(dy), behavior: 'instant' }); ({ ok: true })"
        }
        runTargetJS(target, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message))
            case .success(let value):
                if let dict = value as? [String: Any],
                   self.boolValue(dict["ok"]) == false,
                   (dict["error"] as? String) == "not_found" {
                    if let selector {
                        self.respondElementNotFound(
                            id: id, actionName: "scroll", selector: selector,
                            attempts: 1, target: target, respond: respond
                        )
                    } else {
                        respond(self.baError(
                            id: id, code: "not_found", message: "Element not found",
                            data: ["selector": selector ?? ""]
                        ))
                    }
                    return
                }
                self.appendPostSnapshot(params: params, target: target, payload: target.refPayload) { merged in
                    respond(self.baOk(id: id, result: merged))
                }
            }
        }
    }

    func v2BrowserGetCount(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let selectorRaw = selectorParam(params) else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing selector"))
        }
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        guard let selector = BrowserElementRefs.shared.resolve(selectorRaw, surfaceId: target.surfaceId) else {
            return respond(baError(
                id: id, code: "not_found", message: "Element reference not found",
                data: ["selector": selectorRaw]
            ))
        }
        let script = "document.querySelectorAll(\(BrowserJS.jsonLiteral(selector))).length"
        runTargetJS(target, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message))
            case .success(let value):
                var payload = target.refPayload
                payload["count"] = (value as? NSNumber)?.intValue ?? (value as? Int) ?? 0
                respond(self.baOk(id: id, result: payload))
            }
        }
    }

    // MARK: screenshot

    func v2BrowserScreenshot(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        // WebKitGTK can only snapshot a mapped web view; surfaces in
        // never-shown background workspaces are unmapped (GtkStack doesn't
        // allocate them) and get_snapshot fails with a localized GError.
        // Fail early with a stable message instead (dogfood cycle 5).
        let widget = UnsafeMutableRawPointer(target.webView).assumingMemoryBound(to: GtkWidget.self)
        guard gtk_widget_get_mapped(widget) != 0 else {
            return respond(baError(
                id: id, code: "invalid_state",
                message: "Browser surface is not visible (background workspace); select its workspace once to enable screenshots",
                data: ["surface_id": target.surfaceId.uuidString]
            ))
        }
        let box = Unmanaged.passRetained(SnapshotCallbackBox(webView: target.webView) { png, errorMessage in
            guard let png else {
                respond(self.baError(
                    id: id, code: "internal_error",
                    message: errorMessage ?? "Failed to capture snapshot"
                ))
                return
            }
            var payload = target.refPayload
            payload["png_base64"] = png
            respond(self.baOk(id: id, result: payload))
        }).toOpaque()
        // Default is the visible viewport (what the human sees, and what
        // macOS's WKSnapshotConfiguration does). `full_page` captures the
        // whole document instead — on a page laid out wider or taller than
        // the pane, the viewport shot silently cuts content off mid-word,
        // which is invisible in the result unless you knew to expect it.
        let region = boolParam(params, "full_page") == true
            ? WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT
            : WEBKIT_SNAPSHOT_REGION_VISIBLE
        webkit_web_view_get_snapshot(
            target.webView,
            region,
            WEBKIT_SNAPSHOT_OPTIONS_NONE,
            nil,
            { _, result, userData in
                guard let userData else { return }
                let box = Unmanaged<SnapshotCallbackBox>.fromOpaque(userData).takeRetainedValue()
                finishBrowserSnapshot(box: box, result: result)
            },
            box
        )
    }

    // MARK: find.* locators

    func v2BrowserFindVerb(method: String, id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        switch method {
        case "browser.find.role":
            guard let role = (stringParam(params, "role") ?? stringParam(params, "value"))?.lowercased() else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing role"))
            }
            let name = stringParam(params, "name")?.lowercased()
            let exact = boolParam(params, "exact") ?? false
            let roleLiteral = BrowserJS.jsonLiteral(role)
            let nameLiteral = name.map(BrowserJS.jsonLiteral) ?? "null"
            let exactLiteral = exact ? "true" : "false"
            let finder = """
                    const __targetRole = String(\(roleLiteral)).toLowerCase();
                    const __targetName = \(nameLiteral);
                    const __exact = \(exactLiteral);
                    const __implicitRole = (el) => {
                      const tag = String(el.tagName || '').toLowerCase();
                      if (tag === 'button') return 'button';
                      if (tag === 'a' && el.hasAttribute('href')) return 'link';
                      if (tag === 'input') {
                        const type = String(el.getAttribute('type') || 'text').toLowerCase();
                        if (type === 'checkbox') return 'checkbox';
                        if (type === 'radio') return 'radio';
                        if (type === 'submit' || type === 'button') return 'button';
                        return 'textbox';
                      }
                      if (tag === 'textarea') return 'textbox';
                      if (tag === 'select') return 'combobox';
                      return null;
                    };
                    const __nameFor = (el) => {
                      const aria = String(el.getAttribute('aria-label') || '').trim();
                      if (aria) return aria.toLowerCase();
                      const labelledBy = String(el.getAttribute('aria-labelledby') || '').trim();
                      if (labelledBy) {
                        const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => String(n.textContent || '').trim()).join(' ').trim();
                        if (text) return text.toLowerCase();
                      }
                      const txt = String(el.innerText || el.textContent || '').trim();
                      if (txt) return txt.toLowerCase();
                      if ('value' in el) {
                        const v = String(el.value || '').trim();
                        if (v) return v.toLowerCase();
                      }
                      return '';
                    };
                    const __nodes = Array.from(document.querySelectorAll('*'));
                    return __nodes.find((el) => {
                      const explicit = String(el.getAttribute('role') || '').toLowerCase();
                      const resolved = explicit || __implicitRole(el) || '';
                      if (resolved !== __targetRole) return false;
                      if (__targetName == null) return true;
                      const currentName = __nameFor(el);
                      return __exact ? (currentName === __targetName) : currentName.includes(__targetName);
                    }) || null;
            """
            runFindWithScript(
                id: id, params: params, actionName: "find.role", finderBody: finder,
                metadata: [
                    "role": role,
                    "name": name.map { $0 as Any } ?? NSNull(),
                    "exact": exact
                ],
                respond: respond
            )

        case "browser.find.text":
            guard let text = (stringParam(params, "text") ?? stringParam(params, "value"))?.lowercased() else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing text"))
            }
            let exact = boolParam(params, "exact") ?? false
            let textLiteral = BrowserJS.jsonLiteral(text)
            let exactLiteral = exact ? "true" : "false"
            let finder = """
                    const __target = String(\(textLiteral));
                    const __exact = \(exactLiteral);
                    const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                    const __nodes = Array.from(document.querySelectorAll('body *'));
                    return __nodes.find((el) => {
                      const v = __norm(el.innerText || el.textContent || '');
                      if (!v) return false;
                      return __exact ? (v === __target) : v.includes(__target);
                    }) || null;
            """
            runFindWithScript(
                id: id, params: params, actionName: "find.text", finderBody: finder,
                metadata: ["text": text, "exact": exact], respond: respond
            )

        case "browser.find.label":
            guard let label = (stringParam(params, "label") ?? stringParam(params, "text") ?? stringParam(params, "value"))?.lowercased() else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing label"))
            }
            let exact = boolParam(params, "exact") ?? false
            let labelLiteral = BrowserJS.jsonLiteral(label)
            let exactLiteral = exact ? "true" : "false"
            let finder = """
                    const __target = String(\(labelLiteral));
                    const __exact = \(exactLiteral);
                    const __norm = (s) => String(s || '').replace(/\\s+/g, ' ').trim().toLowerCase();
                    const __labels = Array.from(document.querySelectorAll('label'));
                    const __label = __labels.find((el) => {
                      const v = __norm(el.innerText || el.textContent || '');
                      return __exact ? (v === __target) : v.includes(__target);
                    });
                    if (!__label) return null;
                    const htmlFor = String(__label.getAttribute('for') || '').trim();
                    if (htmlFor) {
                      return document.getElementById(htmlFor);
                    }
                    return __label.querySelector('input,textarea,select,button,[contenteditable="true"]');
            """
            runFindWithScript(
                id: id, params: params, actionName: "find.label", finderBody: finder,
                metadata: ["label": label, "exact": exact], respond: respond
            )

        case "browser.find.placeholder", "browser.find.alt", "browser.find.title":
            let attr = String(method.dropFirst("browser.find.".count))
            guard let value = (stringParam(params, attr) ?? stringParam(params, "text") ?? stringParam(params, "value"))?.lowercased() else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing \(attr)"))
            }
            let exact = boolParam(params, "exact") ?? false
            let valueLiteral = BrowserJS.jsonLiteral(value)
            let exactLiteral = exact ? "true" : "false"
            let finder = """
                    const __target = String(\(valueLiteral));
                    const __exact = \(exactLiteral);
                    const __nodes = Array.from(document.querySelectorAll('[\(attr)]'));
                    return __nodes.find((el) => {
                      const a = String(el.getAttribute('\(attr)') || '').trim().toLowerCase();
                      if (!a) return false;
                      return __exact ? (a === __target) : a.includes(__target);
                    }) || null;
            """
            runFindWithScript(
                id: id, params: params, actionName: "find.\(attr)", finderBody: finder,
                metadata: [attr: value, "exact": exact], respond: respond
            )

        case "browser.find.testid":
            guard let testId = stringParam(params, "testid") ?? stringParam(params, "test_id") ?? stringParam(params, "value") else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing testid"))
            }
            let testIdLiteral = BrowserJS.jsonLiteral(testId)
            let finder = """
                    const __target = String(\(testIdLiteral));
                    const __selectors = ['[data-testid]', '[data-test-id]', '[data-test]'];
                    for (const sel of __selectors) {
                      const nodes = Array.from(document.querySelectorAll(sel));
                      const found = nodes.find((el) => {
                        return String(el.getAttribute('data-testid') || el.getAttribute('data-test-id') || el.getAttribute('data-test') || '') === __target;
                      });
                      if (found) return found;
                    }
                    return null;
            """
            runFindWithScript(
                id: id, params: params, actionName: "find.testid", finderBody: finder,
                metadata: ["testid": testId], respond: respond
            )

        case "browser.find.first", "browser.find.last":
            v2BrowserFindByIndex(
                id: id, params: params,
                index: method == "browser.find.first" ? 0 : -1,
                indexInPayload: false, respond: respond
            )

        case "browser.find.nth":
            guard let index = intParam(params, "index") ?? intParam(params, "nth") else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing index"))
            }
            v2BrowserFindByIndex(
                id: id, params: params, index: index,
                indexInPayload: true, respond: respond
            )

        default:
            respond(baError(id: id, code: "unknown_method", message: "Unknown browser verb: \(method)"))
        }
    }

    /// Shared locator machinery — the macOS `v2BrowserFindWithScript`:
    /// `finderBody` returns an element (or null); its CSS path is allocated
    /// as an element ref.
    private func runFindWithScript(
        id: Any?,
        params: [String: Any],
        actionName: String,
        finderBody: String,
        metadata: [String: Any],
        respond: @escaping (String) -> Void
    ) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let script = """
        (() => {
        \(cssPathJSHelper)

          const __cmuxFound = (() => {
        \(finderBody)
          })();
          if (!__cmuxFound) return { ok: false, error: 'not_found' };
          const selector = __cmuxCssPath(__cmuxFound);
          if (!selector) return { ok: false, error: 'not_found' };
          return {
            ok: true,
            selector,
            tag: String(__cmuxFound.tagName || '').toLowerCase(),
            text: String(__cmuxFound.textContent || '').trim()
          };
        })()
        """

        runTargetJS(target, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message, data: ["action": actionName]))
            case .success(let value):
                guard let dict = value as? [String: Any],
                      self.boolValue(dict["ok"]) == true,
                      let selector = dict["selector"] as? String,
                      !selector.isEmpty else {
                    respond(self.baError(id: id, code: "not_found", message: "Element not found", data: metadata))
                    return
                }
                let ref = BrowserElementRefs.shared.allocate(surfaceId: target.surfaceId, selector: selector)
                var payload = target.refPayload
                payload["action"] = actionName
                payload["selector"] = selector
                payload["element_ref"] = ref
                payload["ref"] = ref
                for (key, value) in metadata {
                    payload[key] = value
                }
                if let tag = dict["tag"] as? String {
                    payload["tag"] = tag
                }
                if let text = dict["text"] as? String {
                    payload["text"] = text
                }
                respond(self.baOk(id: id, result: payload))
            }
        }
    }

    /// find.first / find.last / find.nth — list-position locators. Index 0
    /// keeps the caller's selector (macOS find.first); other indexes append
    /// `:nth-of-type` like the macOS find.last/nth handlers.
    private func v2BrowserFindByIndex(
        id: Any?,
        params: [String: Any],
        index: Int,
        indexInPayload: Bool,
        respond: @escaping (String) -> Void
    ) {
        guard let selectorRaw = selectorParam(params) else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing selector"))
        }
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        guard let selector = BrowserElementRefs.shared.resolve(selectorRaw, surfaceId: target.surfaceId) else {
            return respond(baError(
                id: id, code: "not_found", message: "Element reference not found",
                data: ["selector": selectorRaw]
            ))
        }
        let selectorLiteral = BrowserJS.jsonLiteral(selector)
        let script: String
        if index == 0 && !indexInPayload {
            script = """
            (() => {
              const el = document.querySelector(\(selectorLiteral));
              if (!el) return { ok: false, error: 'not_found' };
              return { ok: true, selector: \(selectorLiteral), text: String(el.textContent || '').trim() };
            })()
            """
        } else {
            // Deviation from macOS, which returns `${selector}:nth-of-type(n)`
            // — :nth-of-type counts per-parent/per-tag, so for matches spread
            // across parents that selector points at a DIFFERENT element than
            // the one found. Return the element's own CSS path instead.
            script = """
            (() => {
            \(cssPathJSHelper)
              const list = Array.from(document.querySelectorAll(\(selectorLiteral)));
              if (!list.length) return { ok: false, error: 'not_found' };
              let idx = \(index);
              if (idx < 0) idx = list.length + idx;
              if (idx < 0 || idx >= list.length) return { ok: false, error: 'not_found' };
              const el = list[idx];
              const finalSelector = __cmuxCssPath(el) || `${\(selectorLiteral)}:nth-of-type(${idx + 1})`;
              return { ok: true, selector: finalSelector, index: idx, text: String(el.textContent || '').trim() };
            })()
            """
        }
        runTargetJS(target, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message))
            case .success(let value):
                guard let dict = value as? [String: Any],
                      self.boolValue(dict["ok"]) == true,
                      let finalSelector = dict["selector"] as? String,
                      !finalSelector.isEmpty else {
                    var data: [String: Any] = ["selector": selector]
                    if indexInPayload { data["index"] = index }
                    respond(self.baError(id: id, code: "not_found", message: "Element not found", data: data))
                    return
                }
                let ref = BrowserElementRefs.shared.allocate(surfaceId: target.surfaceId, selector: finalSelector)
                var payload = target.refPayload
                payload["selector"] = finalSelector
                payload["element_ref"] = ref
                payload["ref"] = ref
                payload["text"] = dict["text"] ?? NSNull()
                if indexInPayload {
                    payload["index"] = dict["index"] ?? NSNull()
                }
                respond(self.baOk(id: id, result: payload))
            }
        }
    }

    // MARK: frame selection

    func v2BrowserFrameSelect(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let selectorRaw = selectorParam(params) else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing selector"))
        }
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        guard let selector = BrowserElementRefs.shared.resolve(selectorRaw, surfaceId: target.surfaceId) else {
            return respond(baError(
                id: id, code: "not_found", message: "Element reference not found",
                data: ["selector": selectorRaw]
            ))
        }
        let selectorLiteral = BrowserJS.jsonLiteral(selector)
        let script = """
        (() => {
          const frame = document.querySelector(\(selectorLiteral));
          if (!frame) return { ok: false, error: 'not_found' };
          if (!('contentDocument' in frame)) return { ok: false, error: 'not_frame' };
          try {
            const sameOrigin = !!frame.contentDocument;
            if (!sameOrigin) return { ok: false, error: 'cross_origin' };
          } catch (_) {
            return { ok: false, error: 'cross_origin' };
          }
          return { ok: true };
        })()
        """
        // Deviation from macOS: validation runs against the TOP document,
        // not the currently selected frame — the run-time prelude resolves
        // the stored selector top-relative, so validating inside the old
        // frame would accept selectors that later fail (and reject valid
        // ones when switching directly between sibling iframes).
        BrowserJS.run(target.webView, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message))
            case .success(let value):
                let dict = value as? [String: Any]
                if let dict, self.boolValue(dict["ok"]) == true {
                    BrowserFrameSelectors.shared.set(selector, for: target.surfaceId)
                    var payload = target.refPayload
                    payload["frame_selector"] = selector
                    respond(self.baOk(id: id, result: payload))
                    return
                }
                if let dict, (dict["error"] as? String) == "cross_origin" {
                    respond(self.baError(
                        id: id, code: "not_supported",
                        message: "Cross-origin iframe control is not supported",
                        data: ["selector": selector]
                    ))
                    return
                }
                respond(self.baError(
                    id: id, code: "not_found", message: "Frame not found",
                    data: ["selector": selector]
                ))
            }
        }
    }

    func v2BrowserFrameMain(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        BrowserFrameSelectors.shared.clear(for: target.surfaceId)
        var payload = target.refPayload
        payload["frame_selector"] = NSNull()
        respond(baOk(id: id, result: payload))
    }

    // MARK: dialogs

    func v2BrowserDialogRespond(id: Any?, params: [String: Any], accept: Bool, respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let text = stringParam(params, "text") ?? stringParam(params, "prompt_text")
        let acceptLiteral = accept ? "true" : "false"
        let textLiteral = text.map(BrowserJS.jsonLiteral) ?? "null"
        // Hooks and queue live in the TOP window regardless of frame
        // selection — same as macOS, which uses the non-frame runner here.
        // The (idempotent) hook install is prepended to the queue-shift
        // script so one JS round-trip arms and answers.
        let script = """
        \(browserDialogHookScript);
        (() => {
          const q = window.__cmuxDialogQueue || [];
          if (!q.length) return { ok: false, error: 'not_found' };
          const entry = q.shift();
          if (entry.type === 'confirm') {
            window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
            window.__cmuxDialogDefaults.confirm = \(acceptLiteral);
          }
          if (entry.type === 'prompt') {
            window.__cmuxDialogDefaults = window.__cmuxDialogDefaults || { confirm: false, prompt: null };
            if (\(acceptLiteral)) {
              window.__cmuxDialogDefaults.prompt = \(textLiteral);
            } else {
              window.__cmuxDialogDefaults.prompt = null;
            }
          }
          return { ok: true, dialog: entry, remaining: q.length };
        })()
        """
        BrowserJS.run(target.webView, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message))
            case .success(let value):
                guard let dict = value as? [String: Any],
                      self.boolValue(dict["ok"]) == true else {
                    // The shift script just proved the queue empty, so the
                    // macOS `pending` diagnostic list is always [] here.
                    respond(self.baError(
                        id: id, code: "not_found", message: "No pending dialog",
                        data: ["pending": [Any]()]
                    ))
                    return
                }
                var payload = target.refPayload
                payload["accepted"] = accept
                payload["dialog"] = dict["dialog"] ?? NSNull()
                payload["remaining"] = dict["remaining"] ?? NSNull()
                respond(self.baOk(id: id, result: payload))
            }
        }
    }

    // MARK: storage

    func v2BrowserStorageVerb(method: String, id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        let rawType = (stringParam(params, "storage") ?? stringParam(params, "type") ?? "local").lowercased()
        let storageType = rawType == "session" ? "session" : "local"
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let typeLiteral = BrowserJS.jsonLiteral(storageType)

        let script: String
        var resultExtras: [String: Any] = ["type": storageType]
        var wantsValue = false

        switch method {
        case "browser.storage.get":
            let key = stringParam(params, "key")
            let keyLiteral = key.map(BrowserJS.jsonLiteral) ?? "null"
            resultExtras["key"] = key.map { $0 as Any } ?? NSNull()
            wantsValue = true
            script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = \(keyLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              if (key == null) {
                const out = {};
                for (let i = 0; i < st.length; i++) {
                  const k = st.key(i);
                  out[k] = st.getItem(k);
                }
                return { ok: true, value: out };
              }
              return { ok: true, value: st.getItem(String(key)) };
            })()
            """
        case "browser.storage.set":
            guard let key = stringParam(params, "key") else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing key"))
            }
            guard let value = params["value"] else {
                return respond(baError(id: id, code: "invalid_params", message: "Missing value"))
            }
            resultExtras["key"] = key
            let keyLiteral = BrowserJS.jsonLiteral(key)
            let valueLiteral = BrowserJS.jsonLiteral(value)
            script = """
            (() => {
              const type = String(\(typeLiteral));
              const key = String(\(keyLiteral));
              const value = \(valueLiteral);
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.setItem(key, value == null ? '' : String(value));
              return { ok: true };
            })()
            """
        default: // browser.storage.clear
            script = """
            (() => {
              const type = String(\(typeLiteral));
              const st = type === 'session' ? window.sessionStorage : window.localStorage;
              if (!st) return { ok: false, error: 'not_available' };
              st.clear();
              return { ok: true };
            })()
            """
        }

        runTargetJS(target, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                respond(self.baError(id: id, code: "js_error", message: message))
            case .success(let value):
                guard let dict = value as? [String: Any],
                      self.boolValue(dict["ok"]) == true else {
                    respond(self.baError(
                        id: id, code: "invalid_state", message: "Storage unavailable",
                        data: ["type": storageType]
                    ))
                    return
                }
                var payload = target.refPayload
                payload.merge(resultExtras) { _, new in new }
                if wantsValue {
                    payload["value"] = dict["value"] ?? NSNull()
                }
                respond(self.baOk(id: id, result: payload))
            }
        }
    }

    // MARK: console / errors telemetry

    func v2BrowserTelemetryVerb(method: String, id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let isErrors = method == "browser.errors.list"
        let clear = method == "browser.console.clear" || (boolParam(params, "clear") ?? false)
        let entriesKey = isErrors ? "errors" : "entries"

        // Capture v2: entries stream in from the document-start user
        // script (CSP-exempt, active since page load) into an app-side
        // ring buffer — no JS round-trip, and no strict-CSP blind spot.
        let store = BrowserConsoleLog.shared
        let items = store.entries(for: target.surfaceId, isErrors: isErrors)
        if clear {
            store.clear(for: target.surfaceId, isErrors: isErrors)
        }
        var payload = target.refPayload
        payload[entriesKey] = items
        payload["count"] = items.count
        respond(baOk(id: id, result: payload))
    }

    // MARK: download wait

    func v2BrowserDownloadWait(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        let timeoutMs = max(1, intParam(params, "timeout_ms") ?? intParam(params, "timeout") ?? 10_000)
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)

        guard let path = stringParam(params, "path") else {
            // macOS's no-path branch polls a download-event queue that
            // nothing ever populates (no writer exists) — so it always
            // times out. Matched here without the busywork.
            scheduleOnMainLoop(afterMs: UInt32(timeoutMs)) {
                respond(self.baError(
                    id: id, code: "timeout", message: "No download event observed",
                    data: ["timeout_ms": timeoutMs]
                ))
            }
            return
        }

        func poll() {
            let fm = FileManager.default
            if fm.fileExists(atPath: path),
               let attrs = try? fm.attributesOfItem(atPath: path),
               let size = attrs[.size] as? NSNumber,
               size.intValue > 0 {
                var payload = target.refPayload
                payload["path"] = path
                payload["downloaded"] = true
                respond(self.baOk(id: id, result: payload))
                return
            }
            guard Date() < deadline else {
                respond(self.baError(
                    id: id, code: "timeout", message: "Timed out waiting for download file",
                    data: ["path": path, "timeout_ms": timeoutMs]
                ))
                return
            }
            scheduleOnMainLoop(afterMs: 50) { poll() }
        }
        poll()
    }

    // MARK: cookies

    func v2BrowserCookiesGet(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        guard let manager = cookieManager(for: target) else {
            return respond(baError(id: id, code: "internal_error", message: "Cookie manager unavailable"))
        }
        let name = stringParam(params, "name")
        let domain = stringParam(params, "domain")
        let path = stringParam(params, "path")
        fetchAllCookies(manager: manager) { cookies, errorMessage in
            guard let cookies else {
                respond(self.baError(
                    id: id, code: "internal_error",
                    message: errorMessage ?? "Failed to read cookies"
                ))
                return
            }
            var rows: [[String: Any]] = []
            for cookie in cookies {
                let dict = soupCookieDict(cookie)
                soup_cookie_free(cookie)
                if let name, (dict["name"] as? String) != name { continue }
                if let domain, !((dict["domain"] as? String) ?? "").contains(domain) { continue }
                if let path, (dict["path"] as? String) != path { continue }
                rows.append(dict)
            }
            var payload = target.refPayload
            payload["cookies"] = rows
            respond(self.baOk(id: id, result: payload))
        }
    }

    func v2BrowserCookiesSet(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        guard let manager = cookieManager(for: target) else {
            return respond(baError(id: id, code: "internal_error", message: "Cookie manager unavailable"))
        }
        let fallbackHost = SurfaceRegistry.shared.currentURL(for: target.surfaceId)
            .flatMap { URL(string: $0)?.host }

        var cookieObjects: [[String: Any]] = []
        if let rows = params["cookies"] as? [[String: Any]] {
            cookieObjects = rows
        } else {
            var single: [String: Any] = [:]
            if let name = stringParam(params, "name") { single["name"] = name }
            if let value = params["value"] as? String { single["value"] = value }
            if let url = stringParam(params, "url") { single["url"] = url }
            if let domain = stringParam(params, "domain") { single["domain"] = domain }
            if let path = stringParam(params, "path") { single["path"] = path }
            if let secure = boolParam(params, "secure") { single["secure"] = secure }
            if let expires = intParam(params, "expires") { single["expires"] = expires }
            if !single.isEmpty {
                cookieObjects = [single]
            }
        }

        guard !cookieObjects.isEmpty else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing cookies payload"))
        }

        var built: [OpaquePointer] = []
        for raw in cookieObjects {
            guard let cookie = makeSoupCookie(raw, fallbackHost: fallbackHost) else {
                for cookie in built { soup_cookie_free(cookie) }
                return respond(baError(
                    id: id, code: "invalid_params", message: "Invalid cookie payload",
                    data: ["cookie": raw]
                ))
            }
            built.append(cookie)
        }

        cookieChainStep(CookieChainBox(manager: manager, cookies: built, isDelete: false) { succeeded, errorMessage in
            if let errorMessage {
                respond(self.baError(id: id, code: "internal_error", message: errorMessage))
                return
            }
            var payload = target.refPayload
            payload["set"] = succeeded
            respond(self.baOk(id: id, result: payload))
        })
    }

    func v2BrowserCookiesClear(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        guard let manager = cookieManager(for: target) else {
            return respond(baError(id: id, code: "internal_error", message: "Cookie manager unavailable"))
        }
        let name = stringParam(params, "name")
        let domain = stringParam(params, "domain")
        // macOS quirk preserved: any explicit name/domain/all narrows the
        // filter below; a bare clear (none of them) removes everything.
        let clearAll = params["all"] == nil && name == nil && domain == nil
        fetchAllCookies(manager: manager) { cookies, errorMessage in
            guard let cookies else {
                respond(self.baError(
                    id: id, code: "internal_error",
                    message: errorMessage ?? "Failed to read cookies"
                ))
                return
            }
            var targets: [OpaquePointer] = []
            for cookie in cookies {
                let cookieName = soup_cookie_get_name(cookie).map { String(cString: $0) } ?? ""
                let cookieDomain = soup_cookie_get_domain(cookie).map { String(cString: $0) } ?? ""
                let matches: Bool = {
                    if clearAll { return true }
                    if let name, cookieName != name { return false }
                    if let domain, !cookieDomain.contains(domain) { return false }
                    return true
                }()
                if matches {
                    targets.append(cookie)
                } else {
                    soup_cookie_free(cookie)
                }
            }
            cookieChainStep(CookieChainBox(manager: manager, cookies: targets, isDelete: true) { succeeded, errorMessage in
                if let errorMessage {
                    respond(self.baError(id: id, code: "internal_error", message: errorMessage))
                    return
                }
                var payload = target.refPayload
                payload["cleared"] = succeeded
                respond(self.baOk(id: id, result: payload))
            })
        }
    }

    // MARK: cookie helpers

    private func cookieManager(for target: AutomationTarget) -> OpaquePointer? {
        guard let session = webkit_web_view_get_network_session(target.webView) else { return nil }
        return webkit_network_session_get_cookie_manager(session)
    }

    private func fetchAllCookies(
        manager: OpaquePointer,
        completion: @escaping ([OpaquePointer]?, String?) -> Void
    ) {
        let box = Unmanaged.passRetained(
            CookieListBox(manager: manager, completion: completion)
        ).toOpaque()
        webkit_cookie_manager_get_all_cookies(
            manager, nil,
            { _, result, userData in
                guard let userData else { return }
                let box = Unmanaged<CookieListBox>.fromOpaque(userData).takeRetainedValue()
                finishCookieList(box: box, result: result)
            },
            box
        )
    }

    /// Wire cookie object → owned SoupCookie (nil = invalid payload, macOS
    /// `v2BrowserCookieFromObject` semantics: name+value required, domain
    /// falls back to the `url` param's host, then the current page host).
    private func makeSoupCookie(_ raw: [String: Any], fallbackHost: String?) -> OpaquePointer? {
        guard let name = raw["name"] as? String, !name.isEmpty,
              let value = raw["value"] as? String else { return nil }
        let urlHost = (raw["url"] as? String).flatMap { URL(string: $0)?.host }
        guard let domain = (raw["domain"] as? String) ?? urlHost ?? fallbackHost, !domain.isEmpty else {
            return nil
        }
        let path = (raw["path"] as? String) ?? "/"
        guard let cookie = soup_cookie_new(name, value, domain, path, -1) else { return nil }
        if boolValue(raw["secure"]) == true {
            soup_cookie_set_secure(cookie, 1)
        }
        if let expires = intParam(raw, "expires"),
           let dateTime = g_date_time_new_from_unix_utc(gint64(expires)) {
            soup_cookie_set_expires(cookie, dateTime)
            g_date_time_unref(dateTime)
        }
        return cookie
    }

    // MARK: selector-action machinery

    private func runSelectorAction(
        id: Any?,
        params: [String: Any],
        actionName: String,
        scriptBuilder: (String) -> String,
        respond: @escaping (String) -> Void
    ) {
        guard let selectorRaw = selectorParam(params) else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing selector"))
        }
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        guard let selector = BrowserElementRefs.shared.resolve(selectorRaw, surfaceId: target.surfaceId) else {
            return respond(baError(
                id: id, code: "not_found", message: "Element reference not found",
                data: ["selector": selectorRaw]
            ))
        }
        let script = scriptBuilder(BrowserJS.jsonLiteral(selector))
        let retryAttempts = max(1, intParam(params, "retry_attempts") ?? 3)

        func attempt(_ number: Int) {
            runTargetJS(target, script: script) { outcome in
                switch outcome {
                case .failure(let message):
                    respond(self.baError(
                        id: id, code: "js_error", message: message,
                        data: ["action": actionName, "selector": selector]
                    ))
                case .success(let value):
                    let dict = value as? [String: Any]
                    if let dict, self.boolValue(dict["ok"]) == true {
                        var payload = target.refPayload
                        payload["action"] = actionName
                        payload["attempts"] = number
                        if let resultValue = dict["value"] {
                            payload["value"] = resultValue
                        }
                        self.appendPostSnapshot(params: params, target: target, payload: payload) { merged in
                            respond(self.baOk(id: id, result: merged))
                        }
                        return
                    }
                    let errorText = dict?["error"] as? String
                    if errorText == "not_found", number < retryAttempts {
                        scheduleOnMainLoop(afterMs: 80) { attempt(number + 1) }
                        return
                    }
                    if errorText == "not_found" {
                        self.respondElementNotFound(
                            id: id, actionName: actionName, selector: selector,
                            attempts: retryAttempts, target: target, respond: respond
                        )
                        return
                    }
                    if errorText == "option_not_found" {
                        respond(self.baError(
                            id: id, code: "invalid_params",
                            message: "No <option> matches the given value",
                            data: ["action": actionName, "selector": selector]
                        ))
                        return
                    }
                    respond(self.baError(
                        id: id, code: "js_error", message: "Browser action failed",
                        data: ["action": actionName, "selector": selector]
                    ))
                }
            }
        }
        attempt(1)
    }

    /// Element-not-found reply with the macOS page diagnostics (match
    /// counts, samples, snapshot hint) gathered by a follow-up script.
    private func respondElementNotFound(
        id: Any?,
        actionName: String,
        selector: String,
        attempts: Int,
        target: AutomationTarget,
        respond: @escaping (String) -> Void
    ) {
        let selectorLiteral = BrowserJS.jsonLiteral(selector)
        let script = """
        (() => {
          const __selector = String(\(selectorLiteral));
          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const __isVisible = (el) => {
            try {
              if (!el) return false;
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              if (!style || !rect) return false;
              if (rect.width <= 0 || rect.height <= 0) return false;
              if (style.display === 'none' || style.visibility === 'hidden') return false;
              if (parseFloat(style.opacity || '1') <= 0.01) return false;
              return true;
            } catch (_) {
              return false;
            }
          };
          const __describe = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            const id = __normalize(el.id || '');
            const klass = __normalize(el.className || '').split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
            let out = tag || 'element';
            if (id) out += '#' + id;
            if (klass) out += '.' + klass;
            return out;
          };
          try {
            const __nodes = Array.from(document.querySelectorAll(__selector));
            const __visible = __nodes.filter(__isVisible);
            const __sample = __nodes.slice(0, 6).map((el, idx) => ({
              index: idx,
              descriptor: __describe(el),
              role: __normalize(el.getAttribute('role') || ''),
              visible: __isVisible(el),
              text: __normalize(el.innerText || el.textContent || '').slice(0, 120)
            }));
            const __snapshotExcerpt = __sample.map((row) => {
              const suffix = row.text ? ` \"${row.text}\"` : '';
              return `- ${row.descriptor}${suffix}`;
            }).join('\\n');
            return {
              ok: true,
              selector: __selector,
              count: __nodes.length,
              visible_count: __visible.length,
              sample: __sample,
              snapshot_excerpt: __snapshotExcerpt,
              title: __normalize(document.title || ''),
              url: String(location.href || ''),
              body_excerpt: document.body ? __normalize(document.body.innerText || '').slice(0, 400) : ''
            };
          } catch (err) {
            return {
              ok: false,
              selector: __selector,
              error: 'invalid_selector',
              details: String((err && err.message) || err || '')
            };
          }
        })()
        """

        runTargetJS(target, script: script) { outcome in
            var data: [String: Any] = ["selector": selector]
            switch outcome {
            case .failure(let message):
                data["diagnostics_error"] = message
            case .success(let value):
                if let dict = value as? [String: Any] {
                    if let count = dict["count"] { data["match_count"] = count }
                    if let visibleCount = dict["visible_count"] { data["visible_match_count"] = visibleCount }
                    if let sample = dict["sample"] { data["sample"] = sample }
                    if let excerpt = dict["snapshot_excerpt"] { data["snapshot_excerpt"] = excerpt }
                    if let body = dict["body_excerpt"] { data["body_excerpt"] = body }
                    if let title = dict["title"] { data["title"] = title }
                    if let url = dict["url"] { data["url"] = url }
                    if let err = dict["error"] { data["diagnostics_code"] = err }
                    if let details = dict["details"] { data["diagnostics_details"] = details }
                }
            }
            data["action"] = actionName
            data["retry_attempts"] = attempts
            data["hint"] = "Run 'browser snapshot' to refresh refs, then retry with a more specific selector."

            let count = (data["match_count"] as? NSNumber)?.intValue ?? (data["match_count"] as? Int) ?? 0
            let visibleCount = (data["visible_match_count"] as? NSNumber)?.intValue ?? (data["visible_match_count"] as? Int) ?? 0
            let message: String
            if count > 0 && visibleCount == 0 {
                message = "Element \"\(selector)\" is present but not visible."
            } else if count > 1 {
                message = "Selector \"\(selector)\" matched multiple elements."
            } else {
                message = "Element \"\(selector)\" not found or not visible. Run 'browser snapshot' to see current page elements."
            }
            respond(self.baError(id: id, code: "not_found", message: message, data: data))
        }
    }

    // MARK: snapshot machinery

    private struct AutomationError: Error {
        let code: String
        let message: String
        var data: [String: Any]?
    }

    /// Accessibility-style page outline: role/name entries with allocated
    /// element refs — same script and post-processing as macOS.
    private func runSnapshot(
        target: AutomationTarget,
        interactive: Bool,
        cursor: Bool,
        compact: Bool,
        maxDepth: Int,
        scopeSelector: String?,
        completion: @escaping (Swift.Result<[String: Any], AutomationError>) -> Void
    ) {
        let interactiveLiteral = interactive ? "true" : "false"
        let cursorLiteral = cursor ? "true" : "false"
        let compactLiteral = compact ? "true" : "false"
        let scopeLiteral = scopeSelector.map(BrowserJS.jsonLiteral) ?? "null"

        let script = """
        (() => {
          const __interactiveOnly = \(interactiveLiteral);
          const __includeCursor = \(cursorLiteral);
          const __compact = \(compactLiteral);
          const __maxDepth = \(maxDepth);
          const __scopeSelector = \(scopeLiteral);

          const __normalize = (s) => String(s || '').replace(/\\s+/g, ' ').trim();
          const __interactiveRoles = new Set(['button','link','textbox','checkbox','radio','combobox','listbox','menuitem','menuitemcheckbox','menuitemradio','option','searchbox','slider','spinbutton','switch','tab','treeitem']);
          const __contentRoles = new Set(['heading','cell','gridcell','columnheader','rowheader','listitem','article','region','main','navigation']);
          const __structuralRoles = new Set(['generic','group','list','table','row','rowgroup','grid','treegrid','menu','menubar','toolbar','tablist','tree','directory','document','application','presentation','none']);

          const __isVisible = (el) => {
            try {
              if (!el) return false;
              const style = getComputedStyle(el);
              const rect = el.getBoundingClientRect();
              if (!style || !rect) return false;
              if (rect.width <= 0 || rect.height <= 0) return false;
              if (style.display === 'none' || style.visibility === 'hidden') return false;
              if (parseFloat(style.opacity || '1') <= 0.01) return false;
              return true;
            } catch (_) {
              return false;
            }
          };

          const __implicitRole = (el) => {
            const tag = String(el.tagName || '').toLowerCase();
            if (tag === 'button') return 'button';
            if (tag === 'a' && el.hasAttribute('href')) return 'link';
            if (tag === 'input') {
              const type = String(el.getAttribute('type') || 'text').toLowerCase();
              if (type === 'checkbox') return 'checkbox';
              if (type === 'radio') return 'radio';
              if (type === 'submit' || type === 'button' || type === 'reset') return 'button';
              return 'textbox';
            }
            if (tag === 'textarea') return 'textbox';
            if (tag === 'select') return 'combobox';
            if (tag === 'summary') return 'button';
            if (tag === 'h1' || tag === 'h2' || tag === 'h3' || tag === 'h4' || tag === 'h5' || tag === 'h6') return 'heading';
            if (tag === 'li') return 'listitem';
            return null;
          };

          const __nameFor = (el) => {
            const aria = __normalize(el.getAttribute('aria-label') || '');
            if (aria) return aria;
            const labelledBy = __normalize(el.getAttribute('aria-labelledby') || '');
            if (labelledBy) {
              const text = labelledBy.split(/\\s+/).map((id) => document.getElementById(id)).filter(Boolean).map((n) => __normalize(n.textContent || '')).join(' ').trim();
              if (text) return text;
            }
            if (el.id) {
              const label = document.querySelector('label[for="' + CSS.escape(el.id) + '"]');
              if (label) {
                const text = __normalize(label.textContent || '');
                if (text) return text;
              }
            }
            if (el.closest) {
              const wrapping = el.closest('label');
              if (wrapping) {
                const text = __normalize(wrapping.textContent || '');
                if (text) return text;
              }
            }
            if (el.tagName && String(el.tagName).toLowerCase() === 'input') {
              const placeholder = __normalize(el.getAttribute('placeholder') || '');
              if (placeholder) return placeholder;
              const value = __normalize(el.value || '');
              if (value) return value;
            }
            const title = __normalize(el.getAttribute('title') || '');
            if (title) return title;
            const text = __normalize(el.innerText || el.textContent || '');
            if (text) return text.slice(0, 120);
            return '';
          };

          const __cssPath = (el) => {
            if (!el || el.nodeType !== 1) return null;
            if (el.id) return '#' + CSS.escape(el.id);
            const parts = [];
            let cur = el;
            while (cur && cur.nodeType === 1) {
              let part = String(cur.tagName || '').toLowerCase();
              if (!part) break;
              if (cur.id) {
                part += '#' + CSS.escape(cur.id);
                parts.unshift(part);
                break;
              }
              const tag = part;
              const parent = cur.parentElement;
              if (parent) {
                const siblings = Array.from(parent.children).filter((n) => String(n.tagName || '').toLowerCase() === tag);
                if (siblings.length > 1) {
                  const index = siblings.indexOf(cur) + 1;
                  part += `:nth-of-type(${index})`;
                }
              }
              parts.unshift(part);
              cur = cur.parentElement;
              if (parts.length >= 6) break;
            }
            return parts.join(' > ');
          };

          const __root = (() => {
            if (__scopeSelector) {
              return document.querySelector(__scopeSelector) || document.body || document.documentElement;
            }
            return document.body || document.documentElement;
          })();

          const __entries = [];
          const __seen = new Set();
          const __appendEntry = (el, depth, forcedRole) => {
            if (!__isVisible(el)) return;
            const explicitRole = __normalize(el.getAttribute('role') || '').toLowerCase();
            const role = forcedRole || explicitRole || __implicitRole(el) || '';
            if (!role) return;

            if (__interactiveOnly && !__interactiveRoles.has(role)) return;
            if (!__interactiveOnly) {
              const includeRole = __interactiveRoles.has(role) || __contentRoles.has(role);
              if (!includeRole) return;
              if (__compact && __structuralRoles.has(role)) {
                const name = __nameFor(el);
                if (!name) return;
              }
            }

            const selector = __cssPath(el);
            if (!selector || __seen.has(selector)) return;
            __seen.add(selector);
            __entries.push({
              selector,
              role,
              name: __nameFor(el),
              depth
            });
          };

          const __walk = (node, depth) => {
            if (!node || depth > __maxDepth || node.nodeType !== 1) return;
            const el = node;
            __appendEntry(el, depth, null);
            for (const child of Array.from(el.children || [])) {
              __walk(child, depth + 1);
            }
          };

          if (__root) {
            __walk(__root, 0);
          }

          if (__includeCursor && __root) {
            const all = Array.from(__root.querySelectorAll('*'));
            for (const el of all) {
              if (!__isVisible(el)) continue;
              const style = getComputedStyle(el);
              const hasOnClick = typeof el.onclick === 'function' || el.hasAttribute('onclick');
              const hasCursorPointer = style.cursor === 'pointer';
              const tabIndex = el.getAttribute('tabindex');
              const hasTabIndex = tabIndex != null && String(tabIndex) !== '-1';
              if (!hasOnClick && !hasCursorPointer && !hasTabIndex) continue;
              __appendEntry(el, 0, 'generic');
              if (__entries.length >= 256) break;
            }
          }

          const body = document.body;
          const root = document.documentElement;
          return {
            title: __normalize(document.title || ''),
            url: String(location.href || ''),
            ready_state: String(document.readyState || ''),
            text: body ? String(body.innerText || '') : '',
            html: root ? String(root.outerHTML || '') : '',
            entries: __entries
          };
        })()
        """

        runTargetJS(target, script: script) { outcome in
            switch outcome {
            case .failure(let message):
                completion(.failure(AutomationError(code: "js_error", message: message, data: nil)))
            case .success(let value):
                guard let dict = value as? [String: Any] else {
                    completion(.failure(AutomationError(code: "js_error", message: "Invalid snapshot payload", data: nil)))
                    return
                }

                let title = (dict["title"] as? String) ?? ""
                let url = (dict["url"] as? String) ?? ""
                let readyState = (dict["ready_state"] as? String) ?? ""
                let text = (dict["text"] as? String) ?? ""
                let html = (dict["html"] as? String) ?? ""
                let entries = (dict["entries"] as? [[String: Any]]) ?? []

                var refs: [String: [String: Any]] = [:]
                var treeLines: [String] = []
                var seenSelectors: Set<String> = []

                for entry in entries {
                    guard let selector = entry["selector"] as? String,
                          !selector.isEmpty,
                          !seenSelectors.contains(selector) else {
                        continue
                    }
                    seenSelectors.insert(selector)

                    let roleRaw = (entry["role"] as? String) ?? "generic"
                    let role = roleRaw.isEmpty ? "generic" : roleRaw
                    let name = ((entry["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let depth = max(0, (entry["depth"] as? NSNumber)?.intValue ?? (entry["depth"] as? Int) ?? 0)

                    let refToken = BrowserElementRefs.shared.allocate(
                        surfaceId: target.surfaceId, selector: selector
                    )
                    let shortRef = refToken.hasPrefix("@") ? String(refToken.dropFirst()) : refToken

                    var refInfo: [String: Any] = ["role": role]
                    if !name.isEmpty {
                        refInfo["name"] = name
                    }
                    refs[shortRef] = refInfo

                    let indent = String(repeating: "  ", count: depth)
                    var line = "\(indent)- \(role)"
                    if !name.isEmpty {
                        let cleanName = name.replacingOccurrences(of: "\"", with: "'")
                        line += " \"\(cleanName)\""
                    }
                    line += " [ref=\(shortRef)]"
                    treeLines.append(line)
                }

                let titleForTree = title.isEmpty ? "page" : title.replacingOccurrences(of: "\"", with: "'")
                var snapshotLines = ["- document \"\(titleForTree)\""]
                if !treeLines.isEmpty {
                    snapshotLines.append(contentsOf: treeLines)
                } else {
                    let excerpt = text
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "\t", with: " ")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if !excerpt.isEmpty {
                        let clipped = String(excerpt.prefix(240)).replacingOccurrences(of: "\"", with: "'")
                        snapshotLines.append("- text \"\(clipped)\"")
                    } else {
                        snapshotLines.append("- (empty)")
                    }
                }

                var payload: [String: Any] = [
                    "snapshot": snapshotLines.joined(separator: "\n"),
                    "title": title,
                    "url": url,
                    "ready_state": readyState,
                    "page": [
                        "title": title,
                        "url": url,
                        "ready_state": readyState,
                        "text": text,
                        "html": html
                    ]
                ]
                if !refs.isEmpty {
                    payload["refs"] = refs
                }
                completion(.success(payload))
            }
        }
    }

    /// `snapshot_after` support: merge a fresh snapshot into an action's
    /// payload (macOS `v2BrowserAppendPostSnapshot`).
    private func appendPostSnapshot(
        params: [String: Any],
        target: AutomationTarget,
        payload: [String: Any],
        completion: @escaping ([String: Any]) -> Void
    ) {
        guard boolParam(params, "snapshot_after") ?? false else {
            return completion(payload)
        }
        let interactive = boolParam(params, "snapshot_interactive") ?? true
        let cursor = boolParam(params, "snapshot_cursor") ?? false
        let compact = boolParam(params, "snapshot_compact") ?? true
        let depthParam: Int = intParam(params, "snapshot_max_depth") ?? 10
        let maxDepth = max(0, depthParam)
        let scopeSelector = stringParam(params, "snapshot_selector")
        runSnapshot(
            target: target,
            interactive: interactive,
            cursor: cursor,
            compact: compact,
            maxDepth: maxDepth,
            scopeSelector: scopeSelector
        ) { result in
            var merged = payload
            switch result {
            case .success(let snapshot):
                if let value = snapshot["snapshot"] { merged["post_action_snapshot"] = value }
                if let value = snapshot["refs"] { merged["post_action_refs"] = value }
                if let value = snapshot["title"] { merged["post_action_title"] = value }
                if let value = snapshot["url"] { merged["post_action_url"] = value }
            case .failure(let error):
                merged["post_action_snapshot_error"] = [
                    "code": error.code,
                    "message": error.message
                ]
            }
            completion(merged)
        }
    }

    // MARK: param + target helpers

    /// Resolves the target browser surface: explicit `surface_id` (UUID or
    /// handle ref), else the resolved workspace's focused surface — and it
    /// must be registered as a browser.
    private func automationTarget(_ params: [String: Any]) -> AutomationTarget? {
        let resolved: (tab: TerminalTab, surfaceId: UUID)?
        if let raw = params["surface_id"] as? String, !raw.isEmpty {
            guard let uuid = UUID(uuidString: raw) ?? RefRegistry.shared.resolve(raw),
                  let tab = tabs.wrappedValue.first(where: { $0.contains(surfaceId: uuid) }) else {
                return nil
            }
            resolved = (tab, uuid)
        } else {
            let wsId = (params["workspace_id"] as? String).flatMap {
                UUID(uuidString: $0) ?? RefRegistry.shared.resolve($0)
            } ?? selection.wrappedValue
            guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }),
                  let focused = tab.focusedSurface else { return nil }
            resolved = (tab, focused.surfaceId)
        }
        guard let resolved,
              let pointer = SurfaceRegistry.shared.browser(for: resolved.surfaceId) else {
            return nil
        }
        return AutomationTarget(
            tab: resolved.tab,
            surfaceId: resolved.surfaceId,
            webView: UnsafeMutablePointer<WebKitWebView>(pointer)
        )
    }

    private func selectorParam(_ params: [String: Any]) -> String? {
        stringParam(params, "selector")
            ?? stringParam(params, "sel")
            ?? stringParam(params, "element_ref")
            ?? stringParam(params, "ref")
    }

    private func stringParam(_ params: [String: Any], _ key: String) -> String? {
        guard let value = params[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Unlike `stringParam`, keeps empty strings (fill "" clears an input).
    private func rawStringParam(_ params: [String: Any], _ key: String) -> String? {
        params[key] as? String
    }

    private func intParam(_ params: [String: Any], _ key: String) -> Int? {
        if let value = params[key] as? Int { return value }
        if let value = params[key] as? NSNumber { return value.intValue }
        return nil
    }

    private func boolParam(_ params: [String: Any], _ key: String) -> Bool? {
        boolValue(params[key])
    }

    /// JSON booleans arrive as Bool or NSNumber depending on the decoder.
    private func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    // MARK: envelope helpers (file-scoped like the other extensions)

    private func baOk(id: Any?, result: [String: Any]) -> String {
        baEncode(["id": id ?? NSNull(), "ok": true, "result": result])
    }

    private func baError(id: Any?, code: String, message: String, data: [String: Any]? = nil) -> String {
        var error: [String: Any] = ["code": code, "message": message]
        if let data {
            error["data"] = data
        }
        return baEncode(["id": id ?? NSNull(), "ok": false, "error": error])
    }

    private func baEncode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }
        return string.replacingOccurrences(of: "\n", with: "\\n")
    }
}
