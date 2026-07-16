import Adwaita
import CVte
import Foundation

/// Main-thread map of tab surface → live VTE terminal, used by the control
/// protocol (`surface.send_text`, `surface.read_text`).
final class SurfaceRegistry {

    static let shared = SurfaceRegistry()

    private(set) var terminals: [UUID: UnsafeMutablePointer<VteTerminal>] = [:]

    func register(_ terminal: UnsafeMutablePointer<VteTerminal>, for surfaceId: UUID) {
        terminals[surfaceId] = terminal
    }

    func unregister(_ surfaceId: UUID) {
        terminals.removeValue(forKey: surfaceId)
    }

    func terminal(for surfaceId: UUID) -> UnsafeMutablePointer<VteTerminal>? {
        terminals[surfaceId]
    }
}

/// A GtkStack hosting one VTE terminal per tab. Children are managed
/// imperatively and kept alive across tab switches — declarative diffing
/// would destroy and respawn shells on every switch.
///
/// This is the Linux stand-in for the macOS `TerminalSurface`; the same
/// widget slot later hosts libghostty surfaces behind the same registry.
struct TerminalStackWidget: AdwaitaWidget {

    var tabs: [TerminalTab]
    var selection: UUID
    var onTitleChanged: (UUID, String) -> Void
    var onBell: (UUID) -> Void

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

    // MARK: child management

    private func sync(_ storage: ViewStorage) {
        guard let stack = storage.opaquePointer else { return }
        var known = storage.fields["known-surfaces"] as? Set<UUID> ?? []

        for tab in tabs where !known.contains(tab.surfaceId) {
            addTerminal(for: tab, to: stack)
            known.insert(tab.surfaceId)
        }

        let live = Set(tabs.map(\.surfaceId))
        for surfaceId in known.subtracting(live) {
            if let child = gtk_stack_get_child_by_name(stack, surfaceId.uuidString) {
                gtk_stack_remove(stack, child)
            }
            SurfaceRegistry.shared.unregister(surfaceId)
            known.remove(surfaceId)
        }
        storage.fields["known-surfaces"] = known

        // Refresh signal handlers so their closures capture current bindings.
        for tab in tabs {
            connectSignals(for: tab, storage: storage)
        }

        if let tab = tabs.first(where: { $0.id == selection }) {
            gtk_stack_set_visible_child_name(stack, tab.surfaceId.uuidString)
            if let terminal = SurfaceRegistry.shared.terminal(for: tab.surfaceId) {
                gtk_widget_grab_focus(asWidget(terminal))
            }
        }
    }

    private func addTerminal(for tab: TerminalTab, to stack: OpaquePointer) {
        guard let widget = vte_terminal_new() else { return }
        let terminal = UnsafeMutableRawPointer(widget).assumingMemoryBound(to: VteTerminal.self)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        vte_terminal_set_scrollback_lines(terminal, 10_000)

        guard let scrolled = gtk_scrolled_window_new() else { return }
        gtk_scrolled_window_set_child(OpaquePointer(scrolled), widget)
        gtk_stack_add_named(stack, scrolled, tab.surfaceId.uuidString)

        spawnShell(in: terminal, tab: tab)
        SurfaceRegistry.shared.register(terminal, for: tab.surfaceId)
    }

    private func connectSignals(for tab: TerminalTab, storage: ViewStorage) {
        guard let terminal = SurfaceRegistry.shared.terminal(for: tab.surfaceId) else { return }
        let pointer = OpaquePointer(terminal)
        let tabId = tab.id
        let onTitleChanged = onTitleChanged
        let onBell = onBell

        storage.connectSignal(
            name: "window-title-changed",
            id: "title-\(tab.surfaceId.uuidString)",
            pointer: pointer
        ) {
            if let title = vte_terminal_get_window_title(terminal) {
                onTitleChanged(tabId, String(cString: title))
            }
        }
        storage.connectSignal(
            name: "bell",
            id: "bell-\(tab.surfaceId.uuidString)",
            pointer: pointer
        ) {
            onBell(tabId)
        }
    }

    /// Spawns the user's shell with the cmux environment (workspace/surface
    /// identity + socket path), mirroring the macOS terminal environment.
    private func spawnShell(in terminal: UnsafeMutablePointer<VteTerminal>, tab: TerminalTab) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/bash"
        var environment = ProcessInfo.processInfo.environment
        environment["CMUX_WORKSPACE_ID"] = tab.id.uuidString
        environment["CMUX_SURFACE_ID"] = tab.surfaceId.uuidString
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
            tab.workingDirectory,
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
