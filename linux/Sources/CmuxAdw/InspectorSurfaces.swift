import Adwaita
import CWebKit
import Foundation

/// Web Inspector (DevTools) hosted in a cmux pane — roadmap/06 increment 3.
///
/// The WebKitGTK inspector is awkward to embed, and the awkwardness is not
/// obvious from the API. Probed empirically (2026-07-21) against
/// webkitgtk-6.0 2.52.4:
///
/// - `webkit_web_inspector_get_web_view()` returns **NULL** both before and
///   after `webkit_web_inspector_show()`. The widget exists **only inside
///   the `attach` signal handler**. So the pane must already exist when
///   `show()` is called — there is no "create it, then fetch the widget".
/// - The returned object is a `WebKitWebViewBase`, and `WEBKIT_IS_WEB_VIEW`
///   on it is **false**. It is a GtkWidget but NOT a WebKitWebView, so it
///   must never go through the browser surface factory, which calls
///   `webkit_web_view_*` on what it adopts.
/// - Returning TRUE from `attach` claims responsibility for placement;
///   returning TRUE from `open-window` suppresses the separate window.
///
/// Hence the flow: create an empty container pane → let the factory
/// register it → connect the signals → `show()` → reparent the widget the
/// `attach` handler hands us into that container.
enum InspectorSurfaceFactory {

    static func create(
        for leaf: PaneLeaf,
        in tab: TerminalTab,
        storage: ViewStorage,
        onSurfaceFocused: @escaping (UUID, UUID) -> Void
    ) {
        // An empty box that the inspector widget gets reparented into once
        // WebKit surrenders it. Registered immediately so `show()` — which
        // fires `attach` synchronously — always finds a home.
        guard let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) else { return }
        gtk_widget_set_hexpand(box, 1)
        gtk_widget_set_vexpand(box, 1)

        let tabId = tab.id
        let surfaceId = leaf.surfaceId
        if let controller = gtk_event_controller_focus_new() {
            gtk_widget_add_controller(box, controller)
            storage.connectSignal(
                name: "enter",
                id: "inspector-focus-\(surfaceId.uuidString)",
                pointer: controller
            ) {
                onSurfaceFocused(tabId, surfaceId)
            }
        }

        SurfaceRegistry.shared.registerInspector(
            container: OpaquePointer(box),
            for: surfaceId
        )

        // The pane exists now; hand it to whoever asked for the inspector.
        if let pending = InspectorAdoption.pending.removeValue(forKey: surfaceId) {
            pending()
        }
    }
}

/// Callbacks parked by `browser.inspect` until the factory has built the
/// pane. Same shape (and the same reason) as `BrowserAdoption`: an Adwaita
/// model mutation can run the surface factory before the mutating call
/// returns, so the work that needs the container must be registered first
/// and run from the factory, never assumed to be safe afterwards.
enum InspectorAdoption {
    static var pending: [UUID: () -> Void] = [:]
}

/// The inspector embedding has several places it can silently do nothing
/// (signal never fires, WebKit hands back NULL, widget lands with no size),
/// so the path is traced to the app log rather than guessed at.
func inspectorLog(_ message: String) {
    FileHandle.standardError.write(Data("cmux inspector: \(message)\n".utf8))
}

/// Carries the destination container across the C `attach` callback, which
/// may not capture Swift context.
final class InspectorAttachBox {
    /// Filled in once the surface factory has built the pane.
    var container: OpaquePointer?
    let surfaceId: UUID
    /// Set by the `attach` handler. Read back by `browser.inspect` so the
    /// verb can report whether DevTools really landed instead of returning
    /// a bare OK for an empty pane.
    var attached = false
    init(surfaceId: UUID) {
        self.surfaceId = surfaceId
    }
}

/// Moves the inspector's widget into our pane. Shared by both signals:
/// WebKit picks `attach` or `open-window` depending on whether it thinks it
/// can dock, and which one it picks is not under our control (the isolated
/// probe got `attach`; inside cmux's pane tree it emits `open-window`).
/// Claiming only one of them is how the pane ended up empty.
private func placeInspector(_ inspector: OpaquePointer, _ box: InspectorAttachBox, from signal: String) -> Int32 {
    guard let container = box.container else {
        inspectorLog("\(signal): no container — cannot place inspector")
        return 0
    }
    guard let view = webkit_web_inspector_get_web_view(inspector) else {
        // Nothing to place: let WebKit fall back to its own handling rather
        // than swallowing the signal and showing the user an empty pane.
        inspectorLog("\(signal): get_web_view returned NULL — declining")
        return 0
    }
    let widget = UnsafeMutableRawPointer(view).assumingMemoryBound(to: GtkWidget.self)
    gtk_widget_set_hexpand(widget, 1)
    gtk_widget_set_vexpand(widget, 1)
    // Reparenting a widget that still has a parent is a hard GTK error.
    if let existing = gtk_widget_get_parent(widget) {
        gtk_widget_unparent(widget)
        _ = existing
    }
    gtk_box_append(
        UnsafeMutableRawPointer(container).assumingMemoryBound(to: GtkBox.self),
        widget
    )
    gtk_widget_set_visible(widget, 1)
    box.attached = true
    inspectorLog("\(signal): inspector widget placed into pane \(box.surfaceId)")
    // "Placed" is not "visible": a widget can land with a zero allocation
    // and render as a blank pane, which looks identical to not working.
    scheduleOnMainLoop(afterMs: 700) {
        inspectorLog("post-attach allocation: \(gtk_widget_get_width(widget))x\(gtk_widget_get_height(widget))"
            + " mapped=\(gtk_widget_get_mapped(widget))")
    }
    return 1
}

/// `attach`: WebKit is asking where to dock the inspector.
let inspectorAttach: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Int32 = { inspectorPtr, userData in
    guard let inspectorPtr, let userData else { return 0 }
    let box = Unmanaged<InspectorAttachBox>.fromOpaque(userData).takeUnretainedValue()
    inspectorLog("attach signal fired")
    return placeInspector(OpaquePointer(inspectorPtr), box, from: "attach")
}

/// `open-window`: WebKit wants a separate DevTools window. We take the
/// widget instead — returning TRUE only counts as "handled" if we really
/// did place it, otherwise the user gets a suppressed window AND an empty
/// pane, which is worse than either alone.
let inspectorOpenWindow: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Int32 = { inspectorPtr, userData in
    guard let inspectorPtr, let userData else { return 0 }
    let box = Unmanaged<InspectorAttachBox>.fromOpaque(userData).takeUnretainedValue()
    inspectorLog("open-window signal fired")
    return placeInspector(OpaquePointer(inspectorPtr), box, from: "open-window")
}

let inspectorAttachBoxDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<InspectorAttachBox>.fromOpaque(data).release()
}
