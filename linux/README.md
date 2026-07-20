# cmux for Linux (GTK4 / libadwaita port)

Work-in-progress port of cmux from Swift + AppKit/SwiftUI to Swift +
[Adwaita for Swift](https://git.aparoksha.dev/aparoksha/adwaita-swift)
(libadwaita/GTK4). The Swift language stays; the Apple UI frameworks go.

See [`../docs/linux-port/FEATURES.md`](../docs/linux-port/FEATURES.md) for a
feature overview (and what's beyond macOS parity), and
[`../docs/linux-port/PORTING.md`](../docs/linux-port/PORTING.md) for the full
analysis and phased plan.

## Status

- [x] Phase 0 — walking skeleton: Adwaita shell with vertical tab sidebar,
      attention indicators, tab management (this package)
- [x] Phase 1 — control socket + CLI: `cmux-adw` serves the cmux socket
      protocol (v1 + v2 subset) on `$XDG_RUNTIME_DIR/cmux.sock`; the shared
      `CLI/cmux.swift` builds as the `cmux` binary and works against it
      (`ping`, `list-workspaces`, `new-workspace`, `select-workspace`,
      `notify` → sidebar attention dots, `list-notifications`, …)
- [x] Phase 2 (part 1) — real terminals: VTE-GTK4 surfaces, one live shell
      per tab (kept alive across switches), OSC titles → tab titles, bell →
      attention dots, `cmux send`/`read-screen` work; shells get
      `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID`/`CMUX_SOCKET_PATH`
- [~] Phase 2 (part 2) — Ghostty fidelity: embedded Ghostty surfaces work
      behind `CMUX_GHOSTTY=1` build + `CMUX_TERM=ghostty` runtime (titles,
      pwd, bell, focus, splits, session restore); `send`/`read-screen`
      verbs and eager background spawn still VTE-only — plan and status in
      [`../docs/linux-port/GHOSTTY-SHIM.md`](../docs/linux-port/GHOSTTY-SHIM.md)
- [x] Phase 3 (part 1) — XDG desktop notifications for background tabs
      (GNotification; run `scripts/install-desktop-entry.sh` once so GNOME
      displays them) and `send-key` (enter/ctrl-c/arrows/…)
- [x] Phase 3 (part 2) — notifications page in the sidebar (bell button):
      unread dots, click-to-jump (focuses the exact surface), clear-all,
      unread count in the sidebar title
- [x] Phase 4a — split panes: nested GtkPaned tree per workspace, one live
      shell per pane (reparented across layout changes, never respawned),
      focus-follows-click, cwd inheritance; `new-split`/`list-panes`/
      `focus-pane`/`close-surface` + header-bar split buttons
- [x] Phase 4b — session persistence: workspaces/pane trees/live cwds to
      `$XDG_DATA_HOME/cmux/session-linux.json`, restored on launch; divider
      positions survive layout changes; Ctrl+Shift+T/D/S/W shortcuts
- [x] Phase 5 (part 1) — browser panes via WebKitGTK: `cmux browser open
      <url>` splits a live web view into the workspace; navigate/back/
      forward/reload/url/title over the socket; page titles drive tab
      titles; URLs persist across restarts
- [x] Phase 5 (parts 2–3) — the full browser automation surface over the
      socket: eval/snapshot/wait, click/fill/type/select and friends,
      screenshot, ten find locators, iframe scoping, dialogs, cookies,
      local/session storage, console/errors capture, download wait — plus
      workspace rename/next/previous/last and notification v2 aliases
      (per-verb status: [`../docs/linux-port/PARITY.md`](../docs/linux-port/PARITY.md))
- [ ] Address-bar / browser chrome UI
- [ ] Flatpak packaging

## Daily use

```sh
cd linux && swift build
ln -sf "$PWD/.build/debug/cmux" ~/.local/bin/cmux         # the CLI
ln -sf "$PWD/.build/debug/cmux-adw" ~/.local/bin/cmux-adw # the app
./scripts/install-desktop-entry.sh                        # launcher + notifications
```

Launch the app from the GNOME app grid ("cmux"), with `cmux-adw &`, or via
the launcher script — `scripts/start.sh` (daily instance, refuses to
double-launch), `scripts/start.sh dev [--ghostty]` (isolated second
instance for testing: own socket/session/app-id), `scripts/start.sh
stop-dev` / `status`. The
symlinks survive rebuilds (`swift build` replaces the binaries in place).
Shells inside cmux get `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID`/
`CMUX_SOCKET_PATH`, so `cmux <command>` inside a pane targets that pane by
default; from outside, target explicitly (`--workspace workspace:2`,
`--surface surface:3`, or indexes).

## Trying the control plane

```sh
swift build
./.build/debug/cmux-adw &          # window opens; socket at $XDG_RUNTIME_DIR/cmux.sock
./.build/debug/cmux ping           # → PONG
./.build/debug/cmux new-workspace --cwd ~/src
./.build/debug/cmux notify --workspace workspace:2 --title "Agent done"
# → attention dot on that workspace in the sidebar
```

## Building

Requirements:

- Swift 6.x — Fedora: `sudo dnf install swift-lang`, or a
  [swift.org](https://swift.org/install/linux/) toolchain tarball in
  `~/.local/swift-toolchain` (the ubi9 build runs fine on Fedora)
- `gtk4-devel` and `libadwaita-devel` (≥ 1.5)

```sh
cd linux
swift build          # or: swift run cmux-adw
```

### Embedded Ghostty terminals (default in shim builds)

Shim-linked builds use **Ghostty terminal surfaces by default**
(`CMUX_TERM=vte` forces the VTE fallback; plain `swift build` produces a
VTE-only binary). Build the embedding shim from the ghostty submodule
(branch `linux-gtk-embed`, fork hiasihaho/ghostty), then link it:

```sh
cd ../ghostty && ~/.local/zig/zig-x86_64-linux-0.15.2/zig build lib-gtk \
    -Dapp-runtime=gtk -Dversion-string=1.3.0-dev
cd ../linux && CMUX_GHOSTTY=1 swift build     # links libghostty-gtk.so
./scripts/start.sh dev                        # ghostty terminals by default
./scripts/start.sh dev --vte                  # VTE fallback
```

Design, current C API, and remaining work:
[`../docs/linux-port/GHOSTTY-SHIM.md`](../docs/linux-port/GHOSTTY-SHIM.md).

### Dual-target builds: GNOME 49 and GNOME 50

The package builds against both SDK generations; only the adwaita-swift
dependency differs (pinned revision for 49, `main` for 50), selected via the
`CMUX_GNOME` env var at manifest-evaluation time:

```sh
swift build                              # GNOME 49 (GTK 4.20 / adw 1.8) — host default
CMUX_GNOME=50 swift build                # GNOME 50 (GTK 4.22 / adw 1.9) — needs GNOME 50 headers
./scripts/build-gnome50.sh               # GNOME 50 build inside a Fedora 44 podman container
```

The container build keeps its artifacts in `.build-gnome50/` so the two
variants never clobber each other. For an interactive GNOME 50 dev shell
(with GUI apps opening on the host desktop):

```sh
toolbox create --distro fedora --release 44 cmux-gnome50
toolbox enter cmux-gnome50
sudo dnf install swift-lang gtk4-devel libadwaita-devel   # passwordless inside toolbox
```

## Layout

```
Sources/CmuxAdw/
  CmuxApp.swift            — app entry, window scene, shortcuts, callbacks
  Views.swift              — sidebar (vertical tabs + attention dots), empty state
  Model.swift              — workspace/pane-tree/notification model (pure)
  TerminalSurfaces.swift   — GtkStack + GtkPaned skeletons, VTE factory,
                             SurfaceRegistry (strong-ref'd widget map)
  GhosttySurfaces.swift    — embedded Ghostty surface factory (CMUX_GHOSTTY builds)
  BrowserSurfaces.swift    — WebKitGTK browser factory + navigation verbs
  BrowserAutomation.swift  — async browser automation verbs (eval/find/dialog/…)
  ControlProtocol.swift    — v1/v2 socket protocol handlers
  ControlSocketServer.swift— AF_UNIX server (thread-per-connection → GTK main loop)
  SessionStore.swift       — session snapshot/restore (XDG)
  DesktopNotifier.swift    — GNotification delivery
  RefRegistry.swift        — workspace:/pane:/surface: handle refs
Sources/CVte/              — VTE-GTK4 C bindings (system library)
Sources/CWebKit/           — WebKitGTK 6.0 C bindings (system library)
Sources/CGhosttyEmbed/     — Ghostty embedding shim bindings (CMUX_GHOSTTY=1 only)
```

## Closed-loop dogfooding

`scripts/dogfood.sh "focus instructions" [timeout-min]` spawns a headless
Claude Code QA agent **inside** the running app (new workspace tab), lets it
exercise the port from within via the `cmux` CLI (tools restricted to
Bash/Read/Grep/Glob, guardrails against touching the human's panes), and
blocks until its markdown report lands in
`~/.local/share/cmux/dogfood/report-<stamp>.md`. Run it in the background
from an outer agent session and the report wakes the outer agent — a full
build → test-from-inside → report → fix loop. Note: the tester runs
unsupervised with pre-approved Bash; start it yourself (or give the outer
agent explicit permission) — it consumes Claude usage.

## Development workflow

- Work happens on the **`linux-port`** branch of the fork
  (`origin` = hiasihaho/cmux, `upstream` = manaflow-ai/cmux); local `main`
  stays a pristine pointer at upstream.
- One commit per phase/feature, **docs updated in the same commit**:
  `../docs/linux-port/PROGRESS.md` (what + verification evidence) and this
  README's status list; `PORTING.md` when the plan itself shifts.
- Conversation exports (`2026-*.txt`) are gitignored — never commit them.
- Changes to shared sources (`CLI/cmux.swift`) must keep building on macOS:
  Linux differences live behind `#if canImport(Darwin)` / `#if os(Linux)`.
- The `ghostty/` submodule points at the **hiasihaho/ghostty** fork on this
  branch (`.gitmodules` switched; no push access to manaflow-ai/ghostty).
  Shim work lives on its `linux-gtk-embed` branch — always push the
  submodule commit there **before** committing a parent pointer to it.
