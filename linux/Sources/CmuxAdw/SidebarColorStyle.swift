import CVte
import Foundation

/// Renders workspace identity colors as a **left rail** on sidebar rows —
/// the macOS `.leftRail` indicator style (MACOS-UX §1.2). Same contract
/// as AttentionStyle: called from the scene body on every render,
/// widget-class writes only, no model state touched.
///
/// Arbitrary hex values become generated CSS classes on ONE provider,
/// regenerated when a color first appears: `.cmux-wsrail-N` (the row
/// rail) and `.cmux-swatch-N` (the palette popover's colored circles).
enum SidebarColorStyle {

    private static var provider: UnsafeMutablePointer<GtkCssProvider>?
    private static var classIndex: [String: Int] = [:]

    static func railClass(for hex: String) -> String {
        "cmux-wsrail-\(index(for: hex))"
    }

    static func swatchClass(for hex: String) -> String {
        "cmux-swatch-\(index(for: hex))"
    }

    private static func index(for hex: String) -> Int {
        if let n = classIndex[hex] { return n }
        let n = classIndex.count
        classIndex[hex] = n
        regenerate()
        return n
    }

    private static func regenerate() {
        guard let display = gdk_display_get_default() else { return }
        if provider == nil {
            provider = gtk_css_provider_new()
            if let provider {
                // GtkStyleProvider is an interface — pass opaquely, like
                // AttentionStyle.install.
                gtk_style_context_add_provider_for_display(
                    display, OpaquePointer(provider), 600)
            }
        }
        guard let provider else { return }
        var css = ""
        for (hex, n) in classIndex {
            css += ".cmux-wsrail-\(n) { box-shadow: inset 4px 0 0 \(hex); }\n"
            css += ".cmux-swatch-\(n) { background-color: \(hex); "
                + "min-width: 22px; min-height: 22px; }\n"
        }
        gtk_css_provider_load_from_string(provider, css)
    }

    /// Applies rail classes to the sidebar's rows by index — the rows
    /// come from the SAME projection the List renders, so index i here
    /// is row i there. `active` is false while the notifications page
    /// occupies the sidebar slot (its list carries the same style class
    /// and must not receive rails).
    static func sync(rows: [SidebarRowModel], active: Bool) {
        guard active, let list = sidebarListBox() else { return }
        let known = classIndex.count
        for index in 0..<max(rows.count, 64) {
            guard let rowWidget = gtk_list_box_get_row_at_index(
                OpaquePointer(list), Int32(index)) else { break }
            let widget = UnsafeMutableRawPointer(rowWidget)
                .assumingMemoryBound(to: GtkWidget.self)
            for n in 0..<known {
                gtk_widget_remove_css_class(widget, "cmux-wsrail-\(n)")
            }
            guard rows.indices.contains(index) else { continue }
            let row = rows[index]
            if case .workspace = row.kind, let hex = row.colorHex {
                gtk_widget_add_css_class(widget, railClass(for: hex))
            }
        }
    }

    /// The workspace list: the first navigation-sidebar ListBox in the
    /// widget tree. (The notifications list shares the style class but
    /// is only mounted when `active` is false above.) Shared with
    /// SidebarDnD.
    static func listBox() -> UnsafeMutablePointer<GtkWidget>? {
        sidebarListBox()
    }

    private static func sidebarListBox() -> UnsafeMutablePointer<GtkWidget>? {
        guard let window = UIDialogs.mainWindowWidget() else { return nil }
        return findNavigationSidebar(in: window)
    }

    private static func findNavigationSidebar(
        in widget: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkWidget>? {
        if gtk_widget_has_css_class(widget, "navigation-sidebar") != 0 { return widget }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            if let found = findNavigationSidebar(in: current) { return found }
            child = gtk_widget_get_next_sibling(current)
        }
        return nil
    }
}
