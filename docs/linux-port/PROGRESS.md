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

### Phase 3b — notifications page UI ✅

- Sidebar toggles between the workspace list and a notifications page
  (bell button in the sidebar header; window title shows unread count).
- Rows render `● title: subtitle — body` (dot = unread, newest first);
  clicking a row jumps to the workspace, focuses the exact surface when it
  still exists, marks read (select-marks-read semantics), and flips back to
  the workspace list. "Clear all" wipes entries + attention dots.
- Minor quirk to watch: a restored shell emitted one phantom bell right
  after session restore (single occurrence; likely prompt/startup output
  containing BEL).

### Phase 5 (part 1) — WebKitGTK browser panels ✅

- `CWebKit` system-library target (`webkitgtk-6.0`); `PaneLeaf` gained a
  `kind` (terminal | browser(initialURL)). Browser surfaces are plain
  `WebKitWebView` widgets in the same pane tree/registry — the registry
  stores containers as `OpaquePointer` so CVte- and CWebKit-bound files
  never mix typed GTK imports.
- Page titles flow through `notify::title` into the tab title; focus
  controller same as terminals. Session persistence stores the **live page
  URL** (schema v2 — v1 files are discarded once).
- Protocol: `browser.open_split` (splits right of the target surface),
  `browser.navigate`, `browser.url.get`, `browser.get.title`,
  `browser.back/forward/reload`. Note the CLI's verb names are irregular:
  `url` → `browser.url.get` but `back` → `browser.back` (template).
- Verified: `browser open https://example.org` → rendered page, tab title
  "Example Domain", `url`/`goto`/`back` round-trips, browser pane +
  URL restored across an app restart. Zero criticals.
- Remaining for later: the big `browser.*` automation surface (eval,
  snapshot, click/type/find — needs async JS eval plumbing), address-bar UI,
  downloads, cookies.

### Dogfooding fixes (reported by a Claude session running inside the port)

- `pane.surfaces` implemented (CLI `list-pane-surfaces` — was unknown_method).
- Closing a surface drops its notifications (whole workspace's on last
  pane) — the list no longer points at dead surface ids.
- Bell policy: 2 s post-spawn grace (fastfetch-style startup banners emit
  BEL — this was also the "phantom bell on restore") and 1 s burst
  coalescing (dot refresh, no duplicate entries). Mirrors macOS's
  notification-burst coalescing.
- Dev-instance support: `CMUX_APP_ID` + `CMUX_SESSION_PATH` env overrides
  (with the existing `CMUX_SOCKET_PATH`) let a second instance run beside
  the daily one — used to verify these fixes without killing the primary
  instance (which was hosting a live Claude session).
- `read-screen` truncating wide startup banners = VTE line wrapping at the
  pane's actual width; expected, not a bug.
- **Shared-CLI fix (upstreamable):** `browser <subcommand>` parsing consumed
  any first word as the optional positional surface handle, so
  `browser url` failed with "requires a subcommand". Now only
  UUID/ref/index-shaped args are treated as handles, and when no handle is
  given the CLI falls back to the workspace's **only** browser surface
  (clear errors for none/multiple). `cmux browser url` from a terminal pane
  next to one browser pane now just works.

### Closed-loop dogfooding: cycle 1 → fixes

First automated cycle (`scripts/dogfood.sh`, headless Claude QA agent inside
the app — user-approved) verified all of the day's fixes and found one real
bug + gaps; fixed same-day:

- **Stale tab title after closing/refocusing surfaces**: the title now
  refreshes from the newly-focused surface's live state (VTE window title /
  WebKit page title) on `surface.close`, `pane.focus`, and focus clicks.
- `surface.read_text` honors `lines` (last N; scrollback capture still todo).
- Minimal `system.identify` (platform/port + caller ids/refs) so agents can
  feature-detect and locate themselves.
- `workspace.create` honors `focus: false`; the dogfood wrapper uses it (raw
  v2 JSON via python) so spawning a tester never steals the human's view,
  and shows a banner instead of a blank cleared pane.
- Not-a-bug from the report: `--id-format` must precede the subcommand
  (global-flag parsing, same on macOS); headless `claude -p` is silent by
  design — hence the banner.

### Dogfood cycle 2 → fixes

Cycle 2 confirmed all cycle-1 fixes and exposed a root-cause chain: my
`system.identify` ignored the CLI's nested `params["caller"]` and returned
the *selected* workspace — the tester mis-identified itself all run, which
manufactured two phantom bugs (browser split "in the wrong workspace",
"inconsistent UUIDs"). Real fixes:

- `system.identify` resolves `params["caller"]` (falls back to selected)
  and echoes a `caller` block.
- **Background terminals work**: default 80×24 PTY size before mapping
  (spawned-in-background shells stalled on a ~0×0 pty), and
  `surface.read_text` reads the screenful **ending at the cursor**
  (`vte_terminal_get_text_range_format`) instead of the viewport — an
  unmapped terminal never scrolls its viewport, so reads returned a stale
  first screenful forever.
- Selection history (`SelectionHistory`): closing the selected workspace
  returns to the previously-selected one, not an arbitrary neighbor.
- CLI `new-workspace --background` → `focus:false` (agents don't steal the
  human's view); dogfood prompt now teaches flag ordering and env-identity
  so testers don't chase phantoms.
- Deferred (documented): `--id-format`/global flags must precede the
  subcommand (upstream CLI ergonomics), help doesn't mark Linux-unimplemented
  verbs, merging repeat bell entries per surface.

### Dogfood cycle 3 → fixes

Cycle 3 (with the taught tester: flag order, env identity, `--background`)
confirmed the cycle-2 fixes and left three real items, all fixed:

- **Workspace close now drops the workspace's notifications** (cleanup had
  only been wired into the surface-close path) — central `removeWorkspace`.
- **Selection-steal race fixed**: the sidebar GtkListBox emits
  `selected_rows_changed` echoes while its rows are diffed after
  socket-driven tab mutations; a `SocketDispatchGuard` marks socket dispatch
  windows and the selection binding ignores row echoes during them (they are
  never user clicks — both run serialized on the main loop).
- **`pane.create`/`surface.create` implemented** (CLI `new-pane`/
  `new-surface`) — with one surface per pane, both are "split with a typed
  surface"; enables browser panes in background workspaces. `browser.identify`
  returns a payload (CLI prints bare OK without `--json` by design).
- Explained, not bugs: `identify --workspace X` reports X as caller because
  the CLI *replaces* the caller env with the flag (macOS-identical);
  the "swallowed bell" was the 2s post-spawn grace on a young scratch
  workspace.

## 2026-07-16 — Phase 5b: browser automation verbs + async socket dispatch

The socket dispatcher went completion-based so verbs can reply from async
GLib callbacks: `ControlSocketServer.dispatcher` is now
`(String, @escaping (String) -> Void) -> Void`, the per-connection socket
thread parks on a poisoned-after-timeout `OneShotResponse`, and the GTK
main loop is never blocked (macOS pumps a nested RunLoop instead — we
verified pings answer in ~110ms while a 3s `browser.eval` promise runs).
v2 transport timeouts now return a JSON error envelope instead of a bare
`ERROR:` line.

On top of that, `BrowserAutomation.swift` ports the macOS automation
surface over `webkit_web_view_call_async_javascript_function` (the GTK
analog of `callAsyncJavaScript`: implicit async function, promises
awaited) + `jsc_value_to_json`: eval, snapshot (role/name tree with `@eN`
refs), wait (50ms GLib-timeout polling), click/dblclick/hover/focus,
fill/type/press/keydown/keyup, check/uncheck/select, scroll/
scroll_into_view, get.text/html/value/attr/count/box/styles,
is.visible/enabled/checked — with the macOS retry loop (3×80ms),
element-not-found diagnostics script, and `snapshot_after` merging.
`system.capabilities` finally reports the real method list. Feature
tracking moved to [PARITY.md](PARITY.md).

Dev-instance verification found (and the human independently reported)
that **fresh splits collapsed browser panes to ~1px**: GtkPaned derives
its initial position from the children's natural widths and WebKitWebView
requests ~0. Fixed in `TerminalStackWidget`: panes whose tree path has no
preserved divider position get a one-shot tick callback that sets the
divider to 50% at first allocation; dragged/rebuilt positions are
untouched. Side effect: session-restored layouts open balanced (divider
positions aren't persisted yet — schema v3 candidate).

Verified end-to-end on the isolated dev instance via the shared CLI
against a local fixture page: eval value types (number/string/object/
promise/undefined sentinel/JS exception→js_error), snapshot refs,
click-by-ref mutating the DOM, fill/check/select reflected in page state,
wait resolving in ~1.5s for a delayed element, wait timeout, not-found
diagnostics, and main-loop responsiveness under a slow eval. A focused
dogfood cycle ran against the dev instance socket (CMUX_SOCKET_PATH is
honored by dogfood.sh).

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
- Swift closures passed as C function pointers (GAsyncReadyCallback,
  GSourceFunc, GtkTickCallback) may not capture ANYTHING — including local
  types and unqualified static members of the enclosing type. Put the box
  classes and the completion logic in file-scope declarations and pass state
  through `user_data` via `Unmanaged`.
- `browser.eval window.innerWidth` right after creating a pane can race the
  first frame tick (the 50/50 divider balancing runs at first allocation) —
  a 1px reading milliseconds after `new-pane` is not the collapse bug.
- When talking to ANOTHER instance's socket (e.g. the dev instance), unset
  `CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID` or pass explicit `--workspace`:
  the CLI injects your caller identity as the default target and those
  UUIDs don't exist over there ("Workspace not found").
