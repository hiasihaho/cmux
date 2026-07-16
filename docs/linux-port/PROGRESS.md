# cmux Linux Port — Progress Log

Companion to [`PORTING.md`](PORTING.md) (the plan). This file records what has
actually been done, the decisions taken, and how each step was verified.
Newest entries last. Started 2026-07-16.

## 2026-07-16 — Bootstrap, analysis, Phase 0, Phase 1

### Toolchain bootstrap (Fedora 43 host)

- swiftly does **not** support Fedora ("Unsupported Linux platform").
- Interim: swift.org **ubi9 tarball** (Swift 6.2.4) extracted to
  `~/.local/swift-toolchain/` — runs and compiles fine on Fedora 43.
- Final: Fedora's `swift-lang 6.2-4.fc43` package installed (user-run
  `sudo dnf install swift-lang`); plain `swift build` now works. The tarball
  is redundant (≈5 GB, safe to delete).
- zig 0.15.2 tarball at `~/.local/zig/zig-x86_64-linux-0.15.2/` for
  libghostty (system zig 0.16.0 is too new for the ghostty fork's
  `minimum_zig_version = 0.15.2`).

### Codebase analysis

Full subsystem survey of the macOS app (48 files, ~74k lines Swift) — results
folded into the disposition table in `PORTING.md`. Headlines:

- Terminal rendering is entirely inside **libghostty** (cmux passes an
  `NSView*` and callbacks; Metal/IOSurface code on the cmux side is
  observation/debug only) → discarded on Linux, ghostty renders via GL.
- `TerminalWindowPortal`/`BrowserWindowPortal` (~2.9k lines) are AppKit
  compositing workarounds → not ported at all.
- Control socket protocol (v1 text + v2 JSON) and the CLI are
  Foundation/POSIX → ported nearly as-is (see Phase 1).
- Big rewrites ahead: Bonsplit (splits/tabs) and WKWebView browser panels.

### Phase 0 — walking skeleton ✅

`linux/` SwiftPM package, UI via **Adwaita for Swift**:

- `cmux-adw` binary: `AdwApplicationWindow` + `OverlaySplitView`, vertical-tab
  sidebar with attention dots (●), tab create/close/select, placeholder
  content page. Verified running on the host Wayland session.
- **adwaita-swift pinned to `664cadd`** (last GNOME 49-compatible commit).
  Its `main` targets the GNOME 50 SDK and uses e.g.
  `gtk_picture_set_isolate_contents` (GTK 4.22) → fails against Fedora 43's
  GTK 4.20 headers. Discovered via `git log -S`; pin documented in
  `linux/Package.swift`.

### Dual-target GNOME 49 + GNOME 50 ✅

- `CMUX_GNOME=50 swift build` switches the adwaita-swift dependency to
  `main` (env var read at manifest evaluation).
- `linux/scripts/build-gnome50.sh` builds in a **Fedora 44 podman container**
  (GTK 4.22.4 / libadwaita 1.9.2 verified), artifacts in `.build-gnome50/`
  (`--userns=keep-id`, SELinux `:Z` mount). Both variants verified:
  `Build complete!` on 49 (host) and 50 (container, adwaita-swift `main`
  d3dab6a).
- The 50-built binary happens to start on the 49 host (lazy PLT binding, no
  GNOME-50-only API used yet) — do not rely on this.

### Phase 1 — control plane ✅

**Server** (`linux/Sources/CmuxAdw/`):

- `ControlSocketServer.swift` — AF_UNIX server; socket at
  `$CMUX_SOCKET_PATH` → `$XDG_RUNTIME_DIR/cmux.sock` → `/tmp/cmux-$UID.sock`,
  mode 0600. Thread per connection; **multiple newline-delimited
  request/response rounds per connection** (the macOS server loops — the CLI
  reuses one connection for a whole command run; a close-after-one-reply
  server breaks `cmux notify`). `SIGPIPE` ignored (a hanging-up client must
  not kill the app). Commands are marshalled to the GTK main loop via GLib
  idle sources (`Idle` + semaphore) because Meta/Adwaita state is
  main-thread-only.
- `ControlProtocol.swift` — wire-compatible verb subset.
  v1: `ping, auth, list_workspaces, new_workspace, select_workspace,
  current_workspace, close_workspace, notify, notify_surface, notify_target,
  list_notifications, clear_notifications, help`.
  v2: `system.ping, system.capabilities, window.list, workspace.list/
  create/select/current/close, surface.list, notification.create/list/clear`.
  Response shapes copied from `Sources/TerminalController.swift` handlers.
- `RefRegistry.swift` — `workspace:<n>`-style handle refs (ordinal per kind,
  encounter order), like the macOS v2 ref registry.
- Each tab carries a placeholder `surfaceId` so the CLI's
  workspace→surface resolution works before real surfaces exist (Phase 2).

**CLI** (`CLI/cmux.swift`, shared source — Linux fixes behind `#if`):

- `import Darwin` → Glibc with a tiny `enum Darwin` shim for the four
  `Darwin.`-qualified syscalls (close/connect/read/write).
- `SOCK_STREAM` is `__socket_type` on Glibc → `Int32` shadow constant.
- `_NSGetExecutablePath` → `/proc/self/exe` readlink.
- New shared `cmuxDefaultSocketPath()` (XDG path on Linux).
- Built as target `CmuxCLI` via symlink `linux/Sources/CmuxCLI → ../../CLI`
  (SwiftPM follows it); binary named `cmux`.

**Verified end-to-end** (app running on Wayland, real CLI binary):

```text
$ cmux ping                          → PONG
$ cmux list-workspaces               → * workspace:1  Terminal 1  [selected]
$ cmux new-workspace --cwd ~/cmux    → OK workspace:2
$ cmux notify --title "Claude Code" --subtitle "Task done" \
      --body "Agent needs your review"          → OK
$ cmux select-workspace --workspace 0           → OK workspace:1
$ cmux notify --workspace workspace:2 --title "Second ping" --body "from CLI" → OK
$ cmux list-notifications
0:…|read|Claude Code|Task done|Agent needs your review
1:…|unread|Second ping||from CLI
```

Attention dot appears on the non-selected workspace's sidebar row; selecting
a workspace marks its notifications read and clears the dot (macOS
mark-read-on-focus semantics).

### Phase 2 groundwork — libghostty ✅ (build) / gap identified (embedding)

- `ghostty/` submodule (manaflow-ai/ghostty fork, 1.3.0-dev) checked out;
  requires zig 0.15.2 (fetched, see toolchain).
- `zig build -Dapp-runtime=none` **succeeds on Linux**: produces
  `zig-out/lib/libghostty.{a,so}`, `libghostty-vt.so` and
  `zig-out/include/ghostty.h`.
- **Gap:** the C embedder API in the produced `ghostty.h` only defines
  `GHOSTTY_PLATFORM_MACOS/IOS` (`ghostty_platform_u` = `{nsview}`/`{uiview}`)
  — there is no GTK/Linux platform variant. Ghostty's own Linux app links
  the Zig `apprt/gtk` code directly instead of using libghostty's C API.
  Embedding options, in preference order:
  1. **VTE stopgap** (`vte291-gtk4-devel`): a real terminal widget behind a
     `TerminalSurfaceWidget` abstraction — working shells, titles, bells in
     days, swappable later.
  2. **Zig C-shim around ghostty's GTK apprt**: export a small C API
     (`cmux_ghostty_surface_widget_new(...) -> GtkWidget*`) from a Zig
     module linking the fork's `apprt/gtk` internals — true Ghostty fidelity,
     medium effort, needs maintenance against the fork.
  3. **Track upstream libghostty**: upstream is factoring out embeddable
     pieces (`libghostty-vt` already ships — VT state machine without
     renderer); a cross-platform embedder API is the stated direction.

### Phase 2 (part 1) — real terminals via VTE ✅

Repo forked to https://github.com/hiasihaho/cmux (branch `linux-port`;
`upstream` remote = manaflow-ai). Then:

- `CVte` system-library target (`pkgConfig: vte-2.91-gtk4`) — GTK4 widget
  structs are opaque in GTK4 headers, so most gtk_* calls take
  `OpaquePointer`; only `VteTerminal*`/`GtkWidget*` are typed.
- `TerminalSurfaces.swift` — `TerminalStackWidget`, a custom `AdwaitaWidget`
  hosting a `GtkStack` with one VTE terminal (in a `GtkScrolledWindow`) per
  tab. Children are managed imperatively in `update()` and kept alive across
  tab switches (declarative diffing would respawn shells). `SurfaceRegistry`
  maps surfaceId → `VteTerminal*` for the control protocol.
- Shells spawn via `vte_terminal_spawn_async` with the cmux environment:
  `CMUX_WORKSPACE_ID`, `CMUX_SURFACE_ID`, `CMUX_SOCKET_PATH` — so `cmux`
  invoked *inside* a tab targets that tab, like on macOS.
- Signals: `window-title-changed` → tab title (bash's OSC title works out of
  the box: tabs show `user@host:dir`); `bell` → attention dot + notification.
- New protocol methods: v2 `surface.send_text` / `surface.read_text`
  (CLI `send` / `read-screen`), v1 `send`.

Verified end-to-end against the running app:

```text
$ cmux list-workspaces          → * workspace:1  hias@fedora:~  [selected]
$ cmux send 'echo linux-port-test-2\n'; cmux read-screen
  hias@fedora:~$ echo linux-port-test-2
  linux-port-test-2
$ cmux send 'printf "\\a"\n'; cmux list-notifications
  0:…|unread|Bell||Terminal bell in hias@fedora:~
$ cmux new-workspace --cwd /tmp; cmux send 'pwd\n'; cmux read-screen
  hias@fedora:/tmp$ pwd
  /tmp
```

Remaining for Phase 2: Ghostty fidelity behind the same
`SurfaceRegistry`/stack slot (Zig C-shim around the fork's GTK apprt or
upstream's embedder API), scrollbar polish, `send-key`, focus-follows-click
feedback into the model.

### Phase 3 (part 1) — desktop notifications + send-key ✅

- `DesktopNotifier.swift`: GNotification via `g_application_get_default()`
  (AdwaitaApp's GtkApplication pointer is module-internal). Delivered only
  when the target tab is not selected — approximates macOS
  suppress-when-focused. GNOME requires a matching `.desktop` file to display
  GNotifications → `linux/scripts/install-desktop-entry.sh` installs
  `com.manaflow.cmux.desktop` per user.
- v2 `surface.send_key` (CLI `send-key`): named keys → PTY bytes
  (enter/tab/esc/backspace/arrows/ctrl-<letter>/sigint/eof/sigtstp/sigquit —
  same names as macOS `sendNamedKey`). Verified: `send 'sleep 60\n'` +
  `send-key sigint` → `^C` on screen, sleep interrupted.

### Phase 4a — split panes ✅

- Model: `PaneNode` (leaf = `PaneLeaf` with paneId/surfaceId/cwd, split =
  orientation + two subtrees) with pure `splitting`/`removing` operations —
  the Linux counterpart of Bonsplit's tree (MVP: one surface per pane, no
  per-pane tab strips yet).
- Widget: each tab's GtkStack child is now a nested-`GtkPaned` skeleton with
  the live VTE containers as leaves. On layout change the skeleton is
  rebuilt; terminals are **reparented, never recreated** (shells survive).
  Split-off shells inherit the source shell's OSC-7 cwd.
- Focus: a `GtkEventControllerFocus` per terminal feeds clicks back into the
  model (`focusedSurfaceId`); the focused surface drives the tab title and is
  the default target for send/read/notify.
- Protocol: v2 `surface.split`, `surface.close`, `pane.list`, `pane.focus`
  (+ v1 `new_split`); `v2RefreshKnownRefs` equivalent so handle refs resolve
  before their first listing (matches macOS). Header-bar split buttons.
- Verified: 3-way split with all shells alive and individually addressable
  (`send --surface surface:N` / `read-screen --surface surface:N`),
  cross-workspace splits, `close-surface` collapsing the tree, 12-round
  focus/send stress — zero Gtk/VTE criticals.

**Reparenting lessons (cost a segfault):**
1. `GtkPaned` silently refuses a child that still has a parent
   (Gtk-CRITICAL) — the child then dies with the old skeleton and any
   pointer map (SurfaceRegistry) dangles → use-after-free in later
   `vte_terminal_*` calls. Always detach containers from their old parents
   (paned: `set_start/end_child(NULL)`; stack: `gtk_stack_remove`) before
   assembling the new tree, holding a `g_object_ref_sink` across the move.
2. A single-leaf tab's stack child IS the terminal container — after
   detaching, there is no separate skeleton left to remove.

### Phase 4a polish + Phase 4b — session persistence ✅

Split polish:
- Divider positions survive skeleton rebuilds (captured/restored keyed by
  tree path).
- Header close button now closes the **focused pane** (last pane closes the
  workspace) — shared logic with v2 `surface.close`.
- Keyboard shortcuts: Ctrl+Shift+T (new tab), Ctrl+Shift+D (split right),
  Ctrl+Shift+S (split down), Ctrl+Shift+W (close pane). Note:
  `.keyboardShortcut()` is Button-specific — apply it *before* AnyView
  modifiers like `.tooltip()`.
- Deferred: pane zoom/equalize, directional focus navigation, resize-pane,
  visible focus ring, per-pane tab strips (full Bonsplit parity).

Session persistence (`SessionStore.swift`):
- Versioned JSON at `$XDG_DATA_HOME/cmux/session-linux.json` (atomic,
  deduped writes): workspaces, pane trees, focused leaf, selection,
  tab counter. Leaf cwds are captured **live** via OSC 7 at save time.
- Saves on every structural change (scene body) + every 15 s (GLib timeout)
  to pick up shell cwd drift; restore happens in `CmuxApp.init` by writing
  `State.rawValue` (no premature view updates).
- Verified: 2 workspaces with a 3-pane split, `cd /tmp` in the focused
  pane → kill → relaunch → layout, selection, focus and the `/tmp` cwd all
  restored.

## Known gotchas (for future sessions)

- Filter `swift build` output: pkg-config emits huge
  `circular dependency freetype2↔harfbuzz` / `prohibited flag` warning spam
  on Fedora; it is harmless.
- Don't `pkill -f cmux-adw` from a script whose own command line contains the
  pattern; use `pkill -x cmux-adw`.
- `Package.resolved` is gitignored in `linux/` — it flips between the two
  GNOME pins.
- The root `Package.swift` (SwiftTerm stub) is the legacy macOS manifest; the
  real macOS build is `GhosttyTabs.xcodeproj`. Don't try to `swift build` the
  repo root.
