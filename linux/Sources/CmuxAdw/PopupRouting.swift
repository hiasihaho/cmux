import CWebKit
import Foundation

/// `window.open()` / `target="_blank"` routed into cmux panes
/// (roadmap/06 increment 5).
///
/// Before this, popups did nothing at all — and nothing is exactly what the
/// caller saw: no error, no pane, `window.open` returning null. Probed with
/// `linux/tests/popup-probe.c` against webkitgtk-6.0 2.52.4:
///
/// - `javascript-can-open-windows-automatically` defaults to **FALSE**, and
///   while it is off `create` never fires at all. That single default is
///   the whole hole.
/// - The view handed back must be built with the **construct-only**
///   `related-view` property (`webkit_web_view_new_with_related_view` was
///   dropped in 6.0); sharing the web process is what keeps `window.opener`
///   working.
/// - **WebKit loads the URL into the returned view itself.** Loading it
///   here too would fetch twice.
/// - Returning NULL is a clean block: the page just sees `window.open`
///   return null.
enum PopupRouting {

    /// Wired by the app: adopts a freshly created popup view into a split
    /// beside its opener. Returns false if no pane could be made, which
    /// tells the handler to decline rather than hand back an orphan view.
    static var adopt: ((OpaquePointer, UUID) -> Bool)?

    /// Disabling the popup blocker means a page can ask for panes in a
    /// loop. Routing popups into visible panes is friendlier than hidden
    /// windows, but it is still an unbounded request from the page, so it
    /// gets a per-opener budget. Compare roadmap/05: agent- or
    /// page-drivable resource growth is the same class of problem.
    private static let burstLimit = 5
    private static let burstWindow: TimeInterval = 10
    private static var recent: [UUID: [Date]] = [:]

    static func allowPopup(from opener: UUID) -> Bool {
        let now = Date()
        var times = (recent[opener] ?? []).filter { now.timeIntervalSince($0) < burstWindow }
        guard times.count < burstLimit else {
            recent[opener] = times
            return false
        }
        times.append(now)
        recent[opener] = times
        return true
    }

    static func forget(_ opener: UUID) {
        recent.removeValue(forKey: opener)
    }
}

/// Carries the opener's surface id across the C `create` callback.
final class PopupOpenerBox {
    let surfaceId: UUID
    init(surfaceId: UUID) { self.surfaceId = surfaceId }
}

let popupOpenerBoxDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<PopupOpenerBox>.fromOpaque(data).release()
}

/// `create`: the page wants a new window. Build a related view, hand it to
/// a new pane, and return it so WebKit loads the target URL into it.
let popupCreate: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> UnsafeMutableRawPointer? = { parentPtr, actionPtr, userData in
    guard let parentPtr, let userData else { return nil }
    let opener = Unmanaged<PopupOpenerBox>.fromOpaque(userData).takeUnretainedValue()

    let targetURL: String = {
        guard let actionPtr else { return "" }
        let action = OpaquePointer(actionPtr)
        guard let request = webkit_navigation_action_get_request(action),
              let uri = webkit_uri_request_get_uri(request) else { return "" }
        return String(cString: uri)
    }()

    guard PopupRouting.allowPopup(from: opener.surfaceId) else {
        popupLog("blocked popup burst from \(opener.surfaceId) (url: \(targetURL))")
        return nil
    }

    // related-view is construct-only, so it can only be set at construction
    // — and the variadic g_object_new is unusable from Swift, so this goes
    // through g_object_new_with_properties like the WebDriver view does.
    var relatedValue = GValue()
    _ = g_value_init(&relatedValue, webkit_web_view_get_type())
    g_value_set_object(&relatedValue, parentPtr)
    let relatedName = strdup("related-view")
    defer {
        free(relatedName)
        g_value_unset(&relatedValue)
    }
    var names: [UnsafePointer<CChar>?] = [UnsafePointer(relatedName)]
    var values: [GValue] = [relatedValue]
    let created = names.withUnsafeMutableBufferPointer { namePtr in
        values.withUnsafeMutableBufferPointer { valuePtr in
            g_object_new_with_properties(
                webkit_web_view_get_type(), 1, namePtr.baseAddress, valuePtr.baseAddress
            )
        }
    }
    guard let created else {
        popupLog("failed to create related view for \(targetURL)")
        return nil
    }
    let raw = UnsafeMutableRawPointer(created)
    let view = OpaquePointer(raw)

    guard PopupRouting.adopt?(view, opener.surfaceId) == true else {
        // No pane to put it in: drop the view and decline, so WebKit's own
        // handling stands instead of the page getting a window that exists
        // nowhere.
        popupLog("no pane available for popup \(targetURL) — declining")
        g_object_unref(raw)
        return nil
    }

    popupLog("routed popup into a pane: \(targetURL.isEmpty ? "(deferred url)" : targetURL)")
    // Deliberately NOT loading targetURL: WebKit loads it into this view
    // itself, and doing it here would fetch twice.
    return raw
}

func popupLog(_ message: String) {
    FileHandle.standardError.write(Data("cmux popup: \(message)\n".utf8))
}
