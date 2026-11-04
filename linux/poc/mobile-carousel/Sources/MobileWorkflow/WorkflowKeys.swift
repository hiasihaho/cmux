import CAdwShim
import CVte
import Foundation

/// Termux-style key row. Over Guacamole the on-screen keyboard has no
/// usable Esc/Tab/Ctrl/arrows for a terminal; this row feeds them to the
/// current pane. Ctrl is sticky: arm it, then the next key typed on any
/// keyboard (hardware, Guacamole OSK, …) is sent as a control character.
enum WorkflowKeys {

    static var actions: [Int: () -> Void] = [:]
    static var ctrlButton: UnsafeMutablePointer<GtkWidget>?

    static func build() -> UnsafeMutablePointer<GtkWidget> {
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(OpaquePointer(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER)
        let row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4)!
        gtk_widget_add_css_class(row, "mobile-keys")
        gtk_scrolled_window_set_child(OpaquePointer(scroller), row)
        // Over RDP a finger is a mouse: GtkScrolledWindow only pans for
        // touch sequences, so a mouse drag must pan the row by hand. The
        // gesture runs in capture phase; once it claims (past the drag
        // threshold) the button underneath never sees a click.
        let drag = gtk_gesture_drag_new()!
        gtk_event_controller_set_propagation_phase(drag, GTK_PHASE_CAPTURE)
        g_signal_connect_data(
            UnsafeMutableRawPointer(drag), "drag-begin",
            unsafeBitCast(workflowKeysDragBegin, to: GCallback.self),
            UnsafeMutableRawPointer(scroller), nil, GConnectFlags(0)
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(drag), "drag-update",
            unsafeBitCast(workflowKeysDragUpdate, to: GCallback.self),
            UnsafeMutableRawPointer(scroller), nil, GConnectFlags(0)
        )
        gtk_widget_add_controller(scroller, drag)

        let runtime = WorkflowRuntime.shared
        func key(_ label: String, _ bytes: [UInt8]) {
            append(row, button(label) { runtime.feed(bytes); runtime.focusCurrentPane() })
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
        append(row, button("⇔80") { runtime.fitted = false; runtime.fitPasses = 0; runtime.fitTicks = 0; _ = g_timeout_add(120, workflowFitTick, nil) })
        append(row, button("A−") { runtime.onFontScale(max(0.4, runtime.fontScale - 0.1)) })
        append(row, button("A+") { runtime.onFontScale(min(2.0, runtime.fontScale + 0.1)) })
        return scroller
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
            unsafeBitCast(workflowKeyClicked, to: GCallback.self),
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
            unsafeBitCast(workflowKeyPressed, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        gtk_widget_add_controller(terminal, controller)
    }

    static var dragStartValue = 0.0

    static var ctrlArmed: Bool {
        guard let ctrlButton else { return false }
        return gtk_toggle_button_get_active(cast(ctrlButton)) != 0
    }

    static func disarmCtrl() {
        guard let ctrlButton else { return }
        gtk_toggle_button_set_active(cast(ctrlButton), 0)
    }
}

let workflowKeyClicked: @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
= { _, userData in
    guard let userData else { return }
    WorkflowKeys.actions[Int(bitPattern: userData)]?()
}

let workflowKeyPressed: @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UInt32, UnsafeMutableRawPointer?) -> Int32
= { _, keyval, _, _, _ in
    guard WorkflowKeys.ctrlArmed else { return 0 }
    let unicode = gdk_keyval_to_unicode(keyval)
    guard unicode >= 0x40, unicode < 0x80 || (unicode >= 0x61 && unicode <= 0x7a) else { return 0 }
    var byte = UInt8(truncatingIfNeeded: unicode)
    if byte >= 0x61, byte <= 0x7a { byte -= 0x20 }   // a-z → A-Z
    guard byte >= 0x40, byte <= 0x5f else { return 0 }
    WorkflowKeys.disarmCtrl()
    WorkflowRuntime.shared.feed([byte & 0x1f])
    return 1
}

let workflowKeysDragBegin: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void
= { _, _, _, scroller in
    guard let scroller else { return }
    let adjustment = gtk_scrolled_window_get_hadjustment(OpaquePointer(scroller))
    WorkflowKeys.dragStartValue = gtk_adjustment_get_value(adjustment)
}

let workflowKeysDragUpdate: @convention(c) (UnsafeMutableRawPointer?, Double, Double, UnsafeMutableRawPointer?) -> Void
= { gesture, offsetX, _, scroller in
    guard let scroller, let gesture else { return }
    if abs(offsetX) > 8 {
        gtk_gesture_set_state(OpaquePointer(gesture), GTK_EVENT_SEQUENCE_CLAIMED)
    }
    let adjustment = gtk_scrolled_window_get_hadjustment(OpaquePointer(scroller))
    gtk_adjustment_set_value(adjustment, WorkflowKeys.dragStartValue - offsetX)
}
