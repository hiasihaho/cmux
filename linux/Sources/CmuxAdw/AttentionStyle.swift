import CVte
import Foundation

/// The one-accent attention language (UX-PARITY decision 2026-07-23),
/// mirroring macOS's tier model with GNOME's accent color:
///
///   tier 1 — transient flash ring (`surface.trigger_flash`, jump-to-unread)
///   tier 2 — persistent ring on a pane holding an unread notification
///   tier 3 — the sidebar dot and header-bar unread count (Views/CmuxApp)
///
/// macOS draws these with NSBezierPath strokes in one systemBlue; GTK gets
/// the same escalation as CSS outlines (outlines never shift layout),
/// installed once as an application-level provider. `@accent_bg_color` is
/// libadwaita's system accent, so the rings follow the user's GNOME accent
/// choice — the recorded deviation from macOS's fixed blue.
enum AttentionStyle {

    private static var installed = false

    /// Idempotent; called from the scene body once a display exists.
    static func install() {
        guard !installed, let display = gdk_display_get_default() else { return }
        installed = true
        let css = """
        .cmux-flash { outline: 3px solid @accent_bg_color; outline-offset: -3px; }
        .cmux-unread { outline: 2px solid alpha(@accent_bg_color, 0.85); outline-offset: -2px; }
        .cmux-unfocused { opacity: 0.78; }
        .cmux-hover-reveal { opacity: 0; transition: opacity 120ms ease; }
        row:hover .cmux-hover-reveal { opacity: 1; }
        """
        guard let provider = gtk_css_provider_new() else { return }
        gtk_css_provider_load_from_string(provider, css)
        gtk_style_context_add_provider_for_display(
            display,
            // GtkStyleProvider is an interface — no struct crosses the C
            // importer, so the provider pointer is passed opaquely.
            OpaquePointer(provider),
            // GTK_STYLE_PROVIDER_PRIORITY_APPLICATION — the macro does not
            // cross the C importer.
            600
        )
    }

    /// Tier 1: two ring blinks over ~0.9s — macOS's `FocusFlashPattern`
    /// cadence. Every tick re-resolves the container from the registry so
    /// a pane closed mid-flash is a no-op, never a use-after-free (the old
    /// opacity flash captured the widget pointer across its timers).
    static func flash(surfaceId: UUID) {
        blink(surfaceId, on: true, afterMs: 1)
        blink(surfaceId, on: false, afterMs: 200)
        blink(surfaceId, on: true, afterMs: 400)
        blink(surfaceId, on: false, afterMs: 900)
    }

    private static func blink(_ surfaceId: UUID, on: Bool, afterMs: UInt32) {
        scheduleOnMainLoop(afterMs: afterMs) {
            guard let container = SurfaceRegistry.shared.containers[surfaceId] else { return }
            setClass("cmux-flash", on: container, enabled: on)
        }
    }

    /// Tier 2 (unread rings) and split dimming in one registry pass.
    /// Called from the scene body on every render — the same idiom as
    /// `SessionStore.saveIfChanged` — so every mutation path (bell, notify
    /// verbs, mark-read, dismiss, clear, focus moves) is covered without
    /// ten call sites. Widget-class writes only; no model state is
    /// touched, so this cannot re-trigger rendering.
    ///
    /// Dimming is macOS's `showsInactiveOverlay: isSplit && !isFocused`
    /// (unfocused-split-fill/opacity): a workspace with one pane dims
    /// nothing; in a split, every pane except the focused one drops to
    /// 0.78 opacity — the orientation cue the port lacked (UX-PARITY §4).
    static func sync(notifications: [TerminalNotification], tabs: [TerminalTab]) {
        let unread = Set(notifications.filter { !$0.isRead }.compactMap(\.surfaceId))
        var dimmed: Set<UUID> = []
        for tab in tabs {
            let leaves = tab.panes
            guard leaves.count > 1 else { continue }
            let focusedPane = tab.focusedSurface?.paneId
            for leaf in leaves where leaf.paneId != focusedPane {
                for surface in leaf.surfaces {
                    dimmed.insert(surface.surfaceId)
                }
            }
        }
        for (surfaceId, container) in SurfaceRegistry.shared.containers {
            setClass("cmux-unread", on: container, enabled: unread.contains(surfaceId))
            setClass("cmux-unfocused", on: container, enabled: dimmed.contains(surfaceId))
        }
    }

    private static func setClass(_ name: String, on container: OpaquePointer, enabled: Bool) {
        let widget = UnsafeMutableRawPointer(container).assumingMemoryBound(to: GtkWidget.self)
        if enabled {
            gtk_widget_add_css_class(widget, name)
        } else {
            gtk_widget_remove_css_class(widget, name)
        }
    }
}
