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
    var toggle: OpaquePointer!                     // AdwToggleGroup
    var keyRow: UnsafeMutablePointer<GtkWidget>!
    init(name: String) { self.name = name }

    var paneIndex: Int {
        max(0, min(1, Int(adw_carousel_get_position(carousel).rounded())))
    }
}

final class WorkflowRuntime {
    static let shared = WorkflowRuntime()

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
        loadPreview(ws)

        // carousel + edge strips
        let carouselWidget = adw_carousel_new()!
        let carousel = OpaquePointer(carouselWidget)
        gtk_widget_set_hexpand(carouselWidget, 1)
        gtk_widget_set_vexpand(carouselWidget, 1)
        adw_carousel_set_interactive(carousel, 0)
        adw_carousel_set_allow_mouse_drag(carousel, 0)
        adw_carousel_set_allow_scroll_wheel(carousel, 0)
        adw_carousel_append(carousel, scrolled)
        adw_carousel_append(carousel, webView)
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
        gtk_box_append(cast(box), toggleWidget)
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
        let target = pane == 0 ? ws.shellPage! : ws.webView!
        adw_carousel_scroll_to(ws.carousel, target, 1)
    }

    func paneChanged(_ ws: Workspace) {
        let pane = ws.paneIndex
        if Int(adw_toggle_group_get_active(ws.toggle)) != pane {
            adw_toggle_group_set_active(ws.toggle, UInt32(pane))
        }
        gtk_widget_set_visible(ws.keyRow, pane == 0 ? 1 : 0)
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

let workflowTerminalMapped: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, _ in
    _ = g_timeout_add(120, workflowFitTick, nil)
}

let workflowFitTick: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in
    let runtime = WorkflowRuntime.shared
    runtime.fitColumns()
    runtime.fitTicks += 1
    return (runtime.fitted || runtime.fitTicks > 60) ? 0 : 1
}

enum WorkflowStyle {
    static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        let css = """
        .edge-strip { background: alpha(@accent_bg_color, 0.08); }
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
