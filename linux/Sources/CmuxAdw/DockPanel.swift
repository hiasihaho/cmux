import Adwaita
import CVte
import Foundation

/// The minimal Dock (comfort mirror ⑦, MACOS-UX §5): a toggleable
/// trailing panel of persistent terminals that stay put while workspaces
/// switch — the "instruments panel" (log tails, lazygit, watchers).
///
/// Scope mirrors macOS's SHIPPED behavior where it is small and the
/// recorded minimal-viable plan elsewhere: reads the GLOBAL
/// `$XDG_CONFIG_HOME/cmux/dock.json` only (macOS's window Dock reads
/// global-only too, so no trust gate is needed — project configs are the
/// gated ones and are not supported yet), terminal controls only
/// (browser entries are skipped, as macOS does with browsers disabled),
/// a vertical resizable stack, no persistence (macOS deliberately
/// reseeds from config each launch). Deferred: in-dock tiling, drag
/// in/out, `--placement dock` verbs (GAPS).
///
/// Control semantics (the macOS detail worth keeping exactly): the
/// command runs in a NON-INTERACTIVE login shell; when it exits the pane
/// falls back to an INTERACTIVE login shell in place, so a crashed
/// watcher becomes a shell right where it died.
enum DockConfig {

    struct Control {
        let id: String
        let title: String
        let command: String
        let cwd: String?
        let env: [String: String]
    }

    private struct FileControl: Codable {
        var id: String?
        var title: String?
        var type: String?
        var command: String?
        var url: String?
        var cwd: String?
        var height: Int?
        var env: [String: String]?
    }

    private struct FileShape: Codable {
        var controls: [FileControl]?
    }

    static func path() -> String {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path + "/.config"
        return base + "/cmux/dock.json"
    }

    /// Parses the global dock.json — the macOS schema (docs/dock.md):
    /// unique non-blank ids, `type` defaults to terminal, terminal
    /// controls require `command`. Browser controls are counted and
    /// skipped. A malformed file yields no controls (the empty state
    /// says so).
    static func load() -> (controls: [Control], skippedBrowsers: Int) {
        guard let data = FileManager.default.contents(atPath: path()),
              let file = try? JSONDecoder().decode(FileShape.self, from: data) else {
            return ([], 0)
        }
        var seen = Set<String>()
        var controls: [Control] = []
        var skipped = 0
        for entry in file.controls ?? [] {
            guard let id = entry.id?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !id.isEmpty, !seen.contains(id) else { continue }
            let type = entry.type ?? "terminal"
            if type == "browser" {
                skipped += 1
                continue
            }
            guard type == "terminal",
                  let command = entry.command, !command.isEmpty else { continue }
            seen.insert(id)
            controls.append(Control(
                id: id,
                title: entry.title ?? id,
                command: command,
                cwd: entry.cwd,
                env: entry.env ?? [:]
            ))
        }
        return (controls, skipped)
    }
}

/// Live dock state, for `debug.dock` and the toggle path.
enum DockRuntime {
    /// Controls materialized into terminals (set at populate time).
    static var loadedControls: [DockConfig.Control] = []
    static var populated = false
    static var skippedBrowsers = 0
    /// Wired by CmuxApp: read + write the dock's visibility state.
    static var visibleProvider: () -> Bool = { false }
    static var setVisible: (Bool) -> Void = { _ in }
}

/// The dock panel: built once, populated lazily on first visibility
/// (macOS materializes its Dock on first show too).
struct DockPanelWidget: AdwaitaWidget {

    var visible: Bool

    func container<Data>(data: WidgetData, type: Data.Type) -> ViewStorage where Data: ViewRenderData {
        let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0)
        gtk_widget_set_vexpand(box, 1)
        gtk_widget_set_size_request(box, 320, -1)
        let storage = ViewStorage(OpaquePointer(box))
        populateIfNeeded(storage)
        return storage
    }

    func update<Data>(
        _ storage: ViewStorage, data: WidgetData, updateProperties: Bool, type: Data.Type
    ) where Data: ViewRenderData {
        populateIfNeeded(storage)
    }

    private func populateIfNeeded(_ storage: ViewStorage) {
        guard visible, !DockRuntime.populated,
              let box = storage.opaquePointer else { return }
        DockRuntime.populated = true
        let (controls, skipped) = DockConfig.load()
        DockRuntime.loadedControls = controls
        DockRuntime.skippedBrowsers = skipped
        let container = UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self)
        guard !controls.isEmpty else {
            appendEmptyState(to: container)
            return
        }
        // A resizable vertical stack: fold the control panes into a chain
        // of vertical paneds (equal initial shares; `height` seeding is
        // deferred).
        var widgets = controls.compactMap(controlWidget)
        guard let first = widgets.first else { return }
        var chain = first
        for next in widgets.dropFirst() {
            guard let paned = gtk_paned_new(GTK_ORIENTATION_VERTICAL) else { continue }
            gtk_widget_set_vexpand(paned, 1)
            gtk_paned_set_start_child(OpaquePointer(paned), chain)
            gtk_paned_set_end_child(OpaquePointer(paned), next)
            chain = paned
        }
        gtk_box_append(container, chain)
    }

    private func appendEmptyState(to container: UnsafeMutablePointer<GtkBox>) {
        guard let label = gtk_label_new(
            "No dock controls.\nDefine terminals in\n\(DockConfig.path())"
        ) else { return }
        gtk_label_set_justify(OpaquePointer(label), GTK_JUSTIFY_CENTER)
        gtk_widget_add_css_class(label, "dim-label")
        gtk_widget_set_vexpand(label, 1)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_box_append(container, label)
    }

    /// One control: a caption + a VTE terminal running the login-shell
    /// wrapper. Dock terminals are deliberately NOT in the surface
    /// registry — they are window furniture, not workspace surfaces
    /// (socket addressing is a deferred stage).
    private func controlWidget(_ control: DockConfig.Control) -> UnsafeMutablePointer<GtkWidget>? {
        guard let box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0),
              let label = gtk_label_new(control.title),
              let terminalWidget = vte_terminal_new() else { return nil }
        gtk_widget_add_css_class(label, "dim-label")
        gtk_widget_add_css_class(label, "caption-heading")
        gtk_widget_set_halign(label, GTK_ALIGN_START)
        gtk_widget_set_margin_start(label, 8)
        gtk_widget_set_margin_top(label, 4)
        let container = UnsafeMutableRawPointer(box).assumingMemoryBound(to: GtkBox.self)
        gtk_box_append(container, label)
        gtk_widget_set_vexpand(terminalWidget, 1)
        gtk_widget_set_hexpand(terminalWidget, 1)
        gtk_box_append(container, terminalWidget)
        gtk_widget_set_vexpand(box, 1)

        let terminal = UnsafeMutableRawPointer(terminalWidget)
            .assumingMemoryBound(to: VteTerminal.self)
        var environment = ProcessInfo.processInfo.environment
        for (key, value) in control.env { environment[key] = value }
        environment["CMUX_DOCK_CONTROL_ID"] = control.id
        environment["CMUX_DOCK_CONTROL_TITLE"] = control.title
        let shell = environment["SHELL"] ?? "/bin/bash"
        // Non-interactive login shell runs the command; on exit an
        // interactive login shell takes over IN PLACE.
        let script = "\(control.command)\nexec \"\(shell)\" -l"
        let argv = cmuxCStringArray([shell, "-l", "-c", script])
        let envv = cmuxCStringArray(environment.map { "\($0.key)=\($0.value)" })
        defer {
            g_strfreev(argv)
            g_strfreev(envv)
        }
        let cwd = control.cwd.map { raw -> String in
            raw.hasPrefix("~")
                ? FileManager.default.homeDirectoryForCurrentUser.path + raw.dropFirst()
                : raw
        } ?? FileManager.default.homeDirectoryForCurrentUser.path
        vte_terminal_spawn_async(
            terminal, VTE_PTY_DEFAULT, cwd, argv, envv,
            G_SPAWN_DEFAULT, nil, nil, nil, -1, nil, nil, nil
        )
        return box
    }
}
