# cmux for Linux (GTK4 / libadwaita port)

Work-in-progress port of cmux from Swift + AppKit/SwiftUI to Swift +
[Adwaita for Swift](https://git.aparoksha.dev/aparoksha/adwaita-swift)
(libadwaita/GTK4). The Swift language stays; the Apple UI frameworks go.

See [`../docs/linux-port/PORTING.md`](../docs/linux-port/PORTING.md) for the
full analysis and phased plan.

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
- [ ] Phase 2 (part 2) — Ghostty fidelity behind the same surface slot
      (libghostty builds on Linux — see `../docs/linux-port/PROGRESS.md`)
- [x] Phase 3 (part 1) — XDG desktop notifications for background tabs
      (GNotification; run `scripts/install-desktop-entry.sh` once so GNOME
      displays them) and `send-key` (enter/ctrl-c/arrows/…)
- [ ] Phase 3 (part 2) — notifications page UI, unread badge polish
- [x] Phase 4a — split panes: nested GtkPaned tree per workspace, one live
      shell per pane (reparented across layout changes, never respawned),
      focus-follows-click, cwd inheritance; `new-split`/`list-panes`/
      `focus-pane`/`close-surface` + header-bar split buttons
- [x] Phase 4b — session persistence: workspaces/pane trees/live cwds to
      `$XDG_DATA_HOME/cmux/session-linux.json`, restored on launch; divider
      positions survive layout changes; Ctrl+Shift+T/D/S/W shortcuts
- [ ] Phase 5 — browser panel via WebKitGTK (`webkitgtk-6.0`)

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
  CmuxApp.swift   — app entry, window scene, tab actions
  Views.swift     — sidebar (vertical tabs + attention dots), content area
  Model.swift     — portable tab/workspace model
```
