#if canImport(CGhosttyEmbed)
import Adwaita
import CGhosttyEmbed
import Foundation

// Experimental Ghostty terminal surfaces (GHOSTTY-SHIM.md increment 2).
// Compiled only when the package was built with CMUX_GHOSTTY=1 (which
// links the embedding shim from the ghostty submodule); activated at
// runtime with CMUX_TERM=ghostty. All GTK calls in this file go through
// CGhosttyEmbed's view of GTK (cross-module GTK types don't unify).

/// One-shot shim initialization, decided by env + first use.
enum GhosttyRuntime {
    /// Shim-linked builds default to Ghostty terminals; VTE is the
    /// explicit fallback via CMUX_TERM=vte or the settings file
    /// (linux.terminalBackend). One-shot: read at first terminal creation,
    /// so a settings change applies at the next launch.
    private static let wanted: Bool = LinuxSettings.terminalBackend == .ghostty
    private static var initResult: Bool?

    /// Self-locate the shell-integration/theme resources for launches
    /// that bypass start.sh (desktop launcher, bare binary): walk up
    /// from the executable towards the repo root looking for the shim's
    /// zig-out share dir. No-op when the env var is already set.
    private static func ensureResourcesDir() {
        guard ProcessInfo.processInfo.environment["GHOSTTY_RESOURCES_DIR"] == nil else { return }
        var dir = URL(fileURLWithPath: "/proc/self/exe")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("ghostty/zig-out/share/ghostty")
            if FileManager.default.fileExists(atPath: candidate.path) {
                setenv("GHOSTTY_RESOURCES_DIR", candidate.path, 1)
                return
            }
            dir.deleteLastPathComponent()
        }
    }

    /// True when Ghostty surfaces are both requested and initializable.
    static func available() -> Bool {
        guard wanted else { return false }
        if let initResult { return initResult }
        ensureResourcesDir()
        let ok = ghostty_embed_init() == 0
        if !ok {
            FileHandle.standardError.write(Data(
                "cmux: ghostty_embed_init failed; falling back to VTE\n".utf8
            ))
        }
        initResult = ok
        return ok
    }
}

/// Creates embedded Ghostty surfaces for `.terminal` pane leaves — the
/// drop-in alternative to the VTE factory in TerminalSurfaces.swift.
enum GhosttySurfaceFactory {

    static func create(
        for leaf: PaneSurface,
        in tab: TerminalTab,
        storage: ViewStorage,
        onTitleChanged: @escaping (UUID, UUID, String) -> Void,
        onBell: @escaping (UUID, UUID) -> Void,
        onSurfaceFocused: @escaping (UUID, UUID) -> Void,
        onCloseRequest: @escaping (UUID, UUID) -> Void
    ) {
        // Same identity environment as the VTE spawn path — bare `cmux`
        // commands in the shell must target this pane.
        var env = [
            ("CMUX_WORKSPACE_ID", tab.id.uuidString),
            ("CMUX_SURFACE_ID", leaf.surfaceId.uuidString),
            ("CMUX_SOCKET_PATH", ControlSocketServer.shared.path),
        ]
        // Repair a stale inherited HOSTNAME.
        //
        // Ghostty's shell integration reports the working directory with
        // `OSC 7 file://$HOSTNAME$PWD`, and Ghostty validates that host
        // against gethostname() before trusting it — deliberately, since
        // any remote shell can send OSC 7 (see stream_handler.zig: "OSC 7
        // is a little sketchy… validate the hostname to be local").
        //
        // Bash sets HOSTNAME itself, but only when it is not already in the
        // environment: an inherited value wins. A desktop session started
        // before the machine was renamed therefore poisons every shell
        // beneath it, OSC 7 is rejected for the whole session, and the pane
        // never reports a working directory — so session restore reopens
        // shells in their spawn directory instead of where they were.
        //
        // Passing the real hostname fixes the cause without touching
        // Ghostty's security check.
        if let real = ProcessInfo.processInfo.hostName as String?, !real.isEmpty {
            env.append(("HOSTNAME", real))
        }
        let keyDup = env.map { strdup($0.0) }
        let valueDup = env.map { strdup($0.1) }
        defer {
            keyDup.forEach { free($0) }
            valueDup.forEach { free($0) }
        }
        var keys: [UnsafePointer<CChar>?] = keyDup.map { UnsafePointer($0) }
        var values: [UnsafePointer<CChar>?] = valueDup.map { UnsafePointer($0) }

        // A pending respawn (surface.respawn tore the old widget down)
        // overrides cwd and runs its command instead of the user's shell.
        let respawn = SurfaceRegistry.shared.takePendingRespawn(for: leaf.surfaceId)
        let workingDirectory = respawn?.workingDirectory ?? leaf.workingDirectory
        // NB: host shells in a flatpak are GHOSTTY's job, not ours. The
        // shim is built with -Dflatpak=true, which enables Ghostty's
        // FlatpakHostCommand path (src/termio/Exec.zig) — it spawns on
        // the host through the portal itself. Wrapping the command in
        // our own `flatpak-spawn --host` (as the VTE path must) puts
        // flatpak-spawn on the HOST, where it has no portal to talk to:
        // "Can't find bus", the shell exits instantly, and the pane
        // reports `unavailable: Surface shell has exited` (2026-08-20).
        let spawnCommand = respawn?.command
        let raw: UnsafeMutableRawPointer? = keys.withUnsafeMutableBufferPointer { k in
            values.withUnsafeMutableBufferPointer { v in
                if let command = spawnCommand {
                    return command.withCString { cmd in
                        ghostty_embed_surface_new_with_command(
                            workingDirectory,
                            k.baseAddress,
                            v.baseAddress,
                            env.count,
                            cmd
                        )
                    }
                }
                return ghostty_embed_surface_new(
                    workingDirectory,
                    k.baseAddress,
                    v.baseAddress,
                    env.count
                )
            }
        }
        guard let raw else { return }
        let widget = raw.assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)

        // Ghostty's own container class (SurfaceScrolledWindow): config-
        // bound scrollbar, hscroll disabled. A plain GtkScrolledWindow with
        // automatic policies let the surface keep its natural size instead
        // of tracking the host window — panes never resized with it.
        guard let containerRaw = ghostty_embed_surface_container_new(widget) else { return }
        let container = containerRaw.assumingMemoryBound(to: GtkWidget.self)
        gtk_widget_set_hexpand(container, 1)
        gtk_widget_set_vexpand(container, 1)

        SurfaceRegistry.shared.registerGhostty(
            OpaquePointer(widget),
            container: OpaquePointer(container),
            for: leaf.surfaceId
        )

        // Replay saved screen text once the shell is actually up — the
        // surface has no terminal until it is first mapped.
        TerminalScrollbackStore.startReplay(surfaceId: leaf.surfaceId)
        AgentResumeStore.start(surfaceId: leaf.surfaceId)

        let tabId = tab.id
        let surfaceId = leaf.surfaceId

        // OSC titles arrive as GObject property notifications.
        storage.connectSignal(
            name: "notify::title",
            id: "ghostty-title-\(surfaceId.uuidString)",
            argCount: 1,
            pointer: OpaquePointer(widget)
        ) {
            if let title = Self.stringProperty(widget, "title"), !title.isEmpty {
                onTitleChanged(tabId, surfaceId, title)
            }
        }

        // Bell state is a boolean property; report the rising edge.
        storage.connectSignal(
            name: "notify::bell-ringing",
            id: "ghostty-bell-\(surfaceId.uuidString)",
            argCount: 1,
            pointer: OpaquePointer(widget)
        ) {
            if Self.boolProperty(widget, "bell-ringing") {
                onBell(tabId, surfaceId)
            }
        }

        if let controller = gtk_event_controller_focus_new() {
            gtk_widget_add_controller(widget, controller)
            storage.connectSignal(
                name: "enter",
                id: "ghostty-focus-\(surfaceId.uuidString)",
                pointer: controller
            ) {
                onSurfaceFocused(tabId, surfaceId)
            }
        }

        // Ghostty asks the container to close the surface (clean child
        // exit with wait-after-command off, Ctrl+D, confirmed closes);
        // abnormal exits show the overlay instead and never emit this.
        storage.connectSignal(
            name: "close-request",
            id: "ghostty-close-\(surfaceId.uuidString)",
            pointer: OpaquePointer(widget)
        ) {
            onCloseRequest(tabId, surfaceId)
        }
    }

    // MARK: GObject property helpers

    static func stringProperty(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ name: String
    ) -> String? {
        var value = GValue()
        g_value_init(&value, g_type_from_name("gchararray"))
        defer { g_value_unset(&value) }
        g_object_get_property(asGObject(widget), name, &value)
        guard let text = g_value_get_string(&value) else { return nil }
        return String(cString: text)
    }

    static func boolProperty(
        _ widget: UnsafeMutablePointer<GtkWidget>,
        _ name: String
    ) -> Bool {
        var value = GValue()
        g_value_init(&value, g_type_from_name("gboolean"))
        defer { g_value_unset(&value) }
        g_object_get_property(asGObject(widget), name, &value)
        return g_value_get_boolean(&value) != 0
    }

    private static func asGObject(
        _ widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GObject> {
        UnsafeMutableRawPointer(widget).assumingMemoryBound(to: GObject.self)
    }
}

extension SurfaceRegistry {
    /// Raw PTY write (send_text/send_key semantics). False while the
    /// surface's shell isn't running yet (unrealized background pane).
    func ghosttySendText(_ text: String, to surfaceId: UUID) -> Bool {
        guard let pointer = ghostty(for: surfaceId) else { return false }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        let bytes = Array(text.utf8)
        return bytes.withUnsafeBufferPointer { buffer in
            ghostty_embed_surface_send_text(widget, buffer.baseAddress, bytes.count)
        }
    }

    /// Focus the surface's input widget (the inner GLArea — the Surface
    /// bin itself is not focusable).
    func ghosttyGrabFocus(for surfaceId: UUID) {
        guard let pointer = ghostty(for: surfaceId) else { return }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        ghostty_embed_surface_grab_focus(widget)
    }

    /// Show/hide the surface's built-in find-in-terminal overlay.
    func ghosttySetSearch(for surfaceId: UUID, active: Bool) {
        guard let pointer = ghostty(for: surfaceId) else { return }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        ghostty_embed_surface_set_search(widget, active)
    }

    /// True once the pane's shell has exited (the surface shows the
    /// child-exited overlay; text writes would go nowhere).
    func ghosttyChildExited(for surfaceId: UUID) -> Bool {
        guard let pointer = ghostty(for: surfaceId) else { return false }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        return GhosttySurfaceFactory.boolProperty(widget, "child-exited")
    }

    /// True once GTK has mapped the surface — the point at which it has a
    /// running terminal of a real size. A pane in a workspace nobody has
    /// selected is realized but never mapped, and writing to it silently
    /// succeeds into a terminal that has not started.
    func ghosttyIsMapped(for surfaceId: UUID) -> Bool {
        guard let pointer = ghostty(for: surfaceId) else { return false }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        return gtk_widget_get_mapped(widget) != 0
    }

    /// Terminal text: active screenful, or the whole buffer with
    /// `includeScrollback`. Nil while the shell isn't running yet.
    func ghosttyReadText(for surfaceId: UUID, includeScrollback: Bool) -> String? {
        guard let pointer = ghostty(for: surfaceId) else { return nil }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        guard let raw = ghostty_embed_surface_read_text(widget, includeScrollback) else {
            return nil
        }
        defer { ghostty_embed_text_free(raw) }
        return String(cString: raw)
    }

    /// Live OSC title of a Ghostty surface (property-backed).
    func currentGhosttyTitle(for surfaceId: UUID) -> String? {
        guard let pointer = ghostty(for: surfaceId) else { return nil }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        let title = GhosttySurfaceFactory.stringProperty(widget, "title")
        return (title?.isEmpty ?? true) ? nil : title
    }

    /// Shell working directory reported via OSC 7 (property-backed).
    /// Replays text into a Ghostty pane as terminal *output* — parsed and
    /// drawn, never handed to the shell. `send_text` would type it in
    /// instead, which for restored scrollback means executing whatever the
    /// user's history happened to contain.
    @discardableResult
    func ghosttyWriteDisplay(for surfaceId: UUID, text: String) -> Bool {
        guard let pointer = ghostty(for: surfaceId), !text.isEmpty else { return false }
        let widget = UnsafeMutableRawPointer(pointer)
        var bytes = Array(text.utf8)
        return bytes.withUnsafeMutableBufferPointer { buffer in
            ghostty_embed_surface_write_display(widget, buffer.baseAddress, buffer.count)
        }
    }

    func currentGhosttyDirectory(for surfaceId: UUID) -> String? {
        guard let pointer = ghostty(for: surfaceId) else { return nil }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        let pwd = GhosttySurfaceFactory.stringProperty(widget, "pwd")
        return (pwd?.isEmpty ?? true) ? nil : pwd
    }

    /// Eagerly start the shell of a realized-but-never-allocated surface
    /// (background workspace pane). The realize half happens in the sync
    /// (`realizeHiddenGhosttys`); this is the sizing half, in the shim.
    @discardableResult
    /// Child pid of a Ghostty surface, or nil when the shim cannot say
    /// (no core surface, not spawned, exited, or the Flatpak host-command
    /// path where the child is in another namespace). The shim answers -1
    /// for all of those; nil keeps "unknown" distinct from "none" for
    /// callers that attribute processes to panes.
    func ghosttyChildPid(for surfaceId: UUID) -> pid_t? {
        guard let widget = ghosttys[surfaceId], let fn = Self.ghosttyPidSymbol else { return nil }
        let raw = fn(UnsafeMutableRawPointer(widget))
        return raw > 0 ? pid_t(raw) : nil
    }

    /// Resolved via dlsym rather than linked directly, ON PURPOSE: the
    /// accessor is newer than the shim most checkouts have installed at
    /// `ghostty/zig-out`, and a hard link-time reference would make a plain
    /// `swift build` fail against an older libghostty-gtk.so — turning a
    /// capability upgrade into a build break, and forcing a shim rebuild at
    /// a moment the operator did not choose (the running daily has that
    /// library MAPPED; overwriting it can SIGBUS a live instance). With
    /// dlsym an old shim simply yields nil = "pid unknown", and the
    /// capability lights up by itself once the shim is rebuilt.
    private static let ghosttyPidSymbol: (@convention(c) (UnsafeMutableRawPointer?) -> Int64)? = {
        guard let handle = dlopen(nil, RTLD_LAZY),
              let symbol = dlsym(handle, "ghostty_embed_surface_pid") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (UnsafeMutableRawPointer?) -> Int64).self)
    }()

    func ghosttyEnsureStarted(for surfaceId: UUID) -> Bool {
        guard let pointer = ghostty(for: surfaceId) else { return false }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        return ghostty_embed_surface_ensure_started(widget) == 1
    }

    /// Live config reload: ghostty re-reads its config and propagates to
    /// every existing surface (the app.reload-config action). The
    /// registered-surface guard doubles as the initialized guard — no
    /// ghostty surface exists unless the shim is up.
    func ghosttyReloadConfig() -> Bool {
        guard !ghosttys.isEmpty else { return false }
        return ghostty_embed_reload_config() == 1
    }
}
#endif

#if !canImport(CGhosttyEmbed)
import Foundation

// VTE-only build: the Ghostty helpers callers use unconditionally
// (scrollback capture/replay, cwd) become honest "not available" answers,
// so the features degrade instead of the build breaking.
extension SurfaceRegistry {
    func ghosttyIsMapped(for surfaceId: UUID) -> Bool { false }
    func ghosttyReadText(for surfaceId: UUID, includeScrollback: Bool) -> String? { nil }
    func ghosttyChildPid(for surfaceId: UUID) -> pid_t? { nil }
    @discardableResult
    func ghosttyWriteDisplay(for surfaceId: UUID, text: String) -> Bool { false }
    func ghosttyChildExited(for surfaceId: UUID) -> Bool { false }
    func currentGhosttyTitle(for surfaceId: UUID) -> String? { nil }
    func currentGhosttyDirectory(for surfaceId: UUID) -> String? { nil }
    @discardableResult
    func ghosttyEnsureStarted(for surfaceId: UUID) -> Bool { false }
    func ghosttyReloadConfig() -> Bool { false }
}
#endif
