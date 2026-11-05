import Adwaita
import CAdw
import Foundation

// Mobile breakpoint (POC 0004 step 3 — the mobile mode in cmux-adw). A tiny
// invisible widget placed in the view tree finds the toplevel window on
// realize and watches its allocated width; when the width crosses a threshold
// it reports isMobile up to the app, which then rearranges the layout
// (sidebar → overview, pane tree → carousel). Verified on the DESKTOP by
// resizing the window narrow/wide — no phone needed to iterate.
//
// We watch the WINDOW width, not the content area, on purpose: hiding the
// sidebar in mobile mode widens the content, and measuring the content would
// feed back and oscillate across the threshold. The window width does not
// move when the sidebar collapses.

/// Carries the app's callback into the C notify handler, which cannot capture.
/// Held alive by ViewStorage.fields for the widget's lifetime; the callbacks
/// take it unretained, so there is no destroy-notify to balance.
final class BreakpointBox {
    var onChange: (Bool) -> Void
    let threshold: Int32
    var last: Bool?
    init(threshold: Int32, onChange: @escaping (Bool) -> Void) {
        self.threshold = threshold
        self.onChange = onChange
    }

    /// width 0 means "not allocated yet" — ignore it so we never flip to a
    /// bogus mobile state before the window has a size.
    func evaluate(width: Int32) {
        guard width > 0 else { return }
        let isMobile = width < threshold
        guard last != isMobile else { return }
        last = isMobile
        onChange(isMobile)
    }
}

/// notify::default-width on the toplevel GtkWindow. `object` is the window.
let breakpointWidthChanged: @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?
) -> Void = { object, _, userData in
    guard let object, let userData else { return }
    let box = Unmanaged<BreakpointBox>.fromOpaque(userData).takeUnretainedValue()
    let widget = object.assumingMemoryBound(to: GtkWidget.self)
    box.evaluate(width: gtk_widget_get_width(widget))
}

/// The observer widget is realized → its root is the window. Hook the window's
/// width and take one reading now.
let breakpointRealized: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, UnsafeMutableRawPointer?
) -> Void = { widget, userData in
    guard let widget, let userData, let root = gtk_widget_get_root(widget) else { return }
    let windowRaw = UnsafeMutableRawPointer(root)
    // connect notify::default-width (fires as the user resizes the window)
    g_signal_connect_data(
        windowRaw, "notify::default-width",
        unsafeBitCast(breakpointWidthChanged, to: GCallback.self),
        userData, nil, GConnectFlags(0))
    let box = Unmanaged<BreakpointBox>.fromOpaque(userData).takeUnretainedValue()
    box.evaluate(width: gtk_widget_get_width(windowRaw.assumingMemoryBound(to: GtkWidget.self)))
}

/// Zero-size, invisible. Lives in the view tree only to reach the window and
/// report the mobile breakpoint; it draws nothing and takes no space.
struct WindowBreakpointObserver: AdwaitaWidget {
    var threshold: Int32 = 600
    var onChange: (Bool) -> Void

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage
        where Data: ViewRenderData {
        let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_set_size_request(box, 0, 0)
        gtk_widget_set_halign(box, GTK_ALIGN_START)
        gtk_widget_set_valign(box, GTK_ALIGN_START)
        let storage = ViewStorage(OpaquePointer(box))
        let state = BreakpointBox(threshold: threshold, onChange: onChange)
        storage.fields["breakpoint-box"] = state
        g_signal_connect_data(
            UnsafeMutableRawPointer(box!), "realize",
            unsafeBitCast(breakpointRealized, to: GCallback.self),
            Unmanaged.passUnretained(state).toOpaque(), nil, GConnectFlags(0))
        return storage
    }

    func update<Data>(
        _ storage: ViewStorage,
        data: WidgetData,
        updateProperties: Bool,
        type: Data.Type
    ) where Data: ViewRenderData {
        // Keep the stored callback current so it always sets the latest app
        // state binding (the closure itself just assigns a Bool, but refresh
        // defensively in case a future version captures more).
        (storage.fields["breakpoint-box"] as? BreakpointBox)?.onChange = onChange
    }
}

// MARK: - Fullscreen state

/// Reports the toplevel window's fullscreen state, kept honest when the user
/// toggles fullscreen outside our button (F11, Escape, the compositor). Lets
/// the header-bar icon show enter-vs-leave correctly in both desktop and
/// mobile. Toggle the state with `UIDialogs.toggleFullscreen()`.
final class FullscreenBox {
    var onChange: (Bool) -> Void
    var last: Bool?
    init(onChange: @escaping (Bool) -> Void) { self.onChange = onChange }
    func report(_ value: Bool) {
        guard last != value else { return }
        last = value
        onChange(value)
    }
}

let fullscreenNotify: @convention(c) (
    UnsafeMutableRawPointer?, OpaquePointer?, UnsafeMutableRawPointer?
) -> Void = { object, _, userData in
    guard let object, let userData else { return }
    let box = Unmanaged<FullscreenBox>.fromOpaque(userData).takeUnretainedValue()
    let window = object.assumingMemoryBound(to: GtkWindow.self)
    box.report(gtk_window_is_fullscreen(window) != 0)
}

let fullscreenRealized: @convention(c) (
    UnsafeMutablePointer<GtkWidget>?, UnsafeMutableRawPointer?
) -> Void = { widget, userData in
    guard let widget, let userData, let root = gtk_widget_get_root(widget) else { return }
    g_signal_connect_data(
        UnsafeMutableRawPointer(root), "notify::fullscreened",
        unsafeBitCast(fullscreenNotify, to: GCallback.self),
        userData, nil, GConnectFlags(0))
    let box = Unmanaged<FullscreenBox>.fromOpaque(userData).takeUnretainedValue()
    let window = UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWindow.self)
    box.report(gtk_window_is_fullscreen(window) != 0)
}

/// Zero-size; only reports the window's fullscreen state up to the app.
struct WindowFullscreenObserver: AdwaitaWidget {
    var onChange: (Bool) -> Void

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage
        where Data: ViewRenderData {
        let box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0)
        gtk_widget_set_size_request(box, 0, 0)
        gtk_widget_set_halign(box, GTK_ALIGN_START)
        gtk_widget_set_valign(box, GTK_ALIGN_START)
        let storage = ViewStorage(OpaquePointer(box))
        let state = FullscreenBox(onChange: onChange)
        storage.fields["fullscreen-box"] = state
        g_signal_connect_data(
            UnsafeMutableRawPointer(box!), "realize",
            unsafeBitCast(fullscreenRealized, to: GCallback.self),
            Unmanaged.passUnretained(state).toOpaque(), nil, GConnectFlags(0))
        return storage
    }

    func update<Data>(
        _ storage: ViewStorage,
        data: WidgetData,
        updateProperties: Bool,
        type: Data.Type
    ) where Data: ViewRenderData {
        (storage.fields["fullscreen-box"] as? FullscreenBox)?.onChange = onChange
    }
}
