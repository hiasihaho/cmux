import CWebKit
import Foundation

// W3C WebDriver opt-in (roadmap/06 increment 2).
//
// WebKitGTK speaks W3C WebDriver, not CDP. `/usr/bin/WebKitWebDriver`
// (Fedora's webkitgtk6.0) is the server side; an application opts in by
// allowing automation on its web context. The handshake, per the GIR
// docs: enable automation → a client connects → `automation-started`
// hands us a `WebKitAutomationSession` → the client asks that session for
// a view → `create-web-view` must return one.
//
// The payoff over our JS-injection verbs is what page JavaScript can
// never do: **trusted input events** (`isTrusted: true`), which some
// login flows, drag-and-drop and media players require, plus standardized
// navigation/waiting semantics and the whole Selenium ecosystem.
//
// SECURITY: automation mode lets any local WebDriver client drive this
// process's web views, so it is strictly opt-in via `CMUX_WEBDRIVER=1`
// (same posture as `CMUX_SOCKET_MODE` on macOS). Never enable by default.
//
// NOTE: the handlers below are file-scope on purpose — a Swift closure
// converted to a C function pointer may not capture context, and that
// includes static members of an enclosing type (see PROGRESS gotchas).

/// Web views handed to automation clients, retained for the session.
private var automationWebViews: [OpaquePointer] = []

/// Bridge that lets a pre-made web view become a cmux browser pane.
///
/// WebDriver never adopts an existing browsing context — session creation
/// always asks us for a view via `create-web-view` (verified in both
/// launch and attach modes). Since the view is ours to choose, we can
/// hand the driver a real pane in the live workspace instead of an orphan
/// window: the human watches automation happen, and cmux's own socket
/// verbs address the very same web view.
enum BrowserAdoption {
    /// surfaceId → pre-made web view the factory should adopt instead of
    /// constructing its own.
    static var pending: [UUID: OpaquePointer] = [:]

    /// Set by CmuxApp (it owns the model bindings): create a browser pane
    /// in the selected workspace and register `view` for adoption.
    /// Returns false when there is no UI to adopt into yet.
    static var adoptIntoSplit: ((OpaquePointer) -> Bool)?
}

/// A driver connected: identify ourselves and stand ready to hand out a
/// web view when it asks.
private func cmuxAutomationStarted(_ session: OpaquePointer) {
    if let info = webkit_application_info_new() {
        webkit_application_info_set_name(info, "cmux")
        webkit_application_info_set_version(info, guint64(1), guint64(0), guint64(0))
        webkit_automation_session_set_application_info(session, info)
        webkit_application_info_unref(info)
    }

    let createView: @convention(c) (
        UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
    ) -> UnsafeMutableRawPointer? = { _, _ in
        cmuxCreateAutomationWebView()
    }
    g_signal_connect_data(
        UnsafeMutableRawPointer(session),
        "create-web-view",
        unsafeBitCast(createView, to: GCallback.self),
        nil, nil, GConnectFlags(0)
    )
}

/// Build the web view the driver will control. `is-controlled-by-automation`
/// is construct-only and 6.0 ships only `webkit_web_view_new(void)`, so
/// construct it with explicit properties. The automation network session
/// keeps the driver on an ephemeral profile rather than the human's
/// cookies.
private func cmuxCreateAutomationWebView() -> UnsafeMutableRawPointer? {
    let context = webkit_web_context_get_default()
    let networkSession = context.flatMap {
        webkit_web_context_get_network_session_for_automation($0)
    }

    var controlled = GValue()
    g_value_init(&controlled, g_type_from_name("gboolean"))
    g_value_set_boolean(&controlled, 1)

    var sessionValue = GValue()
    g_value_init(&sessionValue, webkit_network_session_get_type())
    g_value_set_object(&sessionValue, UnsafeMutableRawPointer(networkSession))

    let controlledName = strdup("is-controlled-by-automation")
    var sessionName: UnsafeMutablePointer<CChar>?
    var names: [UnsafePointer<CChar>?] = [UnsafePointer(controlledName)]
    var values: [GValue] = [controlled]
    if networkSession != nil {
        sessionName = strdup("network-session")
        names.append(UnsafePointer(sessionName))
        values.append(sessionValue)
    }
    let count = guint(names.count)
    defer {
        free(controlledName)
        if let sessionName { free(sessionName) }
        g_value_unset(&controlled)
        g_value_unset(&sessionValue)
    }

    let created = names.withUnsafeMutableBufferPointer { namePtr in
        values.withUnsafeMutableBufferPointer { valuePtr in
            g_object_new_with_properties(
                webkit_web_view_get_type(),
                count,
                namePtr.baseAddress,
                valuePtr.baseAddress
            )
        }
    }
    guard let created else { return nil }
    let rawView = UnsafeMutableRawPointer(created)
    let widget = rawView.assumingMemoryBound(to: GtkWidget.self)

    // Preferred: the driver drives a real cmux pane in the live
    // workspace. Falls back to a standalone window when there is no UI
    // yet (e.g. a driver-launched instance still starting up).
    if BrowserAdoption.adoptIntoSplit?(OpaquePointer(rawView)) == true {
        automationWebViews.append(OpaquePointer(rawView))
        return rawView
    }

    if let windowWidget = gtk_window_new() {
        let window = UnsafeMutableRawPointer(windowWidget)
            .assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_title(window, "cmux (WebDriver)")
        gtk_window_set_default_size(window, 1024, 768)
        gtk_window_set_child(window, widget)
        gtk_window_present(window)
    }

    automationWebViews.append(OpaquePointer(rawView))
    return rawView
}

enum BrowserWebDriver {

    /// True when the human explicitly asked for automation mode.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_WEBDRIVER"] == "1"
    }

    /// Enable automation on the default web context and wire the
    /// handshake. Call once at startup, after GTK init. No-op unless
    /// `CMUX_WEBDRIVER=1`.
    static func enableIfRequested() {
        guard isEnabled else { return }
        guard let context = webkit_web_context_get_default() else { return }

        // Connect before enabling so an early session cannot be missed.
        let started: @convention(c) (
            UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?
        ) -> Void = { _, session, _ in
            guard let session else { return }
            cmuxAutomationStarted(session)
        }
        g_signal_connect_data(
            UnsafeMutableRawPointer(context),
            "automation-started",
            unsafeBitCast(started, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )

        webkit_web_context_set_automation_allowed(context, 1)
        FileHandle.standardError.write(Data(
            "cmux: WebDriver automation ENABLED (CMUX_WEBDRIVER=1) — local WebDriver clients can drive this instance\n".utf8
        ))
    }
}
