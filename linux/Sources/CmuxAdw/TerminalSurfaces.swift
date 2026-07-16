import Adwaita
import CVte
import Foundation

/// Main-thread map of surface → live widget (VTE terminal or WebKit view,
/// plus the container that goes into the pane tree), used by the control
/// protocol and for pane-tree reparenting. Containers are stored as
/// `OpaquePointer` so files bound to different GTK-importing C modules
/// (CVte, CWebKit) can share them without type clashes.
final class SurfaceRegistry {

    static let shared = SurfaceRegistry()

    private(set) var terminals: [UUID: UnsafeMutablePointer<VteTerminal>] = [:]
    private(set) var browsers: [UUID: OpaquePointer] = [:]
    private(set) var containers: [UUID: OpaquePointer] = [:]
    private var spawnTimes: [UUID: Date] = [:]
    private var lastBellTimes: [UUID: Date] = [:]

    func registerTerminal(
        _ terminal: UnsafeMutablePointer<VteTerminal>,
        container: OpaquePointer,
        for surfaceId: UUID
    ) {
        terminals[surfaceId] = terminal
        containers[surfaceId] = container
        spawnTimes[surfaceId] = Date()
    }

    /// Bell policy — shell startup banners (fastfetch & friends) often emit
    /// BEL, and agents can ring in bursts; macOS coalesces these too.
    enum BellVerdict {
        /// Within the post-spawn grace period — ignore entirely.
        case suppress
        /// Burst continuation — refresh the attention dot, no new entry.
        case coalesce
        /// A genuine, reportable bell.
        case notify
    }

    func bellVerdict(for surfaceId: UUID) -> BellVerdict {
        let now = Date()
        defer { lastBellTimes[surfaceId] = now }
        if let spawned = spawnTimes[surfaceId], now.timeIntervalSince(spawned) < 2 {
            return .suppress
        }
        if let last = lastBellTimes[surfaceId], now.timeIntervalSince(last) < 1 {
            return .coalesce
        }
        return .notify
    }

    func registerBrowser(
        _ webView: OpaquePointer,
        container: OpaquePointer,
        for surfaceId: UUID
    ) {
        browsers[surfaceId] = webView
        containers[surfaceId] = container
    }

    func unregister(_ surfaceId: UUID) {
        terminals.removeValue(forKey: surfaceId)
        browsers.removeValue(forKey: surfaceId)
        containers.removeValue(forKey: surfaceId)
        spawnTimes.removeValue(forKey: surfaceId)
        lastBellTimes.removeValue(forKey: surfaceId)
    }

    func terminal(for surfaceId: UUID) -> UnsafeMutablePointer<VteTerminal>? {
        terminals[surfaceId]
    }

    func browser(for surfaceId: UUID) -> OpaquePointer? {
        browsers[surfaceId]
    }

    /// Shell working directory reported via OSC 7 (vte.sh), if any.
    func currentDirectory(for surfaceId: UUID) -> String? {
        guard let terminal = terminals[surfaceId],
              let uri = vte_terminal_get_current_directory_uri(terminal),
              let path = g_filename_from_uri(uri, nil, nil) else { return nil }
        defer { g_free(path) }
        return String(cString: path)
    }
}

/// A GtkStack with one child per tab; each child is the tab's pane tree
/// (nested GtkPaned) with a VTE terminal leaf per surface. All children are
/// managed imperatively: terminals stay alive across tab switches and pane
/// rearrangements (the paned skeleton is rebuilt, terminals are reparented).
struct TerminalStackWidget: AdwaitaWidget {

    var tabs: [TerminalTab]
    var selection: UUID
    var onTitleChanged: (UUID, UUID, String) -> Void
    var onBell: (UUID, UUID) -> Void
    var onSurfaceFocused: (UUID, UUID) -> Void

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage where Data: ViewRenderData {
        let stack = gtk_stack_new()
        gtk_widget_set_hexpand(stack, 1)
        gtk_widget_set_vexpand(stack, 1)
        let storage = ViewStorage(OpaquePointer(stack))
        sync(storage)
        return storage
    }

    func update<Data>(
        _ storage: ViewStorage,
        data: WidgetData,
        updateProperties: Bool,
        type: Data.Type
    ) where Data: ViewRenderData {
        sync(storage)
    }

    // MARK: tree management

    private func sync(_ storage: ViewStorage) {
        guard let stack = storage.opaquePointer else { return }
        var shapes = storage.fields["tab-shapes"] as? [UUID: String] ?? [:]

        // Widgets for every leaf (new tabs and fresh splits alike).
        for tab in tabs {
            for leaf in tab.surfaces where SurfaceRegistry.shared.containers[leaf.surfaceId] == nil {
                switch leaf.kind {
                case .terminal:
                    createTerminal(for: leaf, in: tab, storage: storage)
                case .browser:
                    BrowserSurfaceFactory.create(
                        for: leaf,
                        in: tab,
                        storage: storage,
                        onTitleChanged: onTitleChanged,
                        onSurfaceFocused: onSurfaceFocused
                    )
                }
            }
        }

        // Drop registry entries for surfaces that no longer exist anywhere.
        let liveSurfaces = Set(tabs.flatMap { $0.surfaces.map(\.surfaceId) })
        for surfaceId in SurfaceRegistry.shared.containers.keys where !liveSurfaces.contains(surfaceId) {
            SurfaceRegistry.shared.unregister(surfaceId)
        }

        // Remove stack children of closed tabs.
        let liveTabs = Set(tabs.map(\.id))
        for tabId in shapes.keys where !liveTabs.contains(tabId) {
            if let child = gtk_stack_get_child_by_name(stack, tabId.uuidString) {
                gtk_stack_remove(stack, child)
            }
            shapes.removeValue(forKey: tabId)
        }

        // (Re)build pane skeletons where the layout shape changed.
        for tab in tabs {
            let signature = tab.layout.shapeSignature
            let existing = gtk_stack_get_child_by_name(stack, tab.id.uuidString)
            guard shapes[tab.id] != signature || existing == nil else { continue }

            // Keep live surface containers alive across the rebuild and
            // detach them from their old parents — GtkPaned refuses children
            // that are still parented elsewhere, and a silently rejected
            // child dies with the old skeleton (dangling registry pointers).
            for leaf in tab.surfaces {
                if let container = SurfaceRegistry.shared.containers[leaf.surfaceId] {
                    g_object_ref_sink(UnsafeMutableRawPointer(container))
                    detachFromParent(UnsafeMutablePointer<GtkWidget>(container))
                }
            }
            // Preserve dragged divider positions across the rebuild (keyed
            // by tree path; paths in unchanged subtrees keep their spot).
            var dividers: [String: Int32] = [:]
            captureDividerPositions(existing, path: "", into: &dividers)

            // A single-leaf tab's stack child IS the container — the detach
            // above already removed it from the stack in that case.
            if let existing,
               let parent = gtk_widget_get_parent(existing),
               OpaquePointer(parent) == stack {
                gtk_stack_remove(stack, existing)
            }
            if let root = buildNode(tab.layout) {
                gtk_stack_add_named(stack, root, tab.id.uuidString)
                restoreDividerPositions(root, path: "", from: dividers)
            }
            for leaf in tab.surfaces {
                if let container = SurfaceRegistry.shared.containers[leaf.surfaceId] {
                    g_object_unref(UnsafeMutableRawPointer(container))
                }
            }
            shapes[tab.id] = signature
        }
        storage.fields["tab-shapes"] = shapes

        if let tab = tabs.first(where: { $0.id == selection }) {
            gtk_stack_set_visible_child_name(stack, tab.id.uuidString)
            if let focused = tab.focusedSurface {
                if let terminal = SurfaceRegistry.shared.terminal(for: focused.surfaceId) {
                    gtk_widget_grab_focus(asWidget(terminal))
                } else if let container = SurfaceRegistry.shared.containers[focused.surfaceId] {
                    gtk_widget_grab_focus(UnsafeMutablePointer<GtkWidget>(container))
                }
            }
        }
    }

    private func captureDividerPositions(
        _ widget: UnsafeMutablePointer<GtkWidget>?,
        path: String,
        into positions: inout [String: Int32]
    ) {
        guard let widget, isA(widget, gtk_paned_get_type()) else { return }
        let paned = OpaquePointer(widget)
        positions[path] = gtk_paned_get_position(paned)
        captureDividerPositions(gtk_paned_get_start_child(paned), path: path + "0", into: &positions)
        captureDividerPositions(gtk_paned_get_end_child(paned), path: path + "1", into: &positions)
    }

    private func restoreDividerPositions(
        _ widget: UnsafeMutablePointer<GtkWidget>?,
        path: String,
        from positions: [String: Int32]
    ) {
        guard let widget, isA(widget, gtk_paned_get_type()) else { return }
        let paned = OpaquePointer(widget)
        if let position = positions[path], position > 0 {
            gtk_paned_set_position(paned, position)
        }
        restoreDividerPositions(gtk_paned_get_start_child(paned), path: path + "0", from: positions)
        restoreDividerPositions(gtk_paned_get_end_child(paned), path: path + "1", from: positions)
    }

    private func detachFromParent(_ widget: UnsafeMutablePointer<GtkWidget>) {
        guard let parent = gtk_widget_get_parent(widget) else { return }
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
    }

    private func isA(_ widget: UnsafeMutablePointer<GtkWidget>, _ type: GType) -> Bool {
        g_type_check_instance_is_a(
            UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GTypeInstance.self),
            type
        ) != 0
    }

    private func buildNode(_ node: PaneNode) -> UnsafeMutablePointer<GtkWidget>? {
        switch node {
        case .leaf(let leaf):
            return SurfaceRegistry.shared.containers[leaf.surfaceId]
                .map { UnsafeMutablePointer<GtkWidget>($0) }
        case .split(let orientation, let first, let second):
            let paned = gtk_paned_new(
                orientation == .horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL
            )
            let handle = OpaquePointer(paned)
            gtk_paned_set_start_child(handle, buildNode(first))
            gtk_paned_set_end_child(handle, buildNode(second))
            gtk_paned_set_wide_handle(handle, 1)
            gtk_widget_set_hexpand(paned, 1)
            gtk_widget_set_vexpand(paned, 1)
            return paned
        }
    }

    private func createTerminal(for leaf: PaneLeaf, in tab: TerminalTab, storage: ViewStorage) {
        guard let widget = vte_terminal_new() else { return }
        let terminal = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: VteTerminal.self)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        vte_terminal_set_scrollback_lines(terminal, 10_000)

        guard let scrolled = gtk_scrolled_window_new() else { return }
        gtk_scrolled_window_set_child(OpaquePointer(scrolled), widget)
        gtk_widget_set_hexpand(scrolled, 1)
        gtk_widget_set_vexpand(scrolled, 1)

        spawnShell(in: terminal, leaf: leaf, tab: tab)
        SurfaceRegistry.shared.registerTerminal(terminal, container: OpaquePointer(scrolled), for: leaf.surfaceId)
        connectSignals(for: leaf, in: tab, terminal: terminal, widget: widget, storage: storage)
    }

    private func connectSignals(
        for leaf: PaneLeaf,
        in tab: TerminalTab,
        terminal: UnsafeMutablePointer<VteTerminal>,
        widget: UnsafeMutablePointer<GtkWidget>,
        storage: ViewStorage
    ) {
        let tabId = tab.id
        let surfaceId = leaf.surfaceId
        let onTitleChanged = onTitleChanged
        let onBell = onBell
        let onSurfaceFocused = onSurfaceFocused

        storage.connectSignal(
            name: "window-title-changed",
            id: "title-\(surfaceId.uuidString)",
            pointer: OpaquePointer(terminal)
        ) {
            if let title = vte_terminal_get_window_title(terminal) {
                onTitleChanged(tabId, surfaceId, String(cString: title))
            }
        }
        storage.connectSignal(
            name: "bell",
            id: "bell-\(surfaceId.uuidString)",
            pointer: OpaquePointer(terminal)
        ) {
            onBell(tabId, surfaceId)
        }

        if let controller = gtk_event_controller_focus_new() {
            gtk_widget_add_controller(widget, controller)
            storage.connectSignal(
                name: "enter",
                id: "focus-\(surfaceId.uuidString)",
                pointer: controller
            ) {
                onSurfaceFocused(tabId, surfaceId)
            }
        }
    }

    /// Spawns the user's shell with the cmux environment (workspace/surface
    /// identity + socket path), mirroring the macOS terminal environment.
    private func spawnShell(
        in terminal: UnsafeMutablePointer<VteTerminal>,
        leaf: PaneLeaf,
        tab: TerminalTab
    ) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_WORKSPACE_ID"] = tab.id.uuidString
        environment["CMUX_SURFACE_ID"] = leaf.surfaceId.uuidString
        environment["CMUX_SOCKET_PATH"] = ControlSocketServer.shared.path

        let argv = cStringArray([shell])
        let envv = cStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer {
            g_strfreev(argv)
            g_strfreev(envv)
        }

        vte_terminal_spawn_async(
            terminal,
            VTE_PTY_DEFAULT,
            leaf.workingDirectory,
            argv,
            envv,
            G_SPAWN_DEFAULT,
            nil, nil, nil,
            -1,
            nil, nil, nil
        )
    }

    private func asWidget(_ terminal: UnsafeMutablePointer<VteTerminal>) -> UnsafeMutablePointer<GtkWidget> {
        UnsafeMutableRawPointer(terminal).assumingMemoryBound(to: GtkWidget.self)
    }

    /// NULL-terminated, strdup'd C string array (freed with `g_strfreev`;
    /// VTE's spawn copies the arrays before returning).
    private func cStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
        let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
        for (index, string) in strings.enumerated() {
            array[index] = strdup(string)
        }
        array[strings.count] = nil
        return array
    }
}
