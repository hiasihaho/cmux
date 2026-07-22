import CAdw
import Foundation

/// Per-pane tab strips (AdwTabView + AdwTabBar).
///
/// A pane used to hold exactly one surface, so a second page — a popup, a
/// second browser tab — could only become another split, and every split
/// halved the space. Panes now hold a list of surfaces behind a tab strip,
/// which is also what macOS does (Bonsplit panes carry their own tabs).
/// No shim was needed: adwaita-swift ships a `CAdw` module exposing the
/// raw Adwaita C API.
///
/// **The tab view is persistent, and that is load-bearing.** The first
/// version rebuilt it from scratch on every layout change, which looked
/// fine and was silently broken: a pane's surface containers live *inside*
/// the AdwTabView, `detachFromParent` only knows GtkStack and GtkPaned
/// parents, so on rebuild the containers were never detached and the
/// following `adw_tab_view_append` refused them — four surfaces rendered
/// as one tab. Keeping the view and reconciling its pages means the widget
/// being reparented is the wrapper, whose parent really is a paned or the
/// stack.
///
/// Removing a page must go through `adw_tab_view_close_page`, which emits
/// `close-page` — and our handler for that closes the *surface*. So
/// programmatic removal sets `isReconciling`, which the handler checks;
/// without that distinction a rebuild would delete the user's tabs.
enum PaneTabs {

    /// Live tab views, keyed by pane. Survives layout rebuilds.
    private static var views: [UUID: PaneTabsView] = [:]

    /// True while pages are being reconciled against the model, so the
    /// close-page handler does not mistake it for a user closing a tab.
    static var isReconciling = false

    static func build(
        pane: PaneLeaf,
        tabId: UUID,
        onSelected: @escaping (UUID, UUID, UUID) -> Void,
        onClosed: @escaping (UUID, UUID, UUID) -> Void
    ) -> UnsafeMutablePointer<GtkWidget>? {
        // Fast path: a single-surface pane that has never had tabs stays a
        // bare container — no AdwTabView in the tree at all, so the common
        // case costs nothing. Once a pane has had tabs it keeps its view
        // (bar auto-hidden at one page), because moving the container back
        // out would reintroduce the detach problem.
        if pane.surfaces.count == 1, views[pane.paneId] == nil {
            return SurfaceRegistry.shared.containers[pane.surfaces[0].surfaceId]
                .map { UnsafeMutablePointer<GtkWidget>($0) }
        }

        let view: PaneTabsView
        if let existing = views[pane.paneId] {
            view = existing
        } else {
            guard let created = PaneTabsView(
                tabId: tabId, paneId: pane.paneId, onSelected: onSelected, onClosed: onClosed
            ) else { return nil }
            views[pane.paneId] = created
            view = created
        }
        view.reconcile(with: pane)
        return view.wrapper
    }

    static func wrapper(for paneId: UUID) -> UnsafeMutablePointer<GtkWidget>? {
        views[paneId]?.wrapper
    }

    /// Drops views for panes that no longer exist, so a closed pane does
    /// not keep its tab view (and its surface containers) alive forever.
    static func prune(livePaneIds: Set<UUID>) {
        for (paneId, view) in views where !livePaneIds.contains(paneId) {
            view.destroy()
            views.removeValue(forKey: paneId)
        }
    }

    /// Tab labels: the page title for browsers, the directory for shells.
    /// User-pinned tab titles (`tab.action rename`); while set, OSC/URL
    /// updates stop overwriting — the per-surface analog of the
    /// workspace's customTitle. Persisted in the v3 session snapshot.
    static var customTitles: [UUID: String] = [:]

    static func tabTitle(for surface: PaneSurface) -> String {
        if let pinned = customTitles[surface.surfaceId] { return pinned }
        switch surface.kind {
        case .browser:
            if let title = SurfaceRegistry.shared.currentBrowserTitle(for: surface.surfaceId),
               !title.isEmpty {
                return title
            }
            if let url = SurfaceRegistry.shared.currentURL(for: surface.surfaceId), !url.isEmpty {
                return url
            }
            return "Browser"
        case .inspector:
            return "DevTools"
        case .terminal:
            let cwd = SurfaceRegistry.shared.currentDirectory(for: surface.surfaceId)
                ?? surface.workingDirectory
            let last = (cwd as NSString).lastPathComponent
            return last.isEmpty ? cwd : last
        }
    }

    /// Refreshes one surface's tab label. A page title arrives after the
    /// page exists and is not a model change, so without this the newest
    /// tab keeps whatever placeholder it was created with.
    static func refreshTitle(surfaceId: UUID) {
        for (_, view) in views { view.refreshTitle(surfaceId: surfaceId) }
    }

    /// Refreshes every pane's tab titles. A freshly adopted popup has no
    /// title *and* no URL at the moment its page is created, so without
    /// this its tab reads the literal "Browser" forever.
    static func refreshAllTitles(tabs: [TerminalTab]) {
        for tab in tabs {
            for pane in tab.panes {
                views[pane.paneId]?.refreshTitles(pane.surfaces)
            }
        }
    }
}

/// One pane's live tab view: the wrapper placed in the split tree, the
/// AdwTabView inside it, and the surface→page mapping.
final class PaneTabsView {
    let wrapper: UnsafeMutablePointer<GtkWidget>
    let tabView: OpaquePointer
    private let state: PaneTabsState
    private var pages: [UUID: OpaquePointer] = [:]

    init?(
        tabId: UUID, paneId: UUID,
        onSelected: @escaping (UUID, UUID, UUID) -> Void,
        onClosed: @escaping (UUID, UUID, UUID) -> Void
    ) {
        guard let tabViewWidget = adw_tab_view_new(),
              let bar = adw_tab_bar_new(),
              let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) else { return nil }
        self.tabView = tabViewWidget
        self.wrapper = box
        self.state = PaneTabsState(tabId: tabId, paneId: paneId,
                                   onSelected: onSelected, onClosed: onClosed)

        adw_tab_bar_set_view(bar, tabViewWidget)
        // Auto-hide: a pane down to one tab looks exactly like a pane that
        // never had any.
        adw_tab_bar_set_autohide(bar, 1)
        gtk_box_append(
            UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self),
            UnsafeMutableRawPointer(bar).assumingMemoryBound(to: GtkWidget.self)
        )
        gtk_box_append(
            UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self),
            UnsafeMutableRawPointer(tabViewWidget).assumingMemoryBound(to: GtkWidget.self)
        )
        gtk_widget_set_hexpand(box, 1)
        gtk_widget_set_vexpand(box, 1)
        // The wrapper outlives layout rebuilds, so it holds its own ref.
        g_object_ref_sink(UnsafeMutableRawPointer(box))

        g_signal_connect_data(
            UnsafeMutableRawPointer(tabViewWidget), "notify::selected-page",
            unsafeBitCast(paneTabsSelectionChanged, to: GCallback.self),
            Unmanaged.passRetained(state).toOpaque(),
            paneTabsStateDestroy, GConnectFlags(0)
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(tabViewWidget), "close-page",
            unsafeBitCast(paneTabsClosePage, to: GCallback.self),
            Unmanaged.passRetained(state).toOpaque(),
            paneTabsStateDestroy, GConnectFlags(0)
        )
    }

    /// Brings the pages in line with the model: drop what is gone, append
    /// what is new, order and title them, and select the right one.
    func reconcile(with pane: PaneLeaf) {
        let wanted = pane.surfaces.map(\.surfaceId)
        let wantedSet = Set(wanted)

        for (surfaceId, page) in pages where !wantedSet.contains(surfaceId) {
            PaneTabs.isReconciling = true
            adw_tab_view_close_page(tabView, page)
            PaneTabs.isReconciling = false
            pages.removeValue(forKey: surfaceId)
        }

        for (index, surface) in pane.surfaces.enumerated() {
            if pages[surface.surfaceId] == nil {
                guard let container = SurfaceRegistry.shared.containers[surface.surfaceId] else {
                    continue
                }
                let widget = UnsafeMutablePointer<GtkWidget>(container)
                // append refuses a widget that still has a parent, and the
                // failure is silent — that is what produced the one-tab bug.
                if gtk_widget_get_parent(widget) != nil {
                    gtk_widget_unparent(widget)
                }
                guard let page = adw_tab_view_append(tabView, widget) else { continue }
                pages[surface.surfaceId] = page
            }
            if let page = pages[surface.surfaceId] {
                adw_tab_page_set_title(page, PaneTabs.tabTitle(for: surface))
                adw_tab_view_reorder_page(tabView, page, Int32(index))
            }
        }

        state.surfaceIds = wanted
        if let page = pages[pane.selected.surfaceId] {
            PaneTabs.isReconciling = true
            adw_tab_view_set_selected_page(tabView, page)
            PaneTabs.isReconciling = false
        }
    }

    func refreshTitle(surfaceId: UUID) {
        guard let page = pages[surfaceId] else { return }
        let title = PaneTabs.customTitles[surfaceId]
            ?? SurfaceRegistry.shared.currentBrowserTitle(for: surfaceId)
            ?? SurfaceRegistry.shared.currentURL(for: surfaceId)
            ?? "Browser"
        adw_tab_page_set_title(page, title)
    }

    func refreshTitles(_ surfaces: [PaneSurface]) {
        for surface in surfaces {
            guard let page = pages[surface.surfaceId] else { continue }
            adw_tab_page_set_title(page, PaneTabs.tabTitle(for: surface))
        }
    }

    func destroy() {
        for (_, page) in pages {
            PaneTabs.isReconciling = true
            adw_tab_view_close_page(tabView, page)
            PaneTabs.isReconciling = false
        }
        pages.removeAll()
        if gtk_widget_get_parent(wrapper) != nil {
            gtk_widget_unparent(wrapper)
        }
        g_object_unref(UnsafeMutableRawPointer(wrapper))
    }
}

/// Carries pane identity across the C callbacks, which may not capture.
final class PaneTabsState {
    let tabId: UUID
    let paneId: UUID
    /// Kept in sync by `reconcile`, so a callback always maps a page
    /// position onto the surface that is actually there.
    var surfaceIds: [UUID] = []
    let onSelected: (UUID, UUID, UUID) -> Void
    let onClosed: (UUID, UUID, UUID) -> Void

    init(
        tabId: UUID, paneId: UUID,
        onSelected: @escaping (UUID, UUID, UUID) -> Void,
        onClosed: @escaping (UUID, UUID, UUID) -> Void
    ) {
        self.tabId = tabId
        self.paneId = paneId
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
    guard let viewPtr, let userData, !PaneTabs.isReconciling else { return }
    let state = Unmanaged<PaneTabsState>.fromOpaque(userData).takeUnretainedValue()
    let tabView = OpaquePointer(viewPtr)
    guard let page = adw_tab_view_get_selected_page(tabView) else { return }
    let index = Int(adw_tab_view_get_page_position(tabView, page))
    guard index >= 0, index < state.surfaceIds.count else { return }
    state.onSelected(state.tabId, state.paneId, state.surfaceIds[index])
}

/// Closing a tab must go through the model, not just drop the page, or the
/// surface stays registered and the pane keeps a surface nothing renders.
/// Returning TRUE claims the close; the model-driven reconcile then removes
/// the page. During reconcile we return FALSE so libadwaita really removes
/// it — without that distinction a rebuild would close the user's surfaces.
let paneTabsClosePage: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Int32 = { viewPtr, pagePtr, userData in
    if PaneTabs.isReconciling { return 0 }
    guard let viewPtr, let pagePtr, let userData else { return 0 }
    let state = Unmanaged<PaneTabsState>.fromOpaque(userData).takeUnretainedValue()
    let index = Int(adw_tab_view_get_page_position(OpaquePointer(viewPtr), OpaquePointer(pagePtr)))
    guard index >= 0, index < state.surfaceIds.count else { return 1 }
    state.onClosed(state.tabId, state.paneId, state.surfaceIds[index])
    return 1   // GDK_EVENT_STOP: the model drives the actual removal
}

// MARK: - pane.zoom

extension ControlCommandHandler {

    /// `pane.zoom` — mirrors macOS's "Toggle Pane Zoom" command. Exposed
    /// over the socket as well as the shortcut so the feature is testable
    /// without a screenshot, and so an agent can use it.
    func v2PaneZoom(id: Any?, params: [String: Any]) -> String {
        let registry = RefRegistry.shared
        let surfaceId: UUID? = (params["surface_id"] as? String)
            .flatMap { UUID(uuidString: $0) ?? registry.resolve($0) }
        let wsId = (params["workspace_id"] as? String)
            .flatMap { UUID(uuidString: $0) ?? registry.resolve($0) }
            ?? surfaceId.flatMap { sid in tabs.wrappedValue.first { $0.contains(surfaceId: sid) }?.id }
            ?? selection.wrappedValue
        guard let tab = tabs.wrappedValue.first(where: { $0.id == wsId }) else {
            return v2ZoomError(id: id, code: "not_found", message: "Workspace not found")
        }
        guard let zoomed = toggleZoom(tabId: tab.id, surfaceId: surfaceId) else {
            // Nil means it un-zoomed; distinguish that from "no such pane".
            guard tab.focusedSurface != nil else {
                return v2ZoomError(id: id, code: "not_found", message: "Pane not found")
            }
            return v2ZoomOk(id: id, result: [
                "workspace_id": tab.id.uuidString,
                "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
                "zoomed": false
            ])
        }
        return v2ZoomOk(id: id, result: [
            "workspace_id": tab.id.uuidString,
            "workspace_ref": registry.ref(kind: "workspace", uuid: tab.id),
            "surface_id": zoomed.uuidString,
            "surface_ref": registry.ref(kind: "surface", uuid: zoomed),
            "zoomed": true
        ])
    }

    fileprivate func v2ZoomOk(id: Any?, result: [String: Any]) -> String {
        v2ZoomEncode(["id": id ?? NSNull(), "ok": true, "result": result])
    }
    fileprivate func v2ZoomError(id: Any?, code: String, message: String) -> String {
        v2ZoomEncode(["id": id ?? NSNull(), "ok": false, "error": ["code": code, "message": message]])
    }
    fileprivate func v2ZoomEncode(_ object: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":{\"code\":\"encode_error\",\"message\":\"Failed to encode JSON\"}}"
        }
        return string.replacingOccurrences(of: "\n", with: "\\n")
    }
}
