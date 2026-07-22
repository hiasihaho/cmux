import CAdw
import Foundation

/// The preferences window (Ctrl+comma / the gear button).
///
/// Built in raw libadwaita C — adwaita-swift binds the preference *rows*
/// but not `GtkScale`, and the scrollback budget genuinely wants a
/// slider. Three settings on day one, each writing through
/// `LinuxSettings` into `~/.config/cmux/cmux.json`:
///
/// - terminal backend (ComboRow; applies at next launch — the Ghostty
///   runtime initializes once),
/// - scrollback budget (slider over presets; applies to the next save),
/// - browser search URL (EntryRow; applies to the next search).
enum PreferencesWindow {

    /// Preset stops for the scrollback slider. A linear byte scale is
    /// useless (64 KB and 8 MB on one axis), so the slider moves across
    /// presets and the marks say what they mean. 0 = keep everything.
    static let scrollbackStops: [(chars: Int, label: String)] = [
        (16 * 1024, "16 KB"),
        (64 * 1024, "64 KB"),
        (256 * 1024, "256 KB"),
        (1024 * 1024, "1 MB"),
        (8 * 1024 * 1024, "8 MB"),
        (0, "All"),
    ]

    static func stopIndex(for limit: Int) -> Int {
        if limit == 0 { return scrollbackStops.count - 1 }
        // Nearest stop, so an off-preset value from a hand-edited file
        // still lands somewhere sensible instead of crashing the slider.
        var best = 0
        var bestDistance = Int.max
        for (index, stop) in scrollbackStops.enumerated() where stop.chars != 0 {
            let distance = abs(stop.chars - limit)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private static var window: UnsafeMutablePointer<GtkWidget>?

    /// Presents the window, creating it on first use. One instance —
    /// presenting again raises it.
    static func present() {
        if let window {
            gtk_window_present(UnsafeMutableRawPointer(window).assumingMemoryBound(to: GtkWindow.self))
            return
        }
        guard let created = adw_preferences_window_new() else { return }
        window = created
        let gtkWindow = UnsafeMutableRawPointer(created).assumingMemoryBound(to: GtkWindow.self)
        gtk_window_set_title(gtkWindow, "cmux Preferences")
        gtk_window_set_default_size(gtkWindow, 560, 480)
        // Hide on close instead of destroy, so state (and this pointer)
        // survive reopening.
        gtk_window_set_hide_on_close(gtkWindow, 1)

        let page = adw_preferences_page_new()
        adw_preferences_window_add(
            UnsafeMutableRawPointer(created).assumingMemoryBound(to: AdwPreferencesWindow.self),
            UnsafeMutableRawPointer(page!).assumingMemoryBound(to: AdwPreferencesPage.self)
        )

        addTerminalGroup(to: page!)
        addBrowserGroup(to: page!)

        gtk_window_present(gtkWindow)
    }

    // MARK: terminal group

    private static func addTerminalGroup(to page: UnsafeMutablePointer<GtkWidget>) {
        let group = adw_preferences_group_new()
        adw_preferences_group_set_title(
            UnsafeMutableRawPointer(group!).assumingMemoryBound(to: AdwPreferencesGroup.self),
            "Terminal"
        )

        // Backend chooser. Selection index matches the model order below.
        let combo = adw_combo_row_new()
        let comboRow = UnsafeMutableRawPointer(combo!).assumingMemoryBound(to: AdwComboRow.self)
        adw_preferences_row_set_title(
            UnsafeMutableRawPointer(combo!).assumingMemoryBound(to: AdwPreferencesRow.self),
            "Terminal backend"
        )
        adw_action_row_set_subtitle(
            UnsafeMutableRawPointer(combo!).assumingMemoryBound(to: AdwActionRow.self),
            "Ghostty is the default; VTE is the fallback. Applies to the next launch."
        )
        let backends: [UnsafePointer<CChar>?] = [
            UnsafePointer(strdup("Ghostty")), UnsafePointer(strdup("VTE")), nil,
        ]
        backends.withUnsafeBufferPointer { buffer in
            // In CAdw's view of GTK the string list is directly a model.
            adw_combo_row_set_model(comboRow, gtk_string_list_new(buffer.baseAddress))
        }
        adw_combo_row_set_selected(
            comboRow, LinuxSettings.terminalBackend == .ghostty ? 0 : 1
        )
        g_signal_connect_data(
            UnsafeMutableRawPointer(combo!), "notify::selected",
            unsafeBitCast(preferencesBackendChanged, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        adw_preferences_group_add(
            UnsafeMutableRawPointer(group!).assumingMemoryBound(to: AdwPreferencesGroup.self), combo
        )

        // Scrollback budget: an ActionRow whose activatable area holds the
        // slider, marks labelled with the preset sizes.
        let row = adw_action_row_new()
        adw_preferences_row_set_title(
            UnsafeMutableRawPointer(row!).assumingMemoryBound(to: AdwPreferencesRow.self),
            "Scrollback kept per pane"
        )
        adw_action_row_set_subtitle(
            UnsafeMutableRawPointer(row!).assumingMemoryBound(to: AdwActionRow.self),
            "How much terminal history a session restore brings back."
        )
        let scale = gtk_scale_new_with_range(
            GTK_ORIENTATION_HORIZONTAL, 0, Double(scrollbackStops.count - 1), 1
        )
        let scaleWidget = scale!
        let scalePtr = UnsafeMutableRawPointer(scaleWidget).assumingMemoryBound(to: GtkScale.self)
        gtk_scale_set_draw_value(scalePtr, 0)
        gtk_widget_set_size_request(scaleWidget, 260, -1)
        gtk_widget_set_valign(scaleWidget, GTK_ALIGN_CENTER)
        for (index, stop) in scrollbackStops.enumerated() {
            gtk_scale_add_mark(scalePtr, Double(index), GTK_POS_BOTTOM, stop.label)
        }
        let range = UnsafeMutableRawPointer(scaleWidget).assumingMemoryBound(to: GtkRange.self)
        gtk_range_set_value(range, Double(stopIndex(for: LinuxSettings.scrollbackLimit)))
        g_signal_connect_data(
            UnsafeMutableRawPointer(scaleWidget), "value-changed",
            unsafeBitCast(preferencesScrollbackChanged, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        adw_action_row_add_suffix(
            UnsafeMutableRawPointer(row!).assumingMemoryBound(to: AdwActionRow.self), scaleWidget
        )
        adw_preferences_group_add(
            UnsafeMutableRawPointer(group!).assumingMemoryBound(to: AdwPreferencesGroup.self), row
        )

        adw_preferences_page_add(
            UnsafeMutableRawPointer(page).assumingMemoryBound(to: AdwPreferencesPage.self),
            UnsafeMutableRawPointer(group!).assumingMemoryBound(to: AdwPreferencesGroup.self)
        )
    }

    // MARK: browser group

    private static func addBrowserGroup(to page: UnsafeMutablePointer<GtkWidget>) {
        let group = adw_preferences_group_new()
        adw_preferences_group_set_title(
            UnsafeMutableRawPointer(group!).assumingMemoryBound(to: AdwPreferencesGroup.self),
            "Browser"
        )
        let entry = adw_entry_row_new()
        adw_preferences_row_set_title(
            UnsafeMutableRawPointer(entry!).assumingMemoryBound(to: AdwPreferencesRow.self),
            "Search URL (%s = query)"
        )
        gtk_editable_set_text(OpaquePointer(entry!), LinuxSettings.searchURL)
        // apply on Enter/focus-out via the editable's changed signal with
        // a debounce-free write: the value is tiny and writes are atomic.
        g_signal_connect_data(
            UnsafeMutableRawPointer(entry!), "changed",
            unsafeBitCast(preferencesSearchURLChanged, to: GCallback.self),
            nil, nil, GConnectFlags(0)
        )
        adw_preferences_group_add(
            UnsafeMutableRawPointer(group!).assumingMemoryBound(to: AdwPreferencesGroup.self), entry
        )
        adw_preferences_page_add(
            UnsafeMutableRawPointer(page).assumingMemoryBound(to: AdwPreferencesPage.self),
            UnsafeMutableRawPointer(group!).assumingMemoryBound(to: AdwPreferencesGroup.self)
        )
    }
}

// C signal handlers (cannot capture; settings are global state anyway).

let preferencesBackendChanged: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { comboPtr, _, _ in
    guard let comboPtr else { return }
    let selected = adw_combo_row_get_selected(comboPtr.assumingMemoryBound(to: AdwComboRow.self))
    LinuxSettings.update(["terminalBackend": selected == 1 ? "vte" : "ghostty"])
}

let preferencesScrollbackChanged: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { scalePtr, _ in
    guard let scalePtr else { return }
    let value = gtk_range_get_value(scalePtr.assumingMemoryBound(to: GtkRange.self))
    let index = max(0, min(PreferencesWindow.scrollbackStops.count - 1, Int(value.rounded())))
    LinuxSettings.update(["scrollbackLimit": PreferencesWindow.scrollbackStops[index].chars])
}

let preferencesSearchURLChanged: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> Void = { entryPtr, _ in
    guard let entryPtr,
          let raw = gtk_editable_get_text(OpaquePointer(entryPtr)) else { return }
    let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    // An empty template would break search silently; empty clears back to
    // the default instead.
    LinuxSettings.update(["searchUrl": text.isEmpty ? NSNull() : text])
}
