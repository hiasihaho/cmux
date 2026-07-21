import CAdw
import Foundation

/// Per-pane tab strips (AdwTabView + AdwTabBar).
///
/// A pane used to hold exactly one surface, so a second page — a popup, a
/// second browser tab — could only become another split, and every split
/// halved the space. Five popups were unreadable slivers. Panes now hold a
/// list of surfaces behind a tab strip, which is also what macOS does
/// (Bonsplit panes carry their own tabs).
///
/// `adw_tab_bar_set_autohide` is what makes this free for the common case:
/// a pane with one surface shows no tab bar at all and looks exactly as it
/// did before. No shim was needed — adwaita-swift ships a `CAdw` module
/// that exposes the raw Adwaita C API.
enum PaneTabs {

    /// Wraps a pane's surface containers in a tab view. Returns the widget
    /// to place in the split tree.
    static func build(
        pane: PaneLeaf,
        tabId: UUID,
        onSelected: @escaping (UUID, UUID, UUID) -> Void,
        onClosed: @escaping (UUID, UUID, UUID) -> Void
    ) -> UnsafeMutablePointer<GtkWidget>? {
        let containers = pane.surfaces.compactMap { surface in
            SurfaceRegistry.shared.containers[surface.surfaceId].map { (surface, $0) }
        }
        guard !containers.isEmpty else { return nil }

        // One surface: hand back the bare container. An AdwTabView with a
        // hidden bar would still add a layer to every pane in the tree for
        // no benefit, and this is by far the common case.
        if containers.count == 1, pane.surfaces.count == 1 {
            return UnsafeMutablePointer<GtkWidget>(containers[0].1)
        }

        guard let tabView = adw_tab_view_new(),
              let bar = adw_tab_bar_new(),
              let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) else { return nil }

        for (surface, container) in containers {
            let widget = UnsafeMutablePointer<GtkWidget>(container)
            guard let page = adw_tab_view_append(tabView, widget) else { continue }
            adw_tab_page_set_title(page, tabTitle(for: surface))
        }
        if pane.safeIndex < Int(adw_tab_view_get_n_pages(tabView)),
           let page = adw_tab_view_get_nth_page(tabView, Int32(pane.safeIndex)) {
            adw_tab_view_set_selected_page(tabView, page)
        }

        adw_tab_bar_set_view(bar, tabView)
        adw_tab_bar_set_autohide(bar, 0)   // shown: this pane really has tabs

        let state = PaneTabsState(
            tabId: tabId, paneId: pane.paneId,
            surfaceIds: containers.map { $0.0.surfaceId },
            onSelected: onSelected, onClosed: onClosed
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(tabView), "notify::selected-page",
            unsafeBitCast(paneTabsSelectionChanged, to: GCallback.self),
            Unmanaged.passRetained(state).toOpaque(),
            paneTabsStateDestroy, GConnectFlags(0)
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(tabView), "close-page",
            unsafeBitCast(paneTabsClosePage, to: GCallback.self),
            Unmanaged.passRetained(state).toOpaque(),
            paneTabsStateDestroy, GConnectFlags(0)
        )

        gtk_box_append(
            UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self),
            UnsafeMutableRawPointer(bar).assumingMemoryBound(to: GtkWidget.self)
        )
        gtk_box_append(
            UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self),
            UnsafeMutableRawPointer(tabView).assumingMemoryBound(to: GtkWidget.self)
        )
        gtk_widget_set_hexpand(box, 1)
        gtk_widget_set_vexpand(box, 1)
        return box
    }

    /// Tab labels: the page title for browsers, the directory for shells.
    /// A live title beats the spawn-time guess where one exists.
    static func tabTitle(for surface: PaneSurface) -> String {
        switch surface.kind {
        case .browser:
            if let title = SurfaceRegistry.shared.currentBrowserTitle(for: surface.surfaceId),
               !title.isEmpty {
                return title
            }
            return SurfaceRegistry.shared.currentURL(for: surface.surfaceId) ?? "Browser"
        case .inspector:
            return "DevTools"
        case .terminal:
            let cwd = SurfaceRegistry.shared.currentDirectory(for: surface.surfaceId)
                ?? surface.workingDirectory
            return (cwd as NSString).lastPathComponent.isEmpty
                ? cwd : (cwd as NSString).lastPathComponent
        }
    }
}

/// Carries pane identity across the C callbacks, which may not capture.
final class PaneTabsState {
    let tabId: UUID
    let paneId: UUID
    let surfaceIds: [UUID]
    let onSelected: (UUID, UUID, UUID) -> Void
    let onClosed: (UUID, UUID, UUID) -> Void

    init(
        tabId: UUID, paneId: UUID, surfaceIds: [UUID],
        onSelected: @escaping (UUID, UUID, UUID) -> Void,
        onClosed: @escaping (UUID, UUID, UUID) -> Void
    ) {
        self.tabId = tabId
        self.paneId = paneId
        self.surfaceIds = surfaceIds
        self.onSelected = onSelected
        self.onClosed = onClosed
    }
}

let paneTabsStateDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<PaneTabsState>.fromOpaque(data).release()
}

/// The user clicked a tab — mirror it into the model so the socket verbs
/// and the widget never disagree about which surface a pane is showing.
let paneTabsSelectionChanged: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { viewPtr, _, userData in
    guard let viewPtr, let userData else { return }
    let state = Unmanaged<PaneTabsState>.fromOpaque(userData).takeUnretainedValue()
    let tabView = OpaquePointer(viewPtr)
    guard let page = adw_tab_view_get_selected_page(tabView) else { return }
    let index = Int(adw_tab_view_get_page_position(tabView, page))
    guard index >= 0, index < state.surfaceIds.count else { return }
    state.onSelected(state.tabId, state.paneId, state.surfaceIds[index])
}

/// Closing a tab must go through the model, not just drop the page, or the
/// surface stays registered and the pane tree keeps a surface nothing
/// renders. Returning FALSE tells AdwTabView we handle the removal.
let paneTabsClosePage: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Int32 = { viewPtr, pagePtr, userData in
    guard let viewPtr, let pagePtr, let userData else { return 0 }
    let state = Unmanaged<PaneTabsState>.fromOpaque(userData).takeUnretainedValue()
    let index = Int(adw_tab_view_get_page_position(OpaquePointer(viewPtr), OpaquePointer(pagePtr)))
    guard index >= 0, index < state.surfaceIds.count else { return 1 }
    state.onClosed(state.tabId, state.paneId, state.surfaceIds[index])
    return 1   // GDK_EVENT_STOP: the model drives the actual removal
}
