import CAdwShim
import CVte
import Foundation

/// Termux-style key row. Over Guacamole the on-screen keyboard has no
/// usable Esc/Tab/Ctrl/arrows for a terminal; this row feeds them to the
/// current pane. Ctrl is sticky: arm it, then the next key typed on any
/// keyboard (hardware, Guacamole OSK, …) is sent as a control character.
enum ExtraKeys {

    static var actions: [Int: () -> Void] = [:]
    static var ctrlButton: UnsafeMutablePointer<GtkWidget>?

    static func build() -> UnsafeMutablePointer<GtkWidget> {
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(OpaquePointer(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        gtk_widget_add_css_class(row, "mobile-keys")
        gtk_scrolled_window_set_child(OpaquePointer(scroller), row)

        let runtime = MobileShellRuntime.shared
        func key(_ label: String, _ bytes: [UInt8]) {
            append(row, button(label) { runtime.feed(bytes); runtime.focusCurrentTerminal() })
        }
        key("Esc", [0x1b])
        key("Tab", [0x09])
        // Sticky Ctrl.
        let ctrl = gtk_toggle_button_new_with_label("Ctrl")!
        gtk_widget_set_focus_on_click(ctrl, 0)
        ctrlButton = ctrl
        append(row, ctrl)
        key("←", [0x1b, 0x5b, 0x44])
        key("↑", [0x1b, 0x5b, 0x41])
        key("↓", [0x1b, 0x5b, 0x42])
        key("→", [0x1b, 0x5b, 0x43])
        for ch in ["/", "|", "-", "~", ":", "'", "\""] {
            key(ch, Array(ch.utf8))
        }
        append(row, button("⇔80") { runtime.fitted = false; runtime.fitPasses = 0; runtime.fitTicks = 0; _ = g_timeout_add(120, mobileFitTick, nil) })
        append(row, button("A−") { runtime.onFontScale(max(0.4, runtime.fontScale - 0.1)) })
        append(row, button("A+") { runtime.onFontScale(min(2.0, runtime.fontScale + 0.1)) })
        append(row, button("‹") { scroll(by: -1) })
        append(row, button("›") { scroll(by: 1) })
        return scroller
    }

    private static func scroll(by delta: Int) {
        let runtime = MobileShellRuntime.shared
        guard let carousel = runtime.carousel, !runtime.panes.isEmpty else { return }
        let target = max(0, min(runtime.panes.count - 1, runtime.currentIndex + delta))
        adw_carousel_scroll_to(carousel, runtime.panes[target].page, 1)
    }

    private static func append(_ row: UnsafeMutablePointer<GtkWidget>, _ child: UnsafeMutablePointer<GtkWidget>) {
        gtk_box_append(cast(row), child)
    }

    private static func button(_ label: String, _ action: @escaping () -> Void) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new_with_label(label)!
        gtk_widget_set_focus_on_click(button, 0)
        let id = actions.count + 1
        actions[id] = action
        g_signal_connect_data(
            UnsafeMutableRawPointer(button), "clicked",
            unsafeBitCast(extraKeyClicked, to: GCallback.self),
            UnsafeMutableRawPointer(bitPattern: id), nil, GConnectFlags(0)
        )
        return button
    }

    /// Key controller on a terminal: with Ctrl armed, the next printable
    /// key becomes its control character and disarms the toggle.
    static func installStickyCtrl(on terminal: UnsafeMutablePointer<GtkWidget>) {
        let controller = gtk_event_controller_key_new()!
        gtk_event_controller_set_propagation_phase(controller, GTK_PHASE_CAPTURE)
        g_signal_connect_data(
            UnsafeMutableRawPointer(controller), "key-pressed",
            unsafeBitCast(extraKeyPressed, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        gtk_widget_add_controller(terminal, controller)
    }

    static var ctrlArmed: Bool {
        guard let ctrlButton else { return false }
        return gtk_toggle_button_get_active(cast(ctrlButton)) != 0
    }

    static func disarmCtrl() {
        guard let ctrlButton else { return }
        gtk_toggle_button_set_active(cast(ctrlButton), 0)
    }
}

let extraKeyClicked: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, userData in
    guard let userData else { return }
    ExtraKeys.actions[Int(bitPattern: userData)]?()
}

let extraKeyPressed: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Int32
= { _, keyval, _, _, _ in
    guard ExtraKeys.ctrlArmed else { return 0 }
    let unicode = gdk_keyval_to_unicode(keyval)
    guard unicode >= 0x40, unicode < 0x80 || (unicode >= 0x61 && unicode <= 0x7a) else { return 0 }
    var byte = UInt8(truncatingIfNeeded: unicode)
    if byte >= 0x61, byte <= 0x7a { byte -= 0x20 }   // a-z → A-Z
    guard byte >= 0x40, byte <= 0x5f else { return 0 }
    ExtraKeys.disarmCtrl()
    MobileShellRuntime.shared.feed([byte & 0x1f])
    return 1
}
