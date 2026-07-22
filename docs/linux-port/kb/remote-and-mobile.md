# Remote workspaces (SSH) and the iOS companion — architecture notes

> Sources: https://cmux.com/en/docs/ssh, /en/docs/ios, /en/docs/remote-tmux,
> /en/blog/cmux-ssh, /en/docs/changelog (0.63.0, 0.64.11, 0.64.13).
> Crawled 2026-07-22 via the port's own browser. Out of scope for the port
> today (CONCEPTS), but the relay architecture matters for tmux-compat over
> SSH and any future Linux remote story.

## cmux ssh — remote machine as a first-class workspace

`cmux ssh user@host [--name --command -p -i -o --no-focus]`; reads
~/.ssh/config (aliases, identities, proxies). What makes it more than a shell:

- **Relay daemon (`cmuxd-remote`, Go)**: on first connect cmux probes
  `uname -s/-m`, uploads a versioned binary to
  `~/.cmux/bin/cmuxd-remote/<version>/<os>-<arch>/`, verifies it against a
  SHA-256 manifest embedded in the app. It speaks JSON-RPC over stdio and
  provides: (1) browser traffic proxying — SOCKS5 + HTTP CONNECT over stdio,
  so embedded browser panes in that workspace browse *from the remote
  network* (`localhost:3000` = remote dev server; isolated per-connection
  cookie store); (2) **CLI relay** — reverse TCP tunnel with HMAC-SHA256 auth
  so remote processes can run `cmux notify` etc. against the *local* app
  ("agent notifications come home"); (3) session persistence across
  reconnects + PTY resize coordination (smallest-screen-wins).
- **Detachable PTY daemon** (0.64.11): remote sessions survive dropped
  connections; reconnect with exponential backoff 3s→60s; keepalives
  (ServerAliveInterval=20, CountMax=2) injected unless configured; manual
  reconnect via Enter in a dead pane.
- Drag-and-drop upload via scp through the existing ControlMaster connection
  (foreground SSH process detected by TTY); `terminal.uploadCommands` can
  replace scp per host.
- SSH agent forwarding (0.64.13) so remote git pushes use local keys.
- `cmux claude-teams` / `cmux omo` work inside SSH sessions — the Go daemon
  performs the same tmux-compat translation as the local Swift CLI; teammates
  spawn as native splits locally while compute stays remote.
- Notification spam from flaky hosts is rate-limited per host.

Deep links for "Open in cmux" buttons: `cmux://ssh?...` + https fallback
(kb/cli-reference.md). External links can never carry identity files, raw SSH
options, or commands; a command preview + trust prompt gates connecting.

## Remote tmux mirror

Separate beta feature: control-mode (`tmux -CC`) reprojection of a remote
tmux server into native cmux UI — full mapping and socket verbs in
kb/tmux-compat.md §2.

## iOS companion (TestFlight beta, Founders Edition early access)

Pair iPhone/iPad ↔ Mac via the Mobile Connect window; **bring your own
network** (Tailscale recommended, WireGuard fine) — "the terminal stream
flows directly between your phone and your Mac"; cmux servers store only
account email, push token, pairing/device metadata. Optional notification
forwarding transits cmux servers + APNs (Hide-content mode sends a generic
message). Feature march per changelog: workspace list with groups/unread/
previews, terminal composer with dictation + image attachments, browser
panes, files gallery, authenticated Iroh transport. Enterprise/air-gapped:
contact founders@manaflow.com.
