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

    /// Reverse page→surface lookup for the drag-reorder handler, which
    /// only has the pane's id and the page pointer.
    static func surfaceId(paneId: UUID, page: OpaquePointer) -> UUID? {
        views[paneId]?.surfaceId(forPage: page)
    }

    /// True while pages are being reconciled against the model, so the
    /// close-page handler does not mistake it for a user closing a tab.
    static var isReconciling = false

    static func build(
        pane: PaneLeaf,
        tabId: UUID,
        onSelected: @escaping (UUID, UUID, UUID) -> Void,
        onClosed: @escaping (UUID, UUID, UUID) -> Void,
        onReordered: @escaping (UUID, UUID, UUID, Int) -> Void
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
                tabId: tabId, paneId: pane.paneId,
                onSelected: onSelected, onClosed: onClosed, onReordered: onReordered
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
    /// Unparents a surface's container out of its tab page so the page's
    /// destruction cannot take the widget (and a Ghostty shell) with it.
    /// "Live" = still in the registry: surfaces removed from the model are
    /// unregistered in the same sync pass, moves are not.
    static func detachIfLive(_ surfaceId: UUID) {
        guard let container = SurfaceRegistry.shared.containers[surfaceId] else { return }
        detachWidget(UnsafeMutablePointer<GtkWidget>(container))
    }

    /// Removes a widget from its parent with the CORRECT per-parent call.
    /// Raw gtk_widget_unparent out of a GtkPaned leaves the paned's
    /// internal child pointer set — destroying the paned later disposes
    /// the "removed" child anyway, which is how a moved Ghostty pane's
    /// shell kept dying ("pty fd closed") behind a seemingly safe detach.
    static func detachWidget(_ widget: UnsafeMutablePointer<GtkWidget>) {
        guard let parent = gtk_widget_get_parent(widget) else { return }
        func isA(_ w: UnsafeMutablePointer<GtkWidget>, _ type: GType) -> Bool {
            g_type_check_instance_is_a(
                UnsafeMutableRawPointer(w).assumingMemoryBound(to: GTypeInstance.self), type
            ) != 0
        }
        if isA(parent, gtk_stack_get_type()) {
            gtk_stack_remove(OpaquePointer(parent), widget)
        } else if isA(parent, gtk_paned_get_type()) {
            let paned = OpaquePointer(parent)
            if gtk_paned_get_start_child(paned) == widget {
                gtk_paned_set_start_child(paned, nil)
            } else if gtk_paned_get_end_child(paned) == widget {
                gtk_paned_set_end_child(paned, nil)
            }
        }
        // Any other parent (AdwTabView internals, most importantly) is
        // NOT detached here: ripping a page's child out from under the
        // tab view segfaults the later close_page. Tabbed panes are
        // relocated safely by the reconciliation itself.
    }

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

    /// Themed icon per surface type (MACOS-UX §2.2: terminal.fill /
    /// globe / devtools) — the fallback when a browser has no favicon.
    static func tabIconName(for kind: SurfaceKind) -> String {
        switch kind {
        case .terminal: return "utilities-terminal-symbolic"
        case .browser: return "web-browser-symbolic"
        case .inspector: return "applications-engineering-symbolic"
        }
    }

    /// End-action button pressed on a pane's tab bar: (action id, tabId,
    /// paneId). Wired by CmuxApp to the shared handler paths. Actions:
    /// new_terminal, new_browser, split_right, split_down (the macOS
    /// default four).
    static var onEndAction: ((String, UUID, UUID) -> Void)?

    /// Render-truth for the suite: what icon the surface's tab page
    /// actually carries — a themed icon name, or "favicon" for a texture.
    static func iconDescription(surfaceId: UUID) -> String? {
        for (_, view) in views {
            if let description = view.iconDescription(surfaceId: surfaceId) {
                return description
            }
        }
        return nil
    }

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
    /// Surface kind per page, recorded at reconcile — the icon chooser
    /// must not guess from registry dictionaries (ghostty terminals are
    /// not in the VTE dict; that guess cost a wrong DevTools icon).
    private var kinds: [UUID: SurfaceKind] = [:]

    init?(
        tabId: UUID, paneId: UUID,
        onSelected: @escaping (UUID, UUID, UUID) -> Void,
        onClosed: @escaping (UUID, UUID, UUID) -> Void,
        onReordered: @escaping (UUID, UUID, UUID, Int) -> Void
    ) {
        guard let tabViewWidget = adw_tab_view_new(),
              let bar = adw_tab_bar_new(),
              let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0) else { return nil }
        self.tabView = tabViewWidget
        self.wrapper = box
        self.state = PaneTabsState(tabId: tabId, paneId: paneId,
                                   onSelected: onSelected, onClosed: onClosed,
                                   onReordered: onReordered)

        adw_tab_bar_set_view(bar, tabViewWidget)
        // Auto-hide: a pane down to one tab looks exactly like a pane that
        // never had any.
        adw_tab_bar_set_autohide(bar, 1)
        // End-action buttons (mirror ⑤, the macOS default four). They
        // appear whenever the bar does (2+ tabs, per autohide above).
        if let actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0) {
            let actionsBox = UnsafeMutableRawPointer(actions)
                .assumingMemoryBound(to: GtkBox.self)
            let buttons: [(String, String, String)] = [
                ("new_terminal", "utilities-terminal-symbolic", "New Terminal Tab"),
                ("new_browser", "web-browser-symbolic", "New Browser Tab"),
                ("split_right", "view-dual-symbolic", "Split Right"),
                ("split_down", "view-paged-symbolic", "Split Down")
            ]
            for (action, icon, tooltip) in buttons {
                guard let button = gtk_button_new_from_icon_name(icon) else { continue }
                gtk_widget_add_css_class(button, "flat")
                gtk_widget_set_tooltip_text(button, tooltip)
                let box = PaneEndActionBox(state: state, action: action)
                g_signal_connect_data(
                    UnsafeMutableRawPointer(button), "clicked",
                    unsafeBitCast(paneTabsEndAction, to: GCallback.self),
                    Unmanaged.passRetained(box).toOpaque(),
                    paneEndActionBoxDestroy, GConnectFlags(0)
                )
                gtk_box_append(actionsBox, button)
            }
            adw_tab_bar_set_end_action_widget(bar, actions)
        }
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
        // A user drag emits this per position change. Without the handler
        // the drag was accepted visually and silently reverted by the next
        // reconcile — the model never heard about it (GAPS Now, found by
        // the 2026-07-22 UX survey).
        g_signal_connect_data(
            UnsafeMutableRawPointer(tabViewWidget), "page-reordered",
            unsafeBitCast(paneTabsPageReordered, to: GCallback.self),
            Unmanaged.passRetained(state).toOpaque(),
            paneTabsStateDestroy, GConnectFlags(0)
        )
    }

    /// One end-action button's target: which action for which pane.
final class PaneEndActionBox {
    let state: PaneTabsState
    let action: String
    init(state: PaneTabsState, action: String) {
        self.state = state
        self.action = action
    }
}

let paneEndActionBoxDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<PaneEndActionBox>.fromOpaque(data).release()
}

let paneTabsEndAction: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { _, userData in
    guard let userData else { return }
    let box = Unmanaged<PaneEndActionBox>.fromOpaque(userData).takeUnretainedValue()
    PaneTabs.onEndAction?(box.action, box.state.tabId, box.state.paneId)
}

/// Reverse page→surface lookup for the reorder handler.
    func surfaceId(forPage page: OpaquePointer) -> UUID? {
        pages.first { $0.value == page }?.key
    }

    /// Brings the pages in line with the model: drop what is gone, append
    /// what is new, order and title them, and select the right one.
    func reconcile(with pane: PaneLeaf) {
        let wanted = pane.surfaces.map(\.surfaceId)
        let wantedSet = Set(wanted)

        for (surfaceId, page) in pages where !wantedSet.contains(surfaceId) {
            // A surface leaving THIS pane may be moving to another one
            // (surface.move, pane.break/join) — close_page DESTROYS the
            // page child, and destroying a Ghostty widget kills its shell
            // ("pty fd closed"). Detach the container first when the
            // surface is still registered; a genuinely closed surface is
            // unregistered in the same sync and gets destroyed as before.
            PaneTabs.detachIfLive(surfaceId)
            PaneTabs.isReconciling = true
            adw_tab_view_close_page(tabView, page)
            PaneTabs.isReconciling = false
            pages.removeValue(forKey: surfaceId)
            kinds.removeValue(forKey: surfaceId)
        }

        for (index, surface) in pane.surfaces.enumerated() {
            // A respawned surface keeps its id but has a NEW container
            // (surface.respawn: replace-and-replay); the page still holds
            // the old widget. Close the stale page — close_page is the
            // correct teardown for tab children and destroys the old
            // widget — so the append branch below mounts the replacement.
            if let page = pages[surface.surfaceId],
               let container = SurfaceRegistry.shared.containers[surface.surfaceId],
               adw_tab_page_get_child(page) != UnsafeMutablePointer<GtkWidget>(container) {
                PaneTabs.isReconciling = true
                adw_tab_view_close_page(tabView, page)
                PaneTabs.isReconciling = false
                pages.removeValue(forKey: surface.surfaceId)
            }
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
                kinds[surface.surfaceId] = surface.kind
                syncDecor(page: page, surfaceId: surface.surfaceId)
                pages[surface.surfaceId] = page
            }
            if let page = pages[surface.surfaceId] {
                adw_tab_page_set_title(page, PaneTabs.tabTitle(for: surface))
                // reorder_page EMITS page-reordered — guard it, or every
                // reconcile echoes back into the drag handler.
                PaneTabs.isReconciling = true
                adw_tab_view_reorder_page(tabView, page, Int32(index))
                PaneTabs.isReconciling = false
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
        syncDecor(page: page, surfaceId: surfaceId)
    }

    func refreshTitles(_ surfaces: [PaneSurface]) {
        for surface in surfaces {
            guard let page = pages[surface.surfaceId] else { continue }
            adw_tab_page_set_title(page, PaneTabs.tabTitle(for: surface))
            syncDecor(page: page, surfaceId: surface.surfaceId)
        }
    }

    /// Tab icon + loading spinner (mirror ⑤): a browser page carries its
    /// live favicon (a GdkTexture — it implements GIcon) or the themed
    /// browser icon; terminals and DevTools their themed icons; browser
    /// loads show AdwTabBar's native spinner.
    func syncDecor(page: OpaquePointer, surfaceId: UUID) {
        let registry = SurfaceRegistry.shared
        if let favicon = registry.currentFavicon(for: surfaceId) {
            adw_tab_page_set_icon(page, favicon)
        } else if let kind = kinds[surfaceId],
                  let themed = g_themed_icon_new(PaneTabs.tabIconName(for: kind)) {
            adw_tab_page_set_icon(page, themed)
            g_object_unref(UnsafeMutableRawPointer(themed))
        }
        adw_tab_page_set_loading(
            page, registry.isBrowserLoading(for: surfaceId) ? 1 : 0)
    }

    /// Render-truth for debug.surfaces: the themed name the page's icon
    /// serializes to, or "favicon" for a texture icon.
    func iconDescription(surfaceId: UUID) -> String? {
        guard let page = pages[surfaceId] else { return nil }
        guard let icon = adw_tab_page_get_icon(page) else { return nil }
        guard let serialized = g_icon_to_string(icon) else { return "favicon" }
        defer { g_free(serialized) }
        return String(cString: serialized)
    }

    func destroy() {
        for (surfaceId, page) in pages {
            PaneTabs.detachIfLive(surfaceId)
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
    let onReordered: (UUID, UUID, UUID, Int) -> Void

    init(
        tabId: UUID, paneId: UUID,
        onSelected: @escaping (UUID, UUID, UUID) -> Void,
        onClosed: @escaping (UUID, UUID, UUID) -> Void,
        onReordered: @escaping (UUID, UUID, UUID, Int) -> Void
    ) {
        self.tabId = tabId
        self.paneId = paneId
        self.onSelected = onSelected
        self.onClosed = onClosed
        self.onReordered = onReordered
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

/// `page-reordered` (page, new position). Fires per position change while
/// the user drags — and ALSO for every programmatic `reorder_page`, which
/// is why reconcile wraps its ordering pass in `isReconciling`.
let paneTabsPageReordered: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, UnsafeMutableRawPointer?
) -> Void = { _, pagePtr, position, userData in
    if PaneTabs.isReconciling { return }
    guard let pagePtr, let userData else { return }
    let state = Unmanaged<PaneTabsState>.fromOpaque(userData).takeUnretainedValue()
    guard let surfaceId = PaneTabs.surfaceId(paneId: state.paneId, page: OpaquePointer(pagePtr)) else { return }
    state.onReordered(state.tabId, state.paneId, surfaceId, Int(position))
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
