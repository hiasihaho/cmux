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

// MARK: - async JS bridge

enum BrowserJSOutcome {
    /// JSON-decoded value: Dictionary/Array/String/NSNumber/NSNull.
    case success(Any)
    case failure(String)
}

enum BrowserJS {

    /// Runs `script` inside the same envelope the macOS port uses: promises
    /// are awaited, exceptions surface as `.failure`, and `undefined` is
    /// distinguished from `null` via the `__cmux_t` marker. The completion
    /// fires on the GLib main loop.
    static func run(
        _ webView: UnsafeMutablePointer<WebKitWebView>,
        script: String,
        completion: @escaping (BrowserJSOutcome) -> Void
    ) {
        let scriptLiteral = jsonLiteral(script)
        // Function body for call_async_javascript_function (an implicit
        // async function, so `await`/`return` are valid) — the GTK analog
        // of WKWebView.callAsyncJavaScript, same envelope as macOS.
        let body = """
        const __cmuxMaybeAwait = async (__r) => {
          if (__r !== null && (typeof __r === 'object' || typeof __r === 'function') && typeof __r.then === 'function') {
            return await __r;
          }
          return __r;
        };
        const __cmuxEval = async function() {
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

        webkit_web_view_call_async_javascript_function(
            webView, body, -1, nil, nil, nil, nil,
            { _, result, userData in
                guard let userData else { return }
                let box = Unmanaged<JSCallbackBox>.fromOpaque(userData).takeRetainedValue()
                finishBrowserJSCall(box: box, result: result)
            },
            box
        )
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

    func v2BrowserEval(id: Any?, params: [String: Any], respond: @escaping (String) -> Void) {
        guard let script = stringParam(params, "script") else {
            return respond(baError(id: id, code: "invalid_params", message: "Missing script"))
        }
        guard let target = automationTarget(params) else {
            return respond(baError(id: id, code: "not_found", message: "Browser surface not found"))
        }
        BrowserJS.run(target.webView, script: script) { outcome in
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
            BrowserJS.run(target.webView, script: wrapped) { outcome in
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
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  el.scrollIntoView({ block: 'nearest', inline: 'nearest' });
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
            scriptBuilder = { sel in """
                (() => {
                  const el = document.querySelector(\(sel));
                  if (!el) return { ok: false, error: 'not_found' };
                  if (!('value' in el)) return { ok: false, error: 'not_select' };
                  el.value = String(\(valueLiteral));
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
        let events: [String]
        switch method {
        case "browser.keydown": events = ["keydown"]
        case "browser.keyup": events = ["keyup"]
        default: events = ["keydown", "keypress", "keyup"]
        }
        let dispatches = events
            .map { "target.dispatchEvent(new KeyboardEvent('\($0)', { key: k, bubbles: true, cancelable: true }));" }
            .joined(separator: "\n              ")
        let script = """
            (() => {
              const target = document.activeElement || document.body || document.documentElement;
              if (!target) return { ok: false, error: 'not_found' };
              const k = String(\(keyLiteral));
              \(dispatches)
              return { ok: true };
            })()
            """
        BrowserJS.run(target.webView, script: script) { outcome in
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
        BrowserJS.run(target.webView, script: script) { outcome in
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
        BrowserJS.run(target.webView, script: script) { outcome in
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
            BrowserJS.run(target.webView, script: script) { outcome in
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

        BrowserJS.run(target.webView, script: script) { outcome in
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

        BrowserJS.run(target.webView, script: script) { outcome in
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
