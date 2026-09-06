import CWebKit
import Foundation
import Glibc

/// `cmux://` — the app serving its OWN state to a browser pane.
///
/// WHY A SCHEME AND NOT A FILE OR A LOCALHOST SERVER: everything served
/// here has no path on disk. A surface's scrollback lives in the running
/// app; `BuildInfo` is assembled at build time and read from memory.
/// `file://` cannot address them and a localhost server would mean
/// binding a port, authenticating it, and defending it — a network
/// surface for data that never needs to leave the process. The scheme
/// handler is the seam that already exists in WebKit for exactly this.
///
/// SCOPE (hias GO 2026-09-06, GAPS row): local use only. No network, no
/// DHT, and nothing here may be read as a freshness or authenticity
/// claim — it is this process reporting on itself.
///
/// SECURITY: the scheme is registered `as_no_access`, so a document
/// loaded from `cmux://` gets a unique opaque origin and cannot reach
/// into other origins; and because it is NOT registered CORS-enabled, a
/// remote page's `fetch("cmux://…")` is refused by the same-origin
/// policy. The suite asserts that refusal rather than trusting it — a
/// page that could read `cmux://surface/<id>/scrollback` would be
/// reading the human's terminal.
/// File scope on purpose: a `@convention(c)` closure written inside the
/// enum captures the enclosing type as context and will not compile —
/// the trap already recorded at `BrowserAutomation.swift:18`.
private let cmuxSchemeHandler: @convention(c) (
    OpaquePointer?, UnsafeMutableRawPointer?
) -> Void = { request, _ in
    guard let request else { return }
    MainActor.assumeIsolated { BrowserURIScheme.serve(request) }
}

enum BrowserURIScheme {

    static let scheme = "cmux"
    private static var registered = false

    /// Registers the scheme on the default web context. Idempotent, and
    /// must run BEFORE the first web view is created — a scheme
    /// registered later is not known to views already alive.
    static func ensureRegistered() {
        guard !registered else { return }
        registered = true
        guard let context = webkit_web_context_get_default() else { return }

        webkit_web_context_register_uri_scheme(context, scheme, cmuxSchemeHandler, nil, nil)

        // Opaque origin for cmux:// documents; deliberately NOT
        // cors-enabled and NOT "local" (which would grant file:// access).
        if let manager = webkit_web_context_get_security_manager(context) {
            webkit_security_manager_register_uri_scheme_as_no_access(manager, scheme)
        }
    }

    /// Routes. Deliberately two, both read-only:
    ///   cmux://about                        JSON: build + the route list
    ///   cmux://surface/<uuid>/scrollback    text: that surface's buffer
    @MainActor
    fileprivate static func serve(_ request: OpaquePointer) {
        let uri = webkit_uri_scheme_request_get_uri(request).map { String(cString: $0) } ?? ""
        // "cmux://about" parses with an empty path and "about" as host, so
        // route on host + path together rather than on path alone.
        let rest = uri.hasPrefix("\(scheme)://")
            ? String(uri.dropFirst(scheme.count + 3))
            : uri
        let parts = rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)

        switch parts.first {
        case "about":
            var info = BuildInfo.payload
            info["scheme_routes"] = ["cmux://about", "cmux://surface/<uuid>/scrollback"]
            info["note"] = "process-local state; not a freshness or authenticity claim"
            finish(request, json: info)
        case "surface" where parts.count >= 3 && parts[2] == "scrollback":
            guard let id = UUID(uuidString: parts[1]) else {
                fail(request, status: 400, kind: "not-a-uuid", detail: parts[1]); return
            }
            // nil means "could not read", which is NOT "empty" — the same
            // distinction the session store learned the hard way.
            guard let text = SurfaceRegistry.shared.scrollbackText(for: id) else {
                // COULD-NOT-READ, which is not "empty" and not "no such
                // route" — three different non-answers, three codes. The
                // seam must carry the distinction the code already makes
                // internally (qvision review, 2026-09-06).
                fail(request, status: 503, kind: "unreadable", detail: parts[1]); return
            }
            finish(request, text: text, mime: "text/plain")
        default:
            fail(request, status: 404, kind: "unknown-route", detail: rest)
        }
    }

    private static func finish(_ request: OpaquePointer,
                               json: [String: Any]) {
        let data = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        finish(request, text: String(decoding: data, as: UTF8.self), mime: "application/json")
    }

    private static func finish(_ request: OpaquePointer, text: String, mime: String) {
        respond(request, text: text, mime: mime, status: 200, reason: "OK")
    }

    private static func respond(_ request: OpaquePointer, text: String, mime: String,
                                status: UInt, reason: String) {
        let bytes = Array(text.utf8)
        // The stream takes ownership of the copy through the destructor.
        guard let buffer = malloc(max(bytes.count, 1)) else { return }
        bytes.withUnsafeBytes { raw in
            if let base = raw.baseAddress { memcpy(buffer, base, bytes.count) }
        }
        let stream = g_memory_input_stream_new_from_data(buffer, bytes.count, { ptr in free(ptr) })
        if let response = webkit_uri_scheme_response_new(stream, bytes.count) {
            webkit_uri_scheme_response_set_content_type(response, mime)
            webkit_uri_scheme_response_set_status(response, UInt32(status), reason)
            webkit_uri_scheme_request_finish_with_response(request, response)
            g_object_unref(UnsafeMutableRawPointer(response))
        }
        if let stream { g_object_unref(UnsafeMutableRawPointer(stream)) }
    }

    /// A non-answer, typed. Served as a JSON body with a distinct status
    /// rather than one opaque 404, so a caller can tell "no such route"
    /// from "that surface cannot be read right now" — the same rule the
    /// session store and the vault verbs learned.
    private static func fail(_ request: OpaquePointer,
                             status: UInt, kind: String, detail: String) {
        let body = ["status": kind, "detail": detail,
                    "note": "process-local; not a freshness or authenticity claim"]
        let text = String(decoding:
            (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data("{}".utf8),
            as: UTF8.self)
        respond(request, text: text, mime: "application/json", status: status, reason: kind)
    }
}
