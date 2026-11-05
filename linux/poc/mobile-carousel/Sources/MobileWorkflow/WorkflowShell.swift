import Adwaita
import CAdwShim
import CVte
import CWebKit
import Foundation

struct WorkflowShellWidget: AdwaitaWidget {

    var overview: Bool
    var workspaceCount: Int
    var fontScale: Double
    var closeRequest: Int
    var onWorkspaceChanged: (Int, Int, Int, [String]) -> Void
    var onPaneChanged: (Int) -> Void
    var onExitOverview: () -> Void
    var onFontScale: (Double) -> Void

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage where Data: ViewRenderData {
        let runtime = WorkflowRuntime.shared
        let tabView = adw_tab_view_new()!
        let tabViewWidget: UnsafeMutablePointer<GtkWidget> = cast(tabView)
        gtk_widget_set_hexpand(tabViewWidget, 1)
        gtk_widget_set_vexpand(tabViewWidget, 1)
        let tabOverviewWidget = adw_tab_overview_new()!
        let tabOverview = OpaquePointer(tabOverviewWidget)
        gtk_widget_set_hexpand(tabOverviewWidget, 1)
        gtk_widget_set_vexpand(tabOverviewWidget, 1)
        adw_tab_overview_set_view(tabOverview, tabView)
        adw_tab_overview_set_child(tabOverview, tabViewWidget)
        adw_tab_overview_set_enable_new_tab(tabOverview, 1)
        adw_tab_overview_set_show_start_title_buttons(tabOverview, 0)
        adw_tab_overview_set_show_end_title_buttons(tabOverview, 0)
        runtime.tabView = tabView
        runtime.tabOverview = tabOverview
        g_signal_connect_data(
            UnsafeMutableRawPointer(tabView), "notify::selected-page",
            unsafeBitCast(workflowSelectedPageChanged, to: GCallback.self), nil, nil, GConnectFlags(0))
        g_signal_connect_data(
            UnsafeMutableRawPointer(tabOverviewWidget), "notify::open",
            unsafeBitCast(workflowOverviewOpenChanged, to: GCallback.self), nil, nil, GConnectFlags(0))
        g_signal_connect_data(
            UnsafeMutableRawPointer(tabOverviewWidget), "create-tab",
            unsafeBitCast(workflowOverviewCreateTab, to: GCallback.self), nil, nil, GConnectFlags(0))
        WorkflowStyle.install()
        let storage = ViewStorage(OpaquePointer(tabOverviewWidget))
        sync(storage)
        return storage
    }

    func update<Data>(
        _ storage: ViewStorage, data: WidgetData, updateProperties: Bool, type: Data.Type
    ) where Data: ViewRenderData {
        sync(storage)
    }

    private func sync(_ storage: ViewStorage) {
        let runtime = WorkflowRuntime.shared
        runtime.onWorkspaceChanged = onWorkspaceChanged
        runtime.onPaneChanged = onPaneChanged
        runtime.onExitOverview = onExitOverview
        runtime.onFontScale = onFontScale

        if closeRequest != runtime.handledCloseRequest {
            runtime.handledCloseRequest = closeRequest
            runtime.closeCurrentWorkspace()
        }
        while runtime.workspaces.count < workspaceCount {
            runtime.appendWorkspace(fontScale: fontScale)
        }
        if runtime.fontScale != fontScale {
            runtime.fontScale = fontScale
            for ws in runtime.workspaces { vte_terminal_set_font_scale(ws.terminal, fontScale) }
        }
        if runtime.overview != overview, let tabOverview = runtime.tabOverview {
            runtime.overview = overview
            adw_tab_overview_set_open(tabOverview, overview ? 1 : 0)
            if !overview { runtime.focusCurrentPane() }
        }
    }
}

/// One worktree: a tab page whose child is [carousel(shell, preview), toggle, key row].
final class Workspace {
    let name: String
    var page: OpaquePointer!                       // AdwTabPage
    var carousel: OpaquePointer!                   // AdwCarousel
    var terminal: UnsafeMutablePointer<VteTerminal>!
    var shellPage: UnsafeMutablePointer<GtkWidget>!
    var webView: UnsafeMutablePointer<GtkWidget>!
    var previewPage: UnsafeMutablePointer<GtkWidget>!   // [url bar revealer, web view]
    var urlRevealer: OpaquePointer!                // GtkRevealer
    var urlEntry: UnsafeMutablePointer<GtkWidget>!
    var urlButton: UnsafeMutablePointer<GtkWidget>!     // toggles the bar, preview only
    var zoomLabel: UnsafeMutablePointer<GtkWidget>!
    var toggle: OpaquePointer!                     // AdwToggleGroup
    var keyRow: UnsafeMutablePointer<GtkWidget>!
    init(name: String) { self.name = name }

    var paneIndex: Int {
        max(0, min(1, Int(adw_carousel_get_position(carousel).rounded())))
    }
}

final class WorkflowRuntime {
    static let shared = WorkflowRuntime()
    var guardedHeaders = Set<UnsafeMutablePointer<GtkWidget>>()

    var tabView: OpaquePointer?
    var tabOverview: OpaquePointer?
    var workspaces: [Workspace] = []
    var overview = false
    var fontScale = 1.0
    var handledCloseRequest = 0
    var onWorkspaceChanged: (Int, Int, Int, [String]) -> Void = { _, _, _, _ in }
    var onPaneChanged: (Int) -> Void = { _ in }
    var onExitOverview: () -> Void = {}
    var onFontScale: (Double) -> Void = { _ in }

    let previewURL = ProcessInfo.processInfo.environment["MOBILE_PREVIEW_URL"]
    let worktreeRoot = ProcessInfo.processInfo.environment["MOBILE_WORKTREE_ROOT"]
    lazy var presetNames: [String] = (ProcessInfo.processInfo.environment["MOBILE_WORKSPACE_NAMES"] ?? "")
        .split(separator: ",").map(String.init)

    // column fit (same scheme as v1, on the selected workspace's terminal)
    var fitCols = Int(ProcessInfo.processInfo.environment["MOBILE_FIT_COLS"] ?? "") ?? 80
    var fitted = false
    var fitTicks = 0
    var fitPasses = 0

    var currentIndex: Int {
        guard let tabView, let page = adw_tab_view_get_selected_page(tabView) else { return 0 }
        return max(0, Int(adw_tab_view_get_page_position(tabView, page)))
    }
    var current: Workspace? { workspaces.isEmpty ? nil : workspaces[currentIndex] }
    var currentTerminal: UnsafeMutablePointer<VteTerminal>? { current?.terminal }

    func notifyWorkspace() {
        onWorkspaceChanged(currentIndex, workspaces.count, current?.paneIndex ?? 0, workspaces.map(\.name))
    }

    // MARK: workspaces

    func appendWorkspace(fontScale: Double) {
        guard let tabView else { return }
        let index = workspaces.count
        let name = index < presetNames.count ? presetNames[index] : "feature-\(index + 1)"
        let ws = Workspace(name: name)
        self.fontScale = fontScale

        // shell pane
        guard let vteWidget = vte_terminal_new() else { return }
        let terminal = UnsafeMutableRawPointer(vteWidget).assumingMemoryBound(to: VteTerminal.self)
        gtk_widget_set_hexpand(vteWidget, 1)
        gtk_widget_set_vexpand(vteWidget, 1)
        vte_terminal_set_scrollback_lines(terminal, 10_000)
        vte_terminal_set_size(terminal, 80, 24)
        vte_terminal_set_font_scale(terminal, fontScale)
        let scrolled = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(OpaquePointer(scrolled), vteWidget)
        gtk_scrolled_window_set_policy(OpaquePointer(scrolled), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scrolled, 1)
        gtk_widget_set_vexpand(scrolled, 1)
        ws.terminal = terminal
        ws.shellPage = scrolled
        WorkflowKeys.installStickyCtrl(on: vteWidget)
        g_signal_connect_data(
            UnsafeMutableRawPointer(vteWidget), "map",
            unsafeBitCast(workflowTerminalMapped, to: GCallback.self), nil, nil, GConnectFlags(0))

        // preview pane
        let webView = webkit_web_view_new()!
        gtk_widget_set_hexpand(webView, 1)
        gtk_widget_set_vexpand(webView, 1)
        ws.webView = webView
        g_signal_connect_data(
            UnsafeMutableRawPointer(webView), "notify::uri",
            unsafeBitCast(workflowUriChanged, to: GCallback.self),
            UnsafeMutableRawPointer(bitPattern: index + 1), nil, GConnectFlags(0))
        loadPreview(ws)

        // optional URL bar above the preview (hias 2026-11-04: the human asks the
        // LLM to inspect a specific page, so the address must be visible/editable)
        let urlBar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        gtk_widget_add_css_class(urlBar, "url-bar")
        let urlEntry = gtk_entry_new()!
        gtk_widget_set_hexpand(urlEntry, 1)
        gtk_entry_set_placeholder_text(cast(urlEntry), "URL")
        gtk_entry_set_input_purpose(cast(urlEntry), GTK_INPUT_PURPOSE_URL)
        g_signal_connect_data(
            UnsafeMutableRawPointer(urlEntry), "activate",
            unsafeBitCast(workflowUrlActivated, to: GCallback.self),
            UnsafeMutableRawPointer(bitPattern: index + 1), nil, GConnectFlags(0))
        ws.urlEntry = urlEntry
        let reload = gtk_button_new_from_icon_name("view-refresh-symbolic")!
        gtk_widget_add_css_class(reload, "flat")
        gtk_widget_set_focus_on_click(reload, 0)
        g_signal_connect_data(
            UnsafeMutableRawPointer(reload), "clicked",
            unsafeBitCast(workflowReloadClicked, to: GCallback.self),
            UnsafeMutableRawPointer(bitPattern: index + 1), nil, GConnectFlags(0))
        gtk_box_append(cast(urlBar), urlEntry)
        gtk_box_append(cast(urlBar), reload)
        // ⋮ menu: page zoom (hias 2026-11-04 — pinch does not arrive over a
        // mouse-emulated RDP path, buttons always work)
        let menu = gtk_menu_button_new()!
        gtk_menu_button_set_icon_name(OpaquePointer(menu), "view-more-symbolic")
        gtk_widget_add_css_class(menu, "flat")
        gtk_widget_set_focus_on_click(menu, 0)
        let popover = gtk_popover_new()!
        let menuBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2)!
        let zoomRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        let zoomLabel = gtk_label_new("100 %")!
        gtk_widget_set_size_request(zoomLabel, 56, -1)
        ws.zoomLabel = zoomLabel
        for (icon, delta) in [("zoom-out-symbolic", -1), ("zoom-in-symbolic", 1)] {
            let b = gtk_button_new_from_icon_name(icon)!
            gtk_widget_add_css_class(b, "flat")
            g_signal_connect_data(
                UnsafeMutableRawPointer(b), "clicked",
                unsafeBitCast(workflowZoomClicked, to: GCallback.self),
                UnsafeMutableRawPointer(bitPattern: (index + 1) * 4 + (delta + 2)), nil, GConnectFlags(0))
            if delta < 0 { gtk_box_append(cast(zoomRow), b) }
            else { gtk_box_append(cast(zoomRow), zoomLabel); gtk_box_append(cast(zoomRow), b) }
        }
        let zoomReset = gtk_button_new_with_label("Zoom zurücksetzen")!
        gtk_widget_add_css_class(zoomReset, "flat")
        g_signal_connect_data(
            UnsafeMutableRawPointer(zoomReset), "clicked",
            unsafeBitCast(workflowZoomClicked, to: GCallback.self),
            UnsafeMutableRawPointer(bitPattern: (index + 1) * 4 + 2), nil, GConnectFlags(0))
        gtk_box_append(cast(menuBox), zoomRow)
        gtk_box_append(cast(menuBox), zoomReset)
        gtk_popover_set_child(cast(popover), menuBox)
        gtk_menu_button_set_popover(OpaquePointer(menu), popover)
        gtk_box_append(cast(urlBar), menu)
        let revealer = gtk_revealer_new()!
        gtk_revealer_set_child(OpaquePointer(revealer), urlBar)
        gtk_revealer_set_transition_type(OpaquePointer(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_DOWN)
        gtk_revealer_set_reveal_child(OpaquePointer(revealer), WorkflowRuntime.urlBarDefault ? 1 : 0)
        ws.urlRevealer = OpaquePointer(revealer)
        let previewPage = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_hexpand(previewPage, 1)
        gtk_widget_set_vexpand(previewPage, 1)
        gtk_box_append(cast(previewPage), revealer)
        gtk_box_append(cast(previewPage), webView)
        ws.previewPage = previewPage

        // carousel + edge strips
        let carouselWidget = adw_carousel_new()!
        let carousel = OpaquePointer(carouselWidget)
        gtk_widget_set_hexpand(carouselWidget, 1)
        gtk_widget_set_vexpand(carouselWidget, 1)
        adw_carousel_set_interactive(carousel, 0)
        adw_carousel_set_allow_mouse_drag(carousel, 0)
        adw_carousel_set_allow_scroll_wheel(carousel, 0)
        adw_carousel_append(carousel, scrolled)
        adw_carousel_append(carousel, previewPage)
        ws.carousel = carousel
        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(OpaquePointer(overlay), carouselWidget)
        for start in [true, false] {
            let strip = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
            gtk_widget_set_size_request(strip, 22, -1)
            gtk_widget_set_halign(strip, start ? GTK_ALIGN_START : GTK_ALIGN_END)
            gtk_widget_set_vexpand(strip, 1)
            gtk_widget_add_css_class(strip, "edge-strip")
            let drag = gtk_gesture_drag_new()!
            g_signal_connect_data(
                UnsafeMutableRawPointer(drag), "drag-end",
                unsafeBitCast(workflowEdgeDragEnd, to: GCallback.self),
                UnsafeMutableRawPointer(bitPattern: index + 1), nil, GConnectFlags(0))
            gtk_widget_add_controller(strip, drag)
            gtk_overlay_add_overlay(OpaquePointer(overlay), strip)
        }
        gtk_widget_set_hexpand(overlay, 1)
        gtk_widget_set_vexpand(overlay, 1)

        // bottom toggle Shell | Vorschau
        let toggleWidget = adw_toggle_group_new()!
        let toggle = OpaquePointer(toggleWidget)
        for label in ["Shell", "Vorschau"] {
            let t = adw_toggle_new()!
            adw_toggle_set_label(t, label)
            adw_toggle_group_add(toggle, t)
        }
        adw_toggle_group_set_homogeneous(toggle, 1)
        gtk_widget_set_margin_start(toggleWidget, 8)
        gtk_widget_set_margin_end(toggleWidget, 8)
        gtk_widget_set_margin_top(toggleWidget, 6)
        gtk_widget_set_margin_bottom(toggleWidget, 2)
        gtk_widget_set_focus_on_click(toggleWidget, 0)
        ws.toggle = toggle
        gtk_widget_set_hexpand(toggleWidget, 1)
        // URL-bar toggle sits right of the pane toggle, shown on the preview only
        let urlButton = gtk_toggle_button_new()!
        gtk_button_set_icon_name(cast(urlButton), "web-browser-symbolic")
        gtk_widget_set_tooltip_text(urlButton, "Adressleiste")
        gtk_widget_add_css_class(urlButton, "flat")
        gtk_widget_set_focus_on_click(urlButton, 0)
        gtk_widget_set_margin_end(urlButton, 8)
        gtk_widget_set_margin_top(urlButton, 6)
        gtk_widget_set_margin_bottom(urlButton, 2)
        gtk_widget_set_visible(urlButton, 0)
        gtk_toggle_button_set_active(cast(urlButton), WorkflowRuntime.urlBarDefault ? 1 : 0)
        g_signal_connect_data(
            UnsafeMutableRawPointer(urlButton), "toggled",
            unsafeBitCast(workflowUrlButtonToggled, to: GCallback.self),
            UnsafeMutableRawPointer(bitPattern: index + 1), nil, GConnectFlags(0))
        ws.urlButton = urlButton
        let bottomRow = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)!
        if workflowDebug {
            let probe = gtk_gesture_click_new()!
            gtk_event_controller_set_propagation_phase(probe, GTK_PHASE_CAPTURE)
            g_signal_connect_data(
                UnsafeMutableRawPointer(probe), "pressed",
                unsafeBitCast(workflowProbePressed, to: GCallback.self), nil, nil, GConnectFlags(0))
            gtk_widget_add_controller(bottomRow, probe)
        }
        gtk_box_append(cast(bottomRow), toggleWidget)
        gtk_box_append(cast(bottomRow), urlButton)
        g_signal_connect_data(
            UnsafeMutableRawPointer(toggleWidget), "notify::active",
            unsafeBitCast(workflowToggleChanged, to: GCallback.self),
            UnsafeMutableRawPointer(bitPattern: index + 1), nil, GConnectFlags(0))
        g_signal_connect_data(
            UnsafeMutableRawPointer(carouselWidget), "page-changed",
            unsafeBitCast(workflowPaneChanged, to: GCallback.self),
            UnsafeMutableRawPointer(bitPattern: index + 1), nil, GConnectFlags(0))

        // key row (shell only)
        let keyRow = WorkflowKeys.build()
        ws.keyRow = keyRow

        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_box_append(cast(box), overlay)
        gtk_box_append(cast(box), bottomRow)
        gtk_box_append(cast(box), keyRow)

        let page = adw_tab_view_append(tabView, box)!
        adw_tab_page_set_title(page, name)
        adw_tab_page_set_live_thumbnail(page, 1)
        ws.page = page
        workspaces.append(ws)
        spawnShell(ws)
        if workspaces.count > 1 { adw_tab_view_set_selected_page(tabView, page) }
        notifyWorkspace()
    }

    func closeCurrentWorkspace() {
        guard let tabView, !workspaces.isEmpty else { return }
        let ws = workspaces.remove(at: currentIndex)
        adw_tab_view_close_page(tabView, ws.page)
        notifyWorkspace()
        focusCurrentPane()
    }

    // MARK: panes

    func scroll(_ ws: Workspace, toPane pane: Int) {
        let target = pane == 0 ? ws.shellPage! : ws.previewPage!
        adw_carousel_scroll_to(ws.carousel, target, 1)
    }

    func paneChanged(_ ws: Workspace) {
        let pane = ws.paneIndex
        dbg("page-changed \(ws.name) pane=\(pane) pos=\(adw_carousel_get_position(ws.carousel)) toggle=\(adw_toggle_group_get_active(ws.toggle))")
        if Int(adw_toggle_group_get_active(ws.toggle)) != pane {
            adw_toggle_group_set_active(ws.toggle, UInt32(pane))
        }
        gtk_widget_set_visible(ws.keyRow, pane == 0 ? 1 : 0)
        gtk_widget_set_visible(ws.urlButton, pane == 1 ? 1 : 0)
        if ws === current {
            onPaneChanged(pane)
            if !overview { focusCurrentPane() }
        }
    }

    func focusCurrentPane() {
        guard let ws = current else { return }
        let widget: UnsafeMutablePointer<GtkWidget> = ws.paneIndex == 0 ? cast(ws.terminal) : ws.webView
        gtk_widget_grab_focus(widget)
    }

    func feed(_ bytes: [UInt8]) {
        guard let terminal = currentTerminal else { return }
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                vte_terminal_feed_child(terminal, $0, buffer.count)
            }
        }
    }

    func workspace(forUserData userData: UnsafeMutableRawPointer?) -> Workspace? {
        guard let userData else { return nil }
        let index = Int(bitPattern: userData) - 1
        return index >= 0 && index < workspaces.count ? workspaces[index] : nil
    }

    // MARK: preview

    /// MOBILE_URL_BAR=1 shows the address bar from the start; default hidden.
    static let urlBarDefault = ProcessInfo.processInfo.environment["MOBILE_URL_BAR"] == "1"

    func webView(_ ws: Workspace) -> UnsafeMutablePointer<WebKitWebView> {
        UnsafeMutableRawPointer(ws.webView).assumingMemoryBound(to: WebKitWebView.self)
    }

    func setUrlBarVisible(_ ws: Workspace, _ visible: Bool) {
        gtk_revealer_set_reveal_child(ws.urlRevealer, visible ? 1 : 0)
        if gtk_toggle_button_get_active(cast(ws.urlButton)) != (visible ? 1 : 0) {
            gtk_toggle_button_set_active(cast(ws.urlButton), visible ? 1 : 0)
        }
        if visible, ws.paneIndex == 1 { gtk_widget_grab_focus(ws.urlEntry) }
    }

    /// Entry text → load; bare hosts get http://, since dev servers are plain http.
    func navigate(_ ws: Workspace) {
        let buffer = gtk_entry_get_buffer(cast(ws.urlEntry))
        guard let raw = gtk_entry_buffer_get_text(buffer) else { return }
        var text = String(cString: raw).trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        if !text.contains("://"), !text.hasPrefix("about:") { text = "http://" + text }
        webkit_web_view_load_uri(webView(ws), text)
        gtk_widget_grab_focus(ws.webView)
    }

    /// delta −1 / +1 steps the WebKit zoom by 10 %, 0 resets to 100 %.
    func zoom(_ ws: Workspace, delta: Int) {
        let view = webView(ws)
        var level = delta == 0 ? 1.0 : webkit_web_view_get_zoom_level(view) + Double(delta) * 0.1
        level = max(0.3, min(3.0, (level * 10).rounded() / 10))
        webkit_web_view_set_zoom_level(view, level)
        gtk_label_set_text(OpaquePointer(ws.zoomLabel), "\(Int((level * 100).rounded())) %")
    }

    func syncUrlEntry(_ ws: Workspace) {
        guard let uri = webkit_web_view_get_uri(webView(ws)) else { return }
        let text = String(cString: uri)
        dbg("uri: \(text)")
        // about:blank is the placeholder page; keep whatever the human typed then
        guard !text.isEmpty, !text.hasPrefix("about:") else { return }
        gtk_editable_set_text(OpaquePointer(ws.urlEntry), text)
    }

    private func loadPreview(_ ws: Workspace) {
        let view = UnsafeMutableRawPointer(ws.webView).assumingMemoryBound(to: WebKitWebView.self)
        if let previewURL, !previewURL.isEmpty {
            webkit_web_view_load_uri(view, previewURL)
            return
        }
        // Placeholder until feature-start hands over a dev-server port:
        // shows the workspace and the live viewport, so phone-width checks
        // are visible even before a real app loads.
        let html = """
        <!doctype html><meta name=viewport content="width=device-width, initial-scale=1">
        <style>body{font:16px system-ui;margin:0;padding:24px;background:#1e1e2e;color:#cdd6f4}
        h1{font-size:22px;margin:0 0 8px}code{background:#313244;padding:2px 6px;border-radius:4px}
        .card{background:#313244;border-radius:12px;padding:16px;margin-top:16px}
        .cell{margin:4px 0}</style>
        <h1>Vorschau · \(ws.name)</h1>
        <p>Dev-Server noch nicht gestartet. <code>feature-start</code> setzt hier die URL.</p>
        <div class=card><div class=cell>viewport: <b id=vp></b></div>
        <div class=cell>devicePixelRatio: <b id=dpr></b></div><div class=cell>touch: <b id=touch></b></div></div>
        <script>function u(){vp.textContent=innerWidth+' × '+innerHeight;dpr.textContent=devicePixelRatio;
        touch.textContent=('ontouchstart' in window)?'ja':'nein (RDP = Maus)'};u();addEventListener('resize',u)</script>
        """
        webkit_web_view_load_html(view, html, nil)
    }

    private func spawnShell(_ ws: Workspace) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_MOBILE_SPIKE"] = "2"
        environment["MOBILE_WORKSPACE"] = ws.name
        environment["TERM"] = "xterm-256color"
        var cwd: String? = nil
        if let worktreeRoot {
            let candidate = "\(worktreeRoot)/\(ws.name)"
            if FileManager.default.fileExists(atPath: candidate) { cwd = candidate }
        }
        let argv = cStringArray([shell])
        let envv = cStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer { g_strfreev(argv); g_strfreev(envv) }
        vte_terminal_spawn_async(
            ws.terminal, VTE_PTY_DEFAULT, cwd, argv, envv, G_SPAWN_DEFAULT,
            nil, nil, nil, -1, nil, nil, nil)
    }

    // MARK: column fit (v1 scheme)

    func fitColumns() {
        guard fitCols > 0, !fitted, let terminal = currentTerminal else { return }
        let widget: UnsafeMutablePointer<GtkWidget> = cast(terminal)
        let width = Double(gtk_widget_get_width(widget))
        let charWidth = Double(vte_terminal_get_char_width(terminal))
        guard width > 0, charWidth > 0 else { return }
        let cols = Int(vte_terminal_get_column_count(terminal))
        fitPasses += 1
        if fitPasses % 3 != 1 { return }
        if fitPasses > 1, cols >= fitCols || fitPasses > 30 {
            fitted = true
            return
        }
        let scale = fitPasses == 1
            ? fontScale * width / (charWidth * Double(fitCols))
            : fontScale - 0.04
        onFontScale(max(0.3, min(2.0, (scale * 100).rounded(.down) / 100)))
    }
}

func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (index, string) in strings.enumerated() { array[index] = strdup(string) }
    array[strings.count] = nil
    return array
}

func cast<T>(_ pointer: OpaquePointer) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
}
func cast<T, U>(_ pointer: UnsafeMutablePointer<U>) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
}

// MARK: C callbacks

let workflowSelectedPageChanged: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, _, _ in
    let runtime = WorkflowRuntime.shared
    runtime.notifyWorkspace()
    if !runtime.overview { runtime.focusCurrentPane() }
}

let workflowOverviewOpenChanged: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { overview, _, _ in
    guard let overview else { return }
    let runtime = WorkflowRuntime.shared
    let open = adw_tab_overview_get_open(OpaquePointer(overview)) != 0
    if !open, runtime.overview { runtime.onExitOverview() }
}

let workflowOverviewCreateTab: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> OpaquePointer?
= { _, _ in
    let runtime = WorkflowRuntime.shared
    runtime.appendWorkspace(fontScale: runtime.fontScale)
    return runtime.workspaces.last?.page
}

let workflowPaneChanged: @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
= { _, _, userData in
    let runtime = WorkflowRuntime.shared
    guard let ws = runtime.workspace(forUserData: userData) else { return }
    runtime.paneChanged(ws)
}

let workflowToggleChanged: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { toggle, _, userData in
    guard let toggle else { return }
    let runtime = WorkflowRuntime.shared
    guard let ws = runtime.workspace(forUserData: userData) else { return }
    let active = Int(adw_toggle_group_get_active(OpaquePointer(toggle)))
    dbg("toggle \(ws.name) active=\(active) pane=\(ws.paneIndex) pos=\(adw_carousel_get_position(ws.carousel))")
    if active != ws.paneIndex { runtime.scroll(ws, toPane: active) }
}

/// Edge strip swipe: a horizontal drag past 40 px flips to the neighbour pane.
let workflowEdgeDragEnd: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void
= { _, offsetX, _, userData in
    let runtime = WorkflowRuntime.shared
    guard let ws = runtime.workspace(forUserData: userData) else { return }
    if offsetX < -40, ws.paneIndex == 0 { runtime.scroll(ws, toPane: 1) }
    if offsetX > 40, ws.paneIndex == 1 { runtime.scroll(ws, toPane: 0) }
}

let workflowUrlButtonToggled: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { button, userData in
    guard let button else { return }
    let runtime = WorkflowRuntime.shared
    guard let ws = runtime.workspace(forUserData: userData) else { return }
    runtime.setUrlBarVisible(ws, gtk_toggle_button_get_active(button.assumingMemoryBound(to: GtkToggleButton.self)) != 0)
}

let workflowUrlActivated: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, userData in
    let runtime = WorkflowRuntime.shared
    guard let ws = runtime.workspace(forUserData: userData) else { return }
    runtime.navigate(ws)
}

let workflowReloadClicked: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, userData in
    let runtime = WorkflowRuntime.shared
    guard let ws = runtime.workspace(forUserData: userData) else { return }
    webkit_web_view_reload(runtime.webView(ws))
}

/// userData = (workspace index + 1) * 4 + (delta + 2); delta ∈ {−1, 0, +1}.
let workflowZoomClicked: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, userData in
    guard let userData else { return }
    let packed = Int(bitPattern: userData)
    let runtime = WorkflowRuntime.shared
    guard let ws = runtime.workspace(forUserData: UnsafeMutableRawPointer(bitPattern: packed / 4)) else { return }
    runtime.zoom(ws, delta: packed % 4 - 2)
}

let workflowUriChanged: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, _, userData in
    let runtime = WorkflowRuntime.shared
    guard let ws = runtime.workspace(forUserData: userData) else { return }
    runtime.syncUrlEntry(ws)
}

let workflowTerminalMapped: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { widget, _ in
    _ = g_timeout_add(120, workflowFitTick, nil)
    // MOBILE_FULLSCREEN=1: fill the (phone-sized) remote display from the
    // start. hias 2026-11-05: a double-tap on the header bar to maximize
    // crashed mutter 50.1 (libei touch-up without touch-down) — never make
    // the user reach for the title bar over RDP.
    if let widget, let root = gtk_widget_get_root(widget.assumingMemoryBound(to: GtkWidget.self)) {
        if ProcessInfo.processInfo.environment["MOBILE_FULLSCREEN"] == "1" {
            gtk_window_fullscreen(cast(root))
        }
        WorkflowRuntime.shared.installHeaderGuard(root: cast(root))
    }
}

extension WorkflowRuntime {
    /// A press on an EMPTY header-bar spot makes GTK ask the compositor for a
    /// window move; over libei touch that request crashes mutter 50.1 (hias,
    /// 2026-11-05: "wenn man in der Titelleiste etwas nicht trifft"). A
    /// capture-phase click gesture claims those presses before the header's
    /// GtkWindowHandle sees them; presses that land on a button fall through.
    func installHeaderGuard(root: UnsafeMutablePointer<GtkWidget>) {
        // every header bar in the window: the window's own AND the one
        // AdwTabOverview builds for the overview page
        for header in findWidgets(root, cssName: "headerbar") where !guardedHeaders.contains(header) {
            guardedHeaders.insert(header)
            let click = gtk_gesture_click_new()!
            gtk_gesture_single_set_button(click, 0)   // any button / touch
            gtk_event_controller_set_propagation_phase(click, GTK_PHASE_CAPTURE)
            g_signal_connect_data(
                UnsafeMutableRawPointer(click), "pressed",
                unsafeBitCast(workflowHeaderPressed, to: GCallback.self),
                UnsafeMutableRawPointer(header), nil, GConnectFlags(0))
            gtk_widget_add_controller(header, click)
            dbg("header guard installed on \(header)")
        }
    }

    func findWidgets(_ w: UnsafeMutablePointer<GtkWidget>, cssName: String) -> [UnsafeMutablePointer<GtkWidget>] {
        var hits: [UnsafeMutablePointer<GtkWidget>] = []
        if let n = gtk_widget_get_css_name(w), String(cString: n) == cssName { hits.append(w) }
        var child = gtk_widget_get_first_child(w)
        while let c = child {
            hits += findWidgets(c, cssName: cssName)
            child = gtk_widget_get_next_sibling(c)
        }
        return hits
    }
}

let workflowHeaderPressed: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void
= { gesture, _, x, y, userData in
    guard let gesture, let userData else { return }
    let header = userData.assumingMemoryBound(to: GtkWidget.self)
    var target = gtk_widget_pick(header, x, y, GTK_PICK_DEFAULT)
    while let t = target, t != header {
        if let n = gtk_widget_get_css_name(t), String(cString: n) == "button" { return }   // real control: let it work
        target = gtk_widget_get_parent(t)
    }
    gtk_gesture_set_state(OpaquePointer(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
    dbg("header press claimed at \(Int(x)),\(Int(y)) (no window move)")
}

let workflowFitTick: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in
    let runtime = WorkflowRuntime.shared
    runtime.fitColumns()
    runtime.fitTicks += 1
    return (runtime.fitted || runtime.fitTicks > 60) ? 0 : 1
}

let workflowProbePressed: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void
= { _, n, x, y, _ in dbg("bottomRow pressed n=\(n) x=\(x) y=\(y)") }

let workflowDebug = ProcessInfo.processInfo.environment["MOBILE_DEBUG"] != nil
func dbg(_ line: String) { if workflowDebug { fputs(line + "\n", stderr) } }

enum WorkflowStyle {
    static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        let css = """
        .edge-strip { background: alpha(@accent_bg_color, 0.08); }
        .url-bar { padding: 4px 6px; border-bottom: 1px solid @borders; }
        .mobile-keys { padding: 4px 6px; border-top: 1px solid @borders; }
        .mobile-keys button { min-width: 36px; min-height: 36px; padding: 0 8px; }
        """
        guard let provider = gtk_css_provider_new() else { return }
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(), OpaquePointer(provider),
            UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION))
    }
}
