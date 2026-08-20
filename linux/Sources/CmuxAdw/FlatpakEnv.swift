import Foundation

/// Flatpak-awareness for the Linux port (feature doc:
/// docs/linux-port/features/15-flatpak-packaging.md, round 2).
///
/// Inside the sandbox (`FLATPAK_ID` set) three defaults change:
/// - pane shells spawn on the HOST through the org.freedesktop.Flatpak
///   portal (`flatpak-spawn --host`) — the sandbox /usr is the slim
///   GNOME runtime, not the user's dev environment;
/// - the control socket lands in `$XDG_RUNTIME_DIR/app/$FLATPAK_ID/`,
///   the one sandbox path the host can reach with zero extra
///   permissions (probe-verified 2026-08-20);
/// - session state gets its own `cmux-flatpak` directory so a flatpak
///   instance can never write a host instance's session store — the
///   scrollback store lives in dirname(session) and is PRUNED on every
///   save (the 2026-07-22 trap class).
enum FlatpakEnv {
    static var id: String? {
        let raw = ProcessInfo.processInfo.environment["FLATPAK_ID"]
        return (raw?.isEmpty ?? true) ? nil : raw
    }

    static var isFlatpak: Bool { id != nil }

    /// CMUX_FLATPAK_HOST_SHELL=0/false keeps pane shells inside the
    /// sandbox (round-1 behavior; also the fallback if the portal is
    /// blocked).
    static var hostShellEnabled: Bool {
        guard isFlatpak else { return false }
        let raw = ProcessInfo.processInfo.environment["CMUX_FLATPAK_HOST_SHELL"]?
            .lowercased()
        return raw != "0" && raw != "false"
    }

    /// The one spawn rewrite every pane path shares (shell, respawn,
    /// dock panel — shared-behavior policy). Outside the sandbox (or
    /// when disabled) argv passes through untouched. Inside, the argv
    /// is wrapped in `flatpak-spawn --host`: `extraEnv` (the cmux pane
    /// identity) plus TERM/COLORTERM are forwarded explicitly with
    /// --env; --watch-bus ties host children to the app's bus presence
    /// so a killed sandbox never leaks host shells.
    static func spawnArgv(
        _ argv: [String],
        cwd: String?,
        extraEnv: [String: String]
    ) -> [String] {
        guard hostShellEnabled else { return argv }
        var out = ["/usr/bin/flatpak-spawn", "--host", "--watch-bus"]
        if let cwd, !cwd.isEmpty { out.append("--directory=\(cwd)") }
        var env = extraEnv
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["COLORTERM"] = env["COLORTERM"] ?? "truecolor"
        for (key, value) in env.sorted(by: { $0.key < $1.key }) {
            out.append("--env=\(key)=\(value)")
        }
        out.append(contentsOf: argv)
        return out
    }

    /// Host-side login-shell argv for a pane. Two constraints meet here:
    /// the sandbox's $SHELL is the runtime's sh, so the user's real
    /// shell must resolve on the HOST (the portal forwards the host
    /// session env); and the VTE pty's controlling-terminal slot is
    /// already taken by the sandbox-side session, so a plain host shell
    /// has no job control and `setsid --ctty` gets EPERM. util-linux
    /// `script` allocates a FRESH host pty and makes the shell a proper
    /// session leader inside it — full job control, io relayed to the
    /// VTE pty. `script` is probed at RUNTIME on the host (Fedora splits
    /// it into util-linux-script; some hosts lack it): without it the
    /// shell still opens, with bash's job-control warnings as the only
    /// cost. Never fail a pane over a missing nicety.
    static let hostLoginShellArgv = ["sh", "-c", #"""
        if command -v script >/dev/null 2>&1; then
          exec script -qfc "${SHELL:-/bin/bash}" /dev/null
        else
          exec "${SHELL:-/bin/bash}"
        fi
        """#]
}
