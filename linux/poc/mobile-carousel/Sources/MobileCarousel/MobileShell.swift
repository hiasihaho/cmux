import Adwaita
import CAdwShim
import CVte
import Foundation

/// The imperative GTK tree behind the carousel (same pattern as cmux's
/// TerminalStackWidget: adwaita-swift owns the container, the terminals
/// live in a registry and are never re-created by a state change).
struct MobileShellWidget: AdwaitaWidget {

    var overview: Bool
    var paneCount: Int
    var fontScale: Double
    var closeRequest: Int
    var onPageChanged: (Int, Int) -> Void
    var onTitleChanged: (Int, String) -> Void
    var onExitOverview: () -> Void
    var onFontScale: (Double) -> Void

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage where Data: ViewRenderData {
        let runtime = MobileShellRuntime.shared
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)!
        gtk_widget_set_hexpand(box, 1)
        gtk_widget_set_vexpand(box, 1)

        let carousel = adw_carousel_new()!
        gtk_widget_set_hexpand(carousel, 1)
        gtk_widget_set_vexpand(carousel, 1)
        adw_carousel_set_allow_long_swipes(OpaquePointer(carousel), 1)
        adw_carousel_set_allow_scroll_wheel(OpaquePointer(carousel), 0)
        gtk_widget_add_css_class(carousel, "mobile-carousel")
        runtime.carousel = OpaquePointer(carousel)

        let dots = adw_carousel_indicator_dots_new()!
        adw_carousel_indicator_dots_set_carousel(OpaquePointer(dots), OpaquePointer(carousel))

        gtk_box_append(cast(box), carousel)
        gtk_box_append(cast(box), dots)
        gtk_box_append(cast(box), ExtraKeys.build())

        // page-changed(carousel, index) — raw connect, the index is wanted.
        g_signal_connect_data(
            UnsafeMutableRawPointer(carousel), "page-changed",
            unsafeBitCast(mobilePageChanged, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        // Tap in overview picks the page under the pointer.
        let click = gtk_gesture_click_new()!
        gtk_event_controller_set_propagation_phase(
            click, GTK_PHASE_CAPTURE)
        g_signal_connect_data(
            UnsafeMutableRawPointer(click), "pressed",
            unsafeBitCast(mobileCarouselPressed, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(click), "released",
            unsafeBitCast(mobileCarouselReleased, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        gtk_widget_add_controller(carousel, click)

        MobileStyle.install()
        let storage = ViewStorage(OpaquePointer(box))
        sync(storage)
        return storage
    }

    func update<Data>(
        _ storage: ViewStorage, data: WidgetData, updateProperties: Bool, type: Data.Type
    ) where Data: ViewRenderData {
        sync(storage)
    }

    private func sync(_ storage: ViewStorage) {
        let runtime = MobileShellRuntime.shared
        runtime.onPageChanged = onPageChanged
        runtime.onTitleChanged = onTitleChanged
        runtime.onExitOverview = onExitOverview
        runtime.onFontScale = onFontScale
        guard let carousel = runtime.carousel else { return }

        if closeRequest != runtime.handledCloseRequest {
            runtime.handledCloseRequest = closeRequest
            runtime.closeCurrentPane()
        }
        while runtime.panes.count < paneCount {
            runtime.appendPane(fontScale: fontScale)
        }
        if runtime.fontScale != fontScale {
            runtime.fontScale = fontScale
            for pane in runtime.panes { vte_terminal_set_font_scale(pane.terminal, fontScale) }
        }
        if runtime.overview != overview {
            runtime.overview = overview
            adw_carousel_set_interactive(carousel, overview ? 1 : 0)
            adw_carousel_set_allow_mouse_drag(carousel, overview ? 1 : 0)
            adw_carousel_set_spacing(carousel, overview ? 24 : 0)
            let widget = UnsafeMutablePointer<GtkWidget>(carousel)
            if overview {
                gtk_widget_add_css_class(widget, "overview")
            } else {
                gtk_widget_remove_css_class(widget, "overview")
                runtime.focusCurrentTerminal()
            }
            for pane in runtime.panes {
                gtk_widget_set_can_target(pane.page, overview ? 0 : 1)
                let margin: Int32 = overview ? 20 : 0
                gtk_widget_set_margin_start(pane.page, margin)
                gtk_widget_set_margin_end(pane.page, margin)
                gtk_widget_set_margin_top(pane.page, overview ? 12 : 0)
                gtk_widget_set_margin_bottom(pane.page, overview ? 12 : 0)
            }
        }
    }
}

struct MobilePane {
    let page: UnsafeMutablePointer<GtkWidget>      // scrolled window (carousel child)
    let terminal: UnsafeMutablePointer<VteTerminal>
}

final class MobileShellRuntime {
    static let shared = MobileShellRuntime()

    var carousel: OpaquePointer?
    var panes: [MobilePane] = []
    var overview = false
    var fontScale = 1.0
    var handledCloseRequest = 0
    var pressOrigin: (Double, Double)?
    /// MOBILE_FIT_COLS (default 80, 0 = off): on the first pane's first
    /// map, pick the font scale that fits that many columns. 54 columns
    /// came out of 0.8 on a 392 px screen; TUIs and Claude Code want 80.
    var fitCols = Int(ProcessInfo.processInfo.environment["MOBILE_FIT_COLS"] ?? "") ?? 80
    var fitted = false
    var fitTicks = 0
    var fitPasses = 0

    func fitColumns() {
        guard fitCols > 0, !fitted, let terminal = currentTerminal else { return }
        let widget: UnsafeMutablePointer<GtkWidget> = cast(terminal)
        let width = Double(gtk_widget_get_width(widget))
        let charWidth = Double(vte_terminal_get_char_width(terminal))
        guard width > 0, charWidth > 0 else { return }
        // VTE cell widths are whole pixels and the pty resize lags the
        // font change, so: estimate once, then step the scale down until
        // the measured column count reaches the target (checked every
        // third tick to let the resize land). On 392 px the cells go
        // 5 px → 76 cols, 4 px → 95 cols; 80 exactly does not exist.
        let cols = Int(vte_terminal_get_column_count(terminal))
        fitPasses += 1
        if fitPasses % 3 != 1 { return }
        FileHandle.standardError.write(
            "fit pass=\(fitPasses) width=\(width) charWidth=\(charWidth) cols=\(cols) scale=\(fontScale)\n".data(using: .utf8)!)
        if fitPasses > 1, cols >= fitCols || fitPasses > 30 {
            fitted = true
            return
        }
        let scale = fitPasses == 1
            ? fontScale * width / (charWidth * Double(fitCols))
            : fontScale - 0.04
        onFontScale(max(0.3, min(2.0, (scale * 100).rounded(.down) / 100)))
    }
    var onPageChanged: (Int, Int) -> Void = { _, _ in }
    var onTitleChanged: (Int, String) -> Void = { _, _ in }
    var onExitOverview: () -> Void = {}
    var onFontScale: (Double) -> Void = { _ in }

    var currentIndex: Int {
        guard let carousel else { return 0 }
        let position = adw_carousel_get_position(carousel)
        return max(0, min(panes.count - 1, Int(position.rounded())))
    }

    var currentTerminal: UnsafeMutablePointer<VteTerminal>? {
        panes.isEmpty ? nil : panes[currentIndex].terminal
    }

    func appendPane(fontScale: Double) {
        guard let carousel else { return }
        guard let widget = vte_terminal_new() else { return }
        let terminal = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: VteTerminal.self)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        vte_terminal_set_scrollback_lines(terminal, 10_000)
        vte_terminal_set_size(terminal, 80, 24)
        vte_terminal_set_font_scale(terminal, fontScale)
        self.fontScale = fontScale

        let scrolled = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_child(OpaquePointer(scrolled), widget)
        gtk_scrolled_window_set_policy(OpaquePointer(scrolled), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scrolled, 1)
        gtk_widget_set_vexpand(scrolled, 1)
        gtk_widget_add_css_class(scrolled, "mobile-pane")
        gtk_widget_set_can_target(scrolled, overview ? 0 : 1)

        adw_carousel_append(carousel, scrolled)
        panes.append(MobilePane(page: scrolled, terminal: terminal))
        let index = panes.count - 1

        g_signal_connect_data(
            UnsafeMutableRawPointer(widget), "window-title-changed",
            unsafeBitCast(mobileTitleChanged, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        ExtraKeys.installStickyCtrl(on: widget)
        g_signal_connect_data(
            UnsafeMutableRawPointer(widget), "map",
            unsafeBitCast(mobileTerminalMapped, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        spawnShell(in: terminal)
        onPageChanged(currentIndex, panes.count)
        if panes.count > 1 {
            adw_carousel_scroll_to(carousel, scrolled, 1)
        }
        _ = index
    }

    func closeCurrentPane() {
        guard let carousel, !panes.isEmpty else { return }
        let index = currentIndex
        let pane = panes.remove(at: index)
        adw_carousel_remove(carousel, pane.page)
        onPageChanged(currentIndex, panes.count)
        focusCurrentTerminal()
    }

    func index(ofTerminal terminal: UnsafeMutableRawPointer) -> Int? {
        panes.firstIndex { UnsafeMutableRawPointer($0.terminal) == terminal }
    }

    func focusCurrentTerminal() {
        guard let terminal = currentTerminal else { return }
        gtk_widget_grab_focus(UnsafeMutableRawPointer(terminal).assumingMemoryBound(to: GtkWidget.self))
    }

    func feed(_ bytes: [UInt8]) {
        guard let terminal = currentTerminal else { return }
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                vte_terminal_feed_child(terminal, $0, buffer.count)
            }
        }
    }

    private func spawnShell(in terminal: UnsafeMutablePointer<VteTerminal>) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_MOBILE_SPIKE"] = "1"
        environment["TERM"] = "xterm-256color"
        let argv = cStringArray([shell])
        let envv = cStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer { g_strfreev(argv); g_strfreev(envv) }
        vte_terminal_spawn_async(
            terminal, VTE_PTY_DEFAULT, nil, argv, envv, G_SPAWN_DEFAULT,
            nil, nil, nil, -1, nil, nil, nil
        )
    }
}

func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (index, string) in strings.enumerated() { array[index] = strdup(string) }
    array[strings.count] = nil
    return array
}

let mobilePageChanged: @convention(c) (UnsafeMutableRawPointer?, UInt32, UnsafeMutableRawPointer?) -> Void
= { _, index, _ in
    let runtime = MobileShellRuntime.shared
    runtime.onPageChanged(Int(index), runtime.panes.count)
    if !runtime.overview { runtime.focusCurrentTerminal() }
}

/// First map: the width is allocated, fit the column target once.
let mobileTerminalMapped: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, _ in
    // map can precede the first allocation; retry a few frames.
    _ = g_timeout_add(120, mobileFitTick, nil)
}

let mobileFitTick: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in
    let runtime = MobileShellRuntime.shared
    runtime.fitColumns()
    runtime.fitTicks += 1
    return (runtime.fitted || runtime.fitTicks > 60) ? 0 : 1
}

let mobileTitleChanged: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { terminal, _ in
    guard let terminal else { return }
    let runtime = MobileShellRuntime.shared
    guard let index = runtime.index(ofTerminal: terminal) else { return }
    let vte = terminal.assumingMemoryBound(to: VteTerminal.self)
    guard let title = vte_terminal_get_window_title(vte) else { return }
    runtime.onTitleChanged(index, String(cString: title))
}

/// A click released on the carousel while in overview: pick the page
/// under the pointer and leave overview. (A swipe is a drag, not a click;
/// GtkGestureClick cancels on movement, so this never fires after one.)
let mobileCarouselPressed: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void
= { _, _, x, y, _ in
    MobileShellRuntime.shared.pressOrigin = (x, y)
}

let mobileCarouselReleased: @convention(c) (UnsafeMutableRawPointer?, Int32, Double, Double, UnsafeMutableRawPointer?) -> Void
= { _, _, x, y, _ in
    let runtime = MobileShellRuntime.shared
    guard runtime.overview, let carousel = runtime.carousel else { return }
    // A swipe also ends in "released" (the carousel's drag gesture runs in
    // parallel and does not cancel ours); only a stationary press is a tap.
    if let origin = runtime.pressOrigin, abs(origin.0 - x) > 12 || abs(origin.1 - y) > 12 { return }
    let width = Double(gtk_widget_get_width(UnsafeMutablePointer<GtkWidget>(carousel)))
    let position = adw_carousel_get_position(carousel)
    // Pages are one carousel width apart (+spacing); a tap left of the
    // centre third picks the previous page, right of it the next.
    var target = Int(position.rounded())
    if x < width / 3, position - Double(target) < 0.3 { target -= 1 }
    if x > width * 2 / 3, Double(target) - position < 0.3 { target += 1 }
    target = max(0, min(runtime.panes.count - 1, target))
    if target < runtime.panes.count {
        adw_carousel_scroll_to(carousel, runtime.panes[target].page, 1)
    }
    runtime.onExitOverview()
}

enum MobileStyle {
    static var installed = false
    static func install() {
        guard !installed else { return }
        installed = true
        let css = """
        .mobile-carousel.overview { background: @shade_color; }
        .mobile-carousel.overview .mobile-pane {
            border-radius: 12px;
            opacity: 0.85;
            box-shadow: 0 2px 8px rgba(0,0,0,0.35);
        }
        .mobile-keys { padding: 4px 6px; border-top: 1px solid @borders; }
        .mobile-keys button { min-width: 36px; min-height: 36px; padding: 0 8px; }
        """
        guard let provider = gtk_css_provider_new() else { return }
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            gdk_display_get_default(),
            OpaquePointer(provider),
            UInt32(GTK_STYLE_PROVIDER_PRIORITY_APPLICATION)
        )
    }
}

/// Pointer re-typing for the C importer: GTK types that are complete in
/// this header set come in typed, interfaces (GtkStyleProvider) and
/// controllers created by `*_new()` come in opaque.
func cast<T>(_ pointer: OpaquePointer) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
}
func cast<T, U>(_ pointer: UnsafeMutablePointer<U>) -> UnsafeMutablePointer<T> {
    UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: T.self)
}
