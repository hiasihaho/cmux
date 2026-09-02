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
    /// Embedded Ghostty surface widgets (experimental CMUX_TERM=ghostty
    /// mode) — GhosttySurface GtkWidgets held opaquely like browsers.
    private(set) var ghosttys: [UUID: OpaquePointer] = [:]
    private(set) var containers: [UUID: OpaquePointer] = [:]
    /// Last non-empty cwd seen per surface — see `currentDirectory`.
    private var lastKnownDirectories: [UUID: String] = [:]
    private var spawnTimes: [UUID: Date] = [:]
    private var lastBellTimes: [UUID: Date] = [:]

    /// The registry holds STRONG GObject refs on every stored widget:
    /// entries are queried from timers (15s session autosave → OSC 7 cwd)
    /// that can otherwise race widget destruction — a dangling VteTerminal
    /// pointer segfaulted the app inside `vte_terminal_get_current_directory_uri`
    /// (coredump 2026-07-17 00:06). A ref'd widget may be destroyed
    /// (disposed) but its memory stays valid until we unref in
    /// `unregister`, so getters degrade to nil instead of crashing.
    private func retain(_ pointer: OpaquePointer) {
        // ref_SINK, not ref: registered widgets arrive floating (fresh,
        // unparented), and g_object_ref on a floating object does NOT
        // take ownership — the first parent's own ref_sink consumes the
        // floating ref, leaving the registry's "strong ref" imaginary.
        // The tell: detaching a moved pane from its GtkPaned destroyed it
        // on the spot (parent held the only real ref), killing the shell.
        g_object_ref_sink(UnsafeMutableRawPointer(pointer))
    }

    private func release(_ pointer: OpaquePointer?) {
        if let pointer {
            g_object_unref(UnsafeMutableRawPointer(pointer))
        }
    }

    func registerTerminal(
        _ terminal: UnsafeMutablePointer<VteTerminal>,
        container: OpaquePointer,
        for surfaceId: UUID
    ) {
        retain(OpaquePointer(terminal))
        retain(container)
        terminals[surfaceId] = terminal
        containers[surfaceId] = container
        spawnTimes[surfaceId] = Date()
    }

    /// Child pids reported by VTE's spawn callback, so respawn can kill
    /// the old process deterministically instead of hoping the pty-close
    /// SIGHUP reaches a shell that may ignore it.
    private var childPids: [UUID: pid_t] = [:]

    func setChildPid(_ pid: pid_t, for surfaceId: UUID) {
        if pid > 0 { childPids[surfaceId] = pid }
    }

    /// The child pid behind a surface, for either backend — VTE reports it
    /// through its spawn callback, Ghostty through the shim's
    /// `ghostty_embed_surface_pid`. nil means "not knowable", never a
    /// guess: no child yet, it exited, or (Ghostty under Flatpak) the
    /// child lives on the host in another pid namespace. Callers that
    /// attribute OS processes to panes must treat nil as unknown rather
    /// than as "no processes".
    func childPid(for surfaceId: UUID) -> pid_t? {
        if let pid = childPids[surfaceId] { return pid }
        return ghosttyChildPid(for: surfaceId)
    }

    /// tmux `respawn-pane -k` semantics for a VTE pane: kill the current
    /// child and start `command` in the SAME VteTerminal — scrollback
    /// survives, the process does not. Ghostty panes are refused by the
    /// caller (the shim owns their spawn; roadmap/05).
    func respawnTerminal(
        surfaceId: UUID,
        workspaceId: UUID,
        command: String,
        workingDirectory: String?
    ) -> Bool {
        guard let terminal = terminals[surfaceId] else { return false }
        if let pid = childPids.removeValue(forKey: surfaceId) {
            kill(pid, SIGKILL)
        }
        let cmuxEnv = [
            "CMUX_WORKSPACE_ID": workspaceId.uuidString,
            "CMUX_SURFACE_ID": surfaceId.uuidString,
            "CMUX_SOCKET_PATH": ControlSocketServer.shared.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.merge(cmuxEnv) { _, new in new }
        let argv = cmuxCStringArray(FlatpakEnv.spawnArgv(
            ["/bin/sh", "-c", command], cwd: workingDirectory, extraEnv: cmuxEnv))
        let envv = cmuxCStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer {
            g_strfreev(argv)
            g_strfreev(envv)
        }
        spawnTimes[surfaceId] = Date()
        vte_terminal_spawn_async(
            terminal,
            VTE_PTY_DEFAULT,
            workingDirectory,
            argv,
            envv,
            G_SPAWN_DEFAULT,
            nil, nil, nil,
            -1,
            nil,
            vteSpawnPidCallback,
            Unmanaged.passRetained(SpawnPidBox(surfaceId)).toOpaque()
        )
        return true
    }

    func registerGhostty(
        _ widget: OpaquePointer,
        container: OpaquePointer,
        for surfaceId: UUID
    ) {
        retain(widget)
        retain(container)
        ghosttys[surfaceId] = widget
        containers[surfaceId] = container
        spawnTimes[surfaceId] = Date()
    }

    func ghostty(for surfaceId: UUID) -> OpaquePointer? {
        ghosttys[surfaceId]
    }

    /// Command/cwd override for the NEXT widget created for a surface id —
    /// the handoff from surface.respawn (which tears the old widget down)
    /// to the factory (which mounts the replacement, macOS-style).
    private var pendingGhosttyRespawns: [UUID: (command: String, workingDirectory: String?)] = [:]

    func setPendingRespawn(_ command: String, workingDirectory: String?, for surfaceId: UUID) {
        pendingGhosttyRespawns[surfaceId] = (command, workingDirectory)
    }

    func takePendingRespawn(for surfaceId: UUID) -> (command: String, workingDirectory: String?)? {
        pendingGhosttyRespawns.removeValue(forKey: surfaceId)
    }

    /// Eager background spawn: the shim starts a surface's shell when its
    /// widget is REALIZED, and GTK only realizes stack children when they
    /// are first shown — so panes in never-shown workspaces had no shell
    /// until first selection and agents sending to them got `unavailable`.
    /// Realizing an anchored hidden widget is legal (GTK realizes the
    /// ancestor chain first) and does NOT map it: the shell starts, the
    /// renderer stays dormant until the workspace is shown. Idempotent;
    /// runs at the end of every sync.
    func realizeHiddenGhosttys() {
        for (surfaceId, widget) in ghosttys {
            let w = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GtkWidget.self)
            guard gtk_widget_get_mapped(w) == 0, gtk_widget_get_root(w) != nil else { continue }
            // Always walk the SUBTREE: the bin can be realized while the
            // GLArea inside is not (AdwTabView page churn does this), and
            // gtk_widget_realize is idempotent — a top-level realized
            // check would skip exactly the widget that needs it.
            realizeSubtree(w)
            // The sizing half: GTK never allocates hidden stack children,
            // so realize alone leaves the shim's init waiting for a size
            // that never comes. ensure_started spawns at a stand-in grid;
            // the real resize corrects it on first map. Idempotent.
            ghosttyEnsureStarted(for: surfaceId)
        }
    }

    /// gtk_widget_realize realizes ANCESTORS, never children — and the
    /// shim's lazy init hooks the GLArea's own realize, several levels
    /// below the registered bin. Walk the subtree.
    private func realizeSubtree(_ widget: UnsafeMutablePointer<GtkWidget>) {
        gtk_widget_realize(widget)
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            realizeSubtree(current)
            child = gtk_widget_get_next_sibling(current)
        }
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
        retain(webView)
        retain(container)
        browsers[surfaceId] = webView
        containers[surfaceId] = container
    }

    /// Inspector panes own only their container: the DevTools widget itself
    /// belongs to WebKit and is reparented in later by the `attach` handler,
    /// so there is no second pointer for us to hold.
    func registerInspector(
        container: OpaquePointer,
        for surfaceId: UUID
    ) {
        retain(container)
        containers[surfaceId] = container
    }

    func unregister(_ surfaceId: UUID) {
        if let terminal = terminals.removeValue(forKey: surfaceId) {
            release(OpaquePointer(terminal))
        }
        release(browsers.removeValue(forKey: surfaceId))
        release(ghosttys.removeValue(forKey: surfaceId))
        release(containers.removeValue(forKey: surfaceId))
        spawnTimes.removeValue(forKey: surfaceId)
        lastKnownDirectories.removeValue(forKey: surfaceId)
        lastBellTimes.removeValue(forKey: surfaceId)
        BrowserElementRefs.shared.clear(for: surfaceId)
        BrowserFrameSelectors.shared.clear(for: surfaceId)
        BrowserConsoleLog.shared.clearAll(for: surfaceId)
        BrowserAdoption.pending.removeValue(forKey: surfaceId)
    }

    func terminal(for surfaceId: UUID) -> UnsafeMutablePointer<VteTerminal>? {
        terminals[surfaceId]
    }

    func browser(for surfaceId: UUID) -> OpaquePointer? {
        browsers[surfaceId]
    }

    /// Widget-lifecycle state of one surface — the doctor's stethoscope.
    /// Every field here is something a debugging round has needed and
    /// hand-instrumented at least once (parent type at detach time,
    /// realized/mapped for spawn-gating, refcount for ownership bugs).
    func doctorReport(for surfaceId: UUID) -> [String: Any] {
        var report: [String: Any] = ["surface_id": surfaceId.uuidString]
        if terminals[surfaceId] != nil { report["backend"] = "vte" }
        else if ghosttys[surfaceId] != nil { report["backend"] = "ghostty" }
        else if browsers[surfaceId] != nil { report["backend"] = "browser" }
        else { report["backend"] = "none" }
        if let container = containers[surfaceId] {
            let widget = UnsafeMutablePointer<GtkWidget>(container)
            report["container_refs"] = Int(
                UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self).pointee.ref_count)
            report["realized"] = gtk_widget_get_realized(widget) != 0
            report["mapped"] = gtk_widget_get_mapped(widget) != 0
            // The attention system (AttentionStyle) speaks entirely in CSS
            // classes — reporting them makes rings and split-dimming
            // assertable by the suites instead of screenshot-only.
            if let classes = gtk_widget_get_css_classes(widget) {
                var list: [String] = []
                var index = 0
                while let item = classes[index] {
                    list.append(String(cString: item))
                    index += 1
                }
                report["css_classes"] = list
                g_strfreev(classes)
            }
            if let parent = gtk_widget_get_parent(widget) {
                report["parent_type"] = String(cString: g_type_name(
                    UnsafeMutableRawPointer(parent)
                        .assumingMemoryBound(to: GTypeInstance.self).pointee.g_class.pointee.g_type))
            } else {
                report["parent_type"] = "none"
            }
        } else {
            report["container"] = "unregistered"
        }
        report["readable"] = scrollbackText(for: surfaceId) != nil
        return report
    }

    /// Live window title of a terminal surface (OSC 0/2).
    func currentTerminalTitle(for surfaceId: UUID) -> String? {
        #if canImport(CGhosttyEmbed)
        if ghosttys[surfaceId] != nil {
            return currentGhosttyTitle(for: surfaceId)
        }
        #endif
        guard let terminal = terminals[surfaceId],
              let title = vte_terminal_get_window_title(terminal) else { return nil }
        let string = String(cString: title)
        return string.isEmpty ? nil : string
    }

    /// Full-buffer text of a VTE surface — scrollback plus screen, up to
    /// the cursor. The vertical adjustment's `lower` is the earliest row
    /// VTE still holds; rows are absolute and only grow. The adjustment is
    /// read as the GtkScrollable interface *property* — CVte's view of GTK
    /// does not surface the GtkScrollable cast type.
    func vteScrollbackText(for surfaceId: UUID) -> String? {
        guard let terminal = terminals[surfaceId] else { return nil }
        var cursorCol: glong = 0
        var cursorRow: glong = 0
        vte_terminal_get_cursor_position(terminal, &cursorCol, &cursorRow)
        var startRow: glong = 0
        var adjustmentValue = GValue()
        _ = g_value_init(&adjustmentValue, gtk_adjustment_get_type())
        g_object_get_property(
            UnsafeMutableRawPointer(terminal).assumingMemoryBound(to: GObject.self),
            "vadjustment", &adjustmentValue
        )
        if let raw = g_value_get_object(&adjustmentValue) {
            let adjustment = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: GtkAdjustment.self)
            startRow = glong(gtk_adjustment_get_lower(adjustment))
        }
        g_value_unset(&adjustmentValue)
        guard let raw = vte_terminal_get_text_range_format(
            terminal, VTE_FORMAT_TEXT, startRow, 0, cursorRow, -1, nil
        ) else { return nil }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// Feeds bytes to a VTE terminal as terminal OUTPUT — parsed and
    /// drawn, never handed to the shell. The VTE analog of the Ghostty
    /// fork's `inject_output`.
    @discardableResult
    func vteWriteDisplay(for surfaceId: UUID, text: String) -> Bool {
        guard let terminal = terminals[surfaceId], !text.isEmpty else { return false }
        let bytes = Array(text.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            buffer.baseAddress?.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                vte_terminal_feed(terminal, $0, buffer.count)
            }
        }
        return true
    }

    // MARK: backend-neutral scrollback dispatch (used by TerminalScrollback)

    /// Whichever backend holds the surface answers; nil means "could not
    /// read", which callers must not confuse with "empty".
    func scrollbackText(for surfaceId: UUID) -> String? {
        ghosttyReadText(for: surfaceId, includeScrollback: true)
            ?? vteScrollbackText(for: surfaceId)
    }

    /// True once the surface can accept a replay. Ghostty surfaces need to
    /// be mapped (their terminal starts on first map); a VTE terminal is
    /// ready as soon as it exists.
    func readyForReplay(for surfaceId: UUID) -> Bool {
        // Ghostty readiness used to be "mapped" — before eager background
        // spawn, map was the only moment the core surface (and its
        // terminal) came to exist, and write_display into a not-started
        // surface loses the text. With ensure_started, a readable surface
        // (core exists, io running) is the honest signal, mapped or not.
        if terminals[surfaceId] != nil { return true }
        if ghosttys[surfaceId] != nil {
            return ghosttyReadText(for: surfaceId, includeScrollback: false) != nil
        }
        return false
    }

    /// Readiness for typing INTO a pane (auto-resume), which is a
    /// different question from readiness to paint scrollback into it.
    /// A VTE widget exists the instant it is constructed, but
    /// `vte_terminal_spawn_async` is ASYNC: bytes written before the
    /// child exists are swallowed by the pty, so auto-resume commands
    /// vanished silently (2026-08-20 — the same "write into a
    /// not-started surface loses the text" trap the Ghostty branch
    /// above already guards). The spawn callback's pid is the honest
    /// signal that there is a shell on the other end.
    func readyForPTYWrite(for surfaceId: UUID) -> Bool {
        if terminals[surfaceId] != nil { return childPids[surfaceId] != nil }
        if ghosttys[surfaceId] != nil { return readyForReplay(for: surfaceId) }
        return false
    }

    @discardableResult
    func writeDisplay(for surfaceId: UUID, text: String) -> Bool {
        if terminals[surfaceId] != nil {
            return vteWriteDisplay(for: surfaceId, text: text)
        }
        return ghosttyWriteDisplay(for: surfaceId, text: text)
    }

    /// Shell working directory reported via OSC 7, live from the widget.
    /// Nil whenever the terminal cannot answer — including the case that
    /// matters most: a Ghostty surface whose GLArea is UNREALIZED has no
    /// core surface, so its `pwd` property is empty.
    private func liveDirectory(for surfaceId: UUID) -> String? {
        #if canImport(CGhosttyEmbed)
        if ghosttys[surfaceId] != nil {
            return currentGhosttyDirectory(for: surfaceId)
        }
        #endif
        guard let terminal = terminals[surfaceId],
              let uri = vte_terminal_get_current_directory_uri(terminal),
              let path = g_filename_from_uri(uri, nil, nil) else { return nil }
        defer { g_free(path) }
        return String(cString: path)
    }

    /// The surface's working directory: live if the terminal can answer,
    /// otherwise the last one it reported.
    ///
    /// The remembering half exists because "cannot answer right now" is
    /// a TRANSIENT state that used to be persisted as a permanent fact.
    /// On 2026-09-02 the daily wedged in GL realize/unrealize churn; the
    /// surfaces were unrealized when the session was saved, so every cwd
    /// went out empty, restore spawned every pane in $HOME, and ~10 agent
    /// sessions had to be hand-recovered because `claude --resume`
    /// derives its transcript folder from the cwd (PROGRESS 2026-09-01/02).
    /// A stale-but-real directory beats an empty one in every case.
    func currentDirectory(for surfaceId: UUID) -> String? {
        if let live = liveDirectory(for: surfaceId), !live.isEmpty {
            lastKnownDirectories[surfaceId] = live
            return live
        }
        return lastKnownDirectories[surfaceId]
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
    /// Surface asks to be closed (ghostty close-request: clean shell
    /// exit, Ctrl+D, …). VTE surfaces never call this (they linger).
    var onCloseRequest: (UUID, UUID) -> Void
    /// A pane's tab strip changed selection / a tab was closed. Mirrored
    /// into the model so the widget and the socket verbs never disagree
    /// about which surface a pane is showing.
    var onTabSelected: (UUID, UUID, UUID) -> Void = { _, _, _ in }
    var onTabClosed: (UUID, UUID, UUID) -> Void = { _, _, _ in }
    /// The user dragged a tab to a new position in its strip. Mirrored
    /// into the model (same path as `surface.reorder`) — before this the
    /// drag was accepted visually and silently reverted on the next sync.
    var onTabReordered: (UUID, UUID, UUID, Int) -> Void = { _, _, _, _ in }

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
        PaneDividers.stack = stack
        var shapes = storage.fields["tab-shapes"] as? [UUID: String] ?? [:]

        // Widgets for every leaf (new tabs and fresh splits alike).
        for tab in tabs {
            for (paneId, surface) in tab.allSurfaces
            where SurfaceRegistry.shared.containers[surface.surfaceId] == nil {
                _ = paneId
                let leaf = surface
                switch leaf.kind {
                case .terminal:
                    #if canImport(CGhosttyEmbed)
                    if GhosttyRuntime.available() {
                        GhosttySurfaceFactory.create(
                            for: leaf,
                            in: tab,
                            storage: storage,
                            onTitleChanged: onTitleChanged,
                            onBell: onBell,
                            onSurfaceFocused: onSurfaceFocused,
                            onCloseRequest: onCloseRequest
                        )
                    } else {
                        createTerminal(for: leaf, in: tab, storage: storage)
                    }
                    #else
                    createTerminal(for: leaf, in: tab, storage: storage)
                    #endif
                case .browser:
                    BrowserSurfaceFactory.create(
                        for: leaf,
                        in: tab,
                        storage: storage,
                        onTitleChanged: onTitleChanged,
                        onSurfaceFocused: onSurfaceFocused
                    )
                case .inspector:
                    InspectorSurfaceFactory.create(
                        for: leaf,
                        in: tab,
                        storage: storage,
                        onSurfaceFocused: onSurfaceFocused
                    )
                }
            }
        }

        // Drop registry entries for surfaces that no longer exist anywhere.
        // allSurfaces, not surfaces: a pane's background tabs are live too.
        let liveSurfaces = Set(tabs.flatMap { $0.allSurfaces.map(\.surface.surfaceId) })
        for surfaceId in SurfaceRegistry.shared.containers.keys where !liveSurfaces.contains(surfaceId) {
            SurfaceRegistry.shared.unregister(surfaceId)
            TerminalScrollbackStore.forget(surfaceId)
            BrowserProfileAssignments.forget(surfaceId)
            PaneTabs.customTitles.removeValue(forKey: surfaceId)
        }
        // Same for tab views whose pane is gone, or a closed pane keeps its
        // AdwTabView (and the containers inside it) alive forever.
        PaneTabs.prune(livePaneIds: Set(tabs.flatMap { $0.panes.map(\.paneId) }))

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
            // Zoom changes which widgets are in the tree, so it belongs in
            // the signature or toggling would not rebuild.
            let signature = tab.layout.shapeSignature
                + "|zoom:" + (tab.zoomedSurfaceId?.uuidString ?? "-")
                + "|respawn:\(tab.respawnNonce)"
            let existing = gtk_stack_get_child_by_name(stack, tab.id.uuidString)
            guard shapes[tab.id] != signature || existing == nil else { continue }

            // Keep live surface containers alive across the rebuild and
            // detach them from their old parents — GtkPaned refuses children
            // that are still parented elsewhere, and a silently rejected
            // child dies with the old skeleton (dangling registry pointers).
            for (_, surface) in tab.allSurfaces {
                if let container = SurfaceRegistry.shared.containers[surface.surfaceId] {
                    g_object_ref_sink(UnsafeMutableRawPointer(container))
                    detachFromParent(UnsafeMutablePointer<GtkWidget>(container))
                }
            }
            // A tabbed pane's wrapper is what actually sits in the split
            // tree — its surface containers live inside the persistent
            // AdwTabView and must NOT be pulled out (see PaneTabs). Detach
            // the wrapper instead, or destroying the old skeleton takes the
            // tab view and every page with it.
            for pane in tab.panes {
                if let wrapper = PaneTabs.wrapper(for: pane.paneId) {
                    detachFromParent(wrapper)
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
                // The window's focus reference can be the LAST ref keeping
                // this subtree alive: destroying it then defers the paned's
                // dispose to the next focus change, which runs mid-focus-
                // iteration and segfaults inside gtk_widget_focus_move
                // (observed: gtk_window_root_set_focus → g_object_unref →
                // gtk_paned_dispose → crash). Point focus elsewhere first.
                if let root = gtk_widget_get_root(existing) {
                    let window = UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWindow.self)
                    if let focus = gtk_window_get_focus(window),
                       gtk_widget_is_ancestor(focus, existing) != 0 || focus == existing {
                        gtk_window_set_focus(window, nil)
                    }
                }
                gtk_stack_remove(stack, existing)
            }
            // Zoomed: build only that pane. The other containers stay
            // unparented but alive (the registry holds strong refs), so
            // un-zooming puts them back rather than respawning them.
            let rootNode: UnsafeMutablePointer<GtkWidget>?
            if let zoomed = tab.zoomedSurfaceId,
               let pane = tab.panes.first(where: { $0.contains(surfaceId: zoomed) }) {
                rootNode = PaneTabs.build(
                    pane: pane, tabId: tab.id,
                    onSelected: onTabSelected, onClosed: onTabClosed,
                    onReordered: onTabReordered
                )
            } else {
                rootNode = buildNode(tab.layout, tabId: tab.id)
            }
            if let root = rootNode {
                gtk_stack_add_named(stack, root, tab.id.uuidString)
                restoreDividerPositions(root, path: "", from: dividers)
                balanceFreshDividers(root, path: "", restored: dividers, tabId: tab.id)
            }
            for (_, surface) in tab.allSurfaces {
                if let container = SurfaceRegistry.shared.containers[surface.surfaceId] {
                    g_object_unref(UnsafeMutableRawPointer(container))
                }
            }
            shapes[tab.id] = signature
        }
        storage.fields["tab-shapes"] = shapes
        // Titles arrive after the page does (a freshly adopted popup has
        // neither title nor URL yet), so refresh them on every sync.
        PaneTabs.refreshAllTitles(tabs: tabs)
        // Eager background spawn: realize hidden ghostty widgets so their
        // shells start without the workspace ever being selected.
        SurfaceRegistry.shared.realizeHiddenGhosttys()
        // Mapping used to be what started background shells; with eager
        // realize the replay poll can usually begin before first show.
        TerminalScrollbackStore.replayPendingIfReady()
        AgentResumeStore.startPendingIfReady()

        if let tab = tabs.first(where: { $0.id == selection }) {
            gtk_stack_set_visible_child_name(stack, tab.id.uuidString)
            if let focused = tab.focusedSurface {
                if let terminal = SurfaceRegistry.shared.terminal(for: focused.surfaceId) {
                    gtk_widget_grab_focus(asWidget(terminal))
                } else if SurfaceRegistry.shared.ghostty(for: focused.surfaceId) != nil {
                    #if canImport(CGhosttyEmbed)
                    // The Surface bin is focusable:false — focus its input
                    // widget (GLArea) through ghostty's own API.
                    SurfaceRegistry.shared.ghosttyGrabFocus(for: focused.surfaceId)
                    #endif
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

    /// Fresh splits (no preserved divider) start balanced 50/50. Without
    /// this, GtkPaned derives the initial position from the children's
    /// natural sizes — a WebKitWebView requests ~0, so browser panes
    /// collapsed to a sliver until dragged. The position can only be set
    /// once the paned has a real allocation, hence the one-shot tick
    /// callback (it fires on the first drawn frame after mapping).
    private func balanceFreshDividers(
        _ widget: UnsafeMutablePointer<GtkWidget>?,
        path: String,
        restored positions: [String: Int32],
        tabId: UUID
    ) {
        guard let widget, isA(widget, gtk_paned_get_type()) else { return }
        let paned = OpaquePointer(widget)
        if (positions[path] ?? 0) <= 0,
           let fraction = PaneDividers.fraction(tabId: tabId, path: path) {
            // Restored from the session: apply once the paned has a size.
            _ = gtk_widget_add_tick_callback(
                widget, dividerApplyFraction,
                Unmanaged.passRetained(DividerFractionBox(fraction: fraction)).toOpaque(),
                dividerFractionBoxDestroy
            )
        } else if (positions[path] ?? 0) <= 0 {
            _ = gtk_widget_add_tick_callback(widget, { widget, _, _ in
                guard let widget else { return gboolean(0) }
                let paned = OpaquePointer(widget)
                let horizontal = gtk_orientable_get_orientation(OpaquePointer(widget))
                    == GTK_ORIENTATION_HORIZONTAL
                let total = horizontal
                    ? gtk_widget_get_width(widget)
                    : gtk_widget_get_height(widget)
                if total <= 1 { return gboolean(1) } // not allocated yet
                gtk_paned_set_position(paned, total / 2)
                return gboolean(0)
            }, nil, nil)
        }
        balanceFreshDividers(gtk_paned_get_start_child(paned), path: path + "0", restored: positions, tabId: tabId)
        balanceFreshDividers(gtk_paned_get_end_child(paned), path: path + "1", restored: positions, tabId: tabId)
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

    private func buildNode(_ node: PaneNode, tabId: UUID) -> UnsafeMutablePointer<GtkWidget>? {
        switch node {
        case .leaf(let leaf):
            return PaneTabs.build(
                pane: leaf,
                tabId: tabId,
                onSelected: onTabSelected,
                onClosed: onTabClosed,
                onReordered: onTabReordered
            )
        case .split(let orientation, let first, let second):
            let paned = gtk_paned_new(
                orientation == .horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL
            )
            let handle = OpaquePointer(paned)
            gtk_paned_set_start_child(handle, buildNode(first, tabId: tabId))
            gtk_paned_set_end_child(handle, buildNode(second, tabId: tabId))
            gtk_paned_set_wide_handle(handle, 1)
            gtk_widget_set_hexpand(paned, 1)
            gtk_widget_set_vexpand(paned, 1)
            return paned
        }
    }

    private func createTerminal(for leaf: PaneSurface, in tab: TerminalTab, storage: ViewStorage) {
        guard let widget = vte_terminal_new() else { return }
        let terminal = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: VteTerminal.self)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        vte_terminal_set_scrollback_lines(terminal, 10_000)
        // Sane PTY geometry before the widget is ever mapped — terminals
        // spawned into unselected workspaces otherwise start with a ~0-size
        // viewport and their shells stall on a 0x0 pty.
        vte_terminal_set_size(terminal, 80, 24)

        guard let scrolled = gtk_scrolled_window_new() else { return }
        gtk_scrolled_window_set_child(OpaquePointer(scrolled), widget)
        gtk_widget_set_hexpand(scrolled, 1)
        gtk_widget_set_vexpand(scrolled, 1)

        spawnShell(in: terminal, leaf: leaf, tab: tab)
        SurfaceRegistry.shared.registerTerminal(terminal, container: OpaquePointer(scrolled), for: leaf.surfaceId)
        // Replay restored scrollback. Unlike Ghostty (terminal exists only
        // after first map), a VTE terminal is usable immediately.
        TerminalScrollbackStore.startReplay(surfaceId: leaf.surfaceId)
        AgentResumeStore.start(surfaceId: leaf.surfaceId)
        connectSignals(for: leaf, in: tab, terminal: terminal, widget: widget, storage: storage)
    }

    private func connectSignals(
        for leaf: PaneSurface,
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
        leaf: PaneSurface,
        tab: TerminalTab
    ) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        let cmuxEnv = [
            "CMUX_WORKSPACE_ID": tab.id.uuidString,
            "CMUX_SURFACE_ID": leaf.surfaceId.uuidString,
            "CMUX_SOCKET_PATH": ControlSocketServer.shared.path,
        ]
        var environment = ProcessInfo.processInfo.environment
        environment.merge(cmuxEnv) { _, new in new }

        // In-flatpak the sandbox $SHELL is the runtime's sh — resolve
        // the user's real shell host-side instead.
        let shellArgv = FlatpakEnv.hostShellEnabled
            ? FlatpakEnv.hostLoginShellArgv : [shell]
        let argv = cmuxCStringArray(FlatpakEnv.spawnArgv(
            shellArgv, cwd: leaf.workingDirectory, extraEnv: cmuxEnv))
        let envv = cmuxCStringArray(environment.map { "\($0.key)=\($0.value)" })
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
            nil,
            vteSpawnPidCallback,
            Unmanaged.passRetained(SpawnPidBox(leaf.surfaceId)).toOpaque()
        )
    }

    private func asWidget(_ terminal: UnsafeMutablePointer<VteTerminal>) -> UnsafeMutablePointer<GtkWidget> {
        UnsafeMutableRawPointer(terminal).assumingMemoryBound(to: GtkWidget.self)
    }

}

/// NULL-terminated, strdup'd C string array (freed with `g_strfreev`;
/// VTE's spawn copies the arrays before returning). File-scope: both the
/// view's first spawn and the registry's respawn build argv/envv with it.
func cmuxCStringArray(_ strings: [String]) -> UnsafeMutablePointer<UnsafeMutablePointer<CChar>?> {
    let array = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: strings.count + 1)
    for (index, string) in strings.enumerated() {
        array[index] = strdup(string)
    }
    array[strings.count] = nil
    return array
}

/// Carries the surface identity into VTE's C spawn callback.
final class SpawnPidBox {
    let surfaceId: UUID
    init(_ surfaceId: UUID) { self.surfaceId = surfaceId }
}

/// Records the child pid VTE reports, so respawn can kill the previous
/// process instead of orphaning it.
let vteSpawnPidCallback: VteTerminalSpawnAsyncCallback = { _, pid, _, userData in
    guard let userData else { return }
    let box = Unmanaged<SpawnPidBox>.fromOpaque(userData).takeRetainedValue()
    SurfaceRegistry.shared.setChildPid(pid, for: box.surfaceId)
}
