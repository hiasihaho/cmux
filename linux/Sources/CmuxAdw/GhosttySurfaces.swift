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
    private static let wanted =
        ProcessInfo.processInfo.environment["CMUX_TERM"]?.lowercased() == "ghostty"
    private static var initResult: Bool?

    /// True when Ghostty surfaces are both requested and initializable.
    static func available() -> Bool {
        guard wanted else { return false }
        if let initResult { return initResult }
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
        for leaf: PaneLeaf,
        in tab: TerminalTab,
        storage: ViewStorage,
        onTitleChanged: @escaping (UUID, UUID, String) -> Void,
        onBell: @escaping (UUID, UUID) -> Void,
        onSurfaceFocused: @escaping (UUID, UUID) -> Void
    ) {
        // Same identity environment as the VTE spawn path — bare `cmux`
        // commands in the shell must target this pane.
        let env = [
            ("CMUX_WORKSPACE_ID", tab.id.uuidString),
            ("CMUX_SURFACE_ID", leaf.surfaceId.uuidString),
            ("CMUX_SOCKET_PATH", ControlSocketServer.shared.path),
        ]
        let keyDup = env.map { strdup($0.0) }
        let valueDup = env.map { strdup($0.1) }
        defer {
            keyDup.forEach { free($0) }
            valueDup.forEach { free($0) }
        }
        var keys: [UnsafePointer<CChar>?] = keyDup.map { UnsafePointer($0) }
        var values: [UnsafePointer<CChar>?] = valueDup.map { UnsafePointer($0) }

        let raw: UnsafeMutableRawPointer? = keys.withUnsafeMutableBufferPointer { k in
            values.withUnsafeMutableBufferPointer { v in
                ghostty_embed_surface_new(
                    leaf.workingDirectory,
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

        // Ghostty's own hierarchy hosts the (GtkScrollable) surface in a
        // scrolled window; mirror that so scrollback gets a scrollbar.
        guard let scrolled = gtk_scrolled_window_new() else { return }
        gtk_scrolled_window_set_child(OpaquePointer(scrolled), widget)
        gtk_widget_set_hexpand(scrolled, 1)
        gtk_widget_set_vexpand(scrolled, 1)

        SurfaceRegistry.shared.registerGhostty(
            OpaquePointer(widget),
            container: OpaquePointer(scrolled),
            for: leaf.surfaceId
        )

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
    func currentGhosttyDirectory(for surfaceId: UUID) -> String? {
        guard let pointer = ghostty(for: surfaceId) else { return nil }
        let widget = UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: GtkWidget.self)
        let pwd = GhosttySurfaceFactory.stringProperty(widget, "pwd")
        return (pwd?.isEmpty ?? true) ? nil : pwd
    }
}
#endif
