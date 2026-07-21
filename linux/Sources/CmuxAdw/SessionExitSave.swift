import CVte
import Foundation

/// One last save when the human closes the window.
///
/// Terminal output is not a model change, so a pane's text reaches disk
/// only on the periodic pass. Run `ls`, close the window, reopen — and the
/// pane comes back showing whatever happened to be there up to fifteen
/// seconds earlier, or nothing at all if the pass had not run since the
/// pane was created. Browser navigation had exactly this shape of bug and
/// was fixed with a debounced save; this is the terminal half of it.
///
/// The hook is the window's `close-request`, deliberately, not the
/// application's `shutdown`: by shutdown time the widgets are already
/// destroyed, so a save then reads nothing from every pane — the worst
/// possible moment to write. `close-request` fires while the terminals are
/// still alive, which is the whole point.
enum SessionExitSave {

    private static var installed = false

    /// Connects the hook if the application has a window yet. Returns
    /// false while it does not, so the caller can try again — the app is
    /// not registered (and `g_application_get_default()` is nil) for the
    /// first moments of startup.
    @discardableResult
    static func install(save: @escaping () -> Void) -> Bool {
        guard !installed else { return true }
        // Test-only kill switch, so the A/B harness can run the identical
        // binary with and without the hook and attribute a rescued save to
        // it — frequent title-change saves otherwise mask the comparison.
        // Never set outside tests.
        if ProcessInfo.processInfo.environment["CMUX_DISABLE_EXIT_SAVE"] == "1" {
            installed = true
            return true
        }
        guard let application = g_application_get_default() else { return false }
        let gtkApplication = UnsafeMutableRawPointer(application)
            .assumingMemoryBound(to: GtkApplication.self)

        var node = gtk_application_get_windows(gtkApplication)
        var connected = false
        while let current = node {
            if let window = current.pointee.data {
                let box = SessionExitSaveBox(save: save)
                g_signal_connect_data(
                    window, "close-request",
                    unsafeBitCast(sessionExitSaveCloseRequest, to: GCallback.self),
                    Unmanaged.passRetained(box).toOpaque(),
                    sessionExitSaveBoxDestroy, GConnectFlags(0)
                )
                connected = true
            }
            node = current.pointee.next
        }
        installed = connected
        if connected {
            FileHandle.standardError.write(Data("cmux: exit save installed\n".utf8))
        }
        return connected
    }
}

final class SessionExitSaveBox {
    let save: () -> Void
    init(save: @escaping () -> Void) { self.save = save }
}

let sessionExitSaveBoxDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<SessionExitSaveBox>.fromOpaque(data).release()
}

/// `close-request` returns whether to *block* the close. We only want the
/// side effect, so this always returns FALSE and the window closes as the
/// human asked — a save must never be able to trap someone in the app.
let sessionExitSaveCloseRequest: @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?
) -> gboolean = { _, userData in
    guard let userData else { return 0 }
    // Breadcrumb, deliberately kept: the A/B harness and the smoke suite
    // assert on it, and "did the final save even run?" is the first
    // question when a session comes back stale.
    FileHandle.standardError.write(Data("cmux: exit save firing\n".utf8))
    Unmanaged<SessionExitSaveBox>.fromOpaque(userData).takeUnretainedValue().save()
    return 0
}
