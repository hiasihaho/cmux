# cmux Linux Port — Progress Log

Companion to [`PORTING.md`](PORTING.md) (the plan). This file records what has
actually been done, the decisions taken, and how each step was verified.
Newest entries last. Started 2026-07-16.

This log is chronological evidence — the right shape for "what happened
on the 21st?". For "we're about to do X, what do we already know?", read
[`LESSONS.md`](LESSONS.md), which distills the transferable lessons and
points back here for the evidence.

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

### Dogfood cycle 4 (browser automation) → fixes

A focused cycle against the dev instance (`CMUX_SOCKET_PATH` is honored by
dogfood.sh) validated the whole automation surface and returned six real
findings. Raw-wire probes root-caused two of them to the shared CLI, not
the app — the wire had `"value":0` and the correct workspace all along:

- **CLI `displayBrowserValue` corrupted `eval` results 0/1 into
  false/true**: the bool-first `as? Bool` cast succeeds for the NSNumbers
  0/1 on Linux corelibs Foundation. Numbers now render via a JSON
  fragment round-trip, which keeps booleans and numbers apart on both
  platforms.
- **CLI `browser identify`** sent `system.identify` without caller
  context (top-level refs described the *selected* workspace — the same
  class of bug as cycle 2's identify saga) and printed a bare `OK` in
  plain mode. It now passes `$CMUX_WORKSPACE_ID`/`$CMUX_SURFACE_ID` as
  caller and renders surface/url/title lines.
- **`select` with a non-matching value silently cleared the selection and
  reported OK** — now validated against `el.options` first;
  `invalid_params: No <option> matches the given value`, selection
  untouched. (macOS inherits this bug; deviation noted in PARITY.md.)
- **`dblclick` never fired `click` events** so onclick handlers didn't
  run — now click, click, dblclick per spec. (Deviation; macOS only
  dispatches dblclick.)
- **`press` with a printable key was a silent no-op on inputs** —
  synthetic KeyboardEvents are untrusted so the default text-insertion
  action never runs; single printable chars now insert at the selection
  (setRangeText) + input event. (Deviation; macOS dispatches events only.)
- **Snapshot accessible names ignored `<label for=…>`** — checkboxes were
  all named "on". `__nameFor` now checks label[for] and wrapping labels
  after aria-*. (Deviation; macOS misses labels too.)

Known limitation (documented, not fixed): browser panes in never-selected
background workspaces run at a 0×0 viewport — GtkStack doesn't allocate
unmapped children. Event-driven verbs (click/fill/eval) work fine;
layout-dependent reads (snapshot visibility, get.box) see degenerate
geometry until the workspace is first shown.

## 2026-07-16 — Phase 5c: screenshot, find locators, frames, dialogs, cookies

Closes the main browser-automation parity gaps flagged in PARITY.md after
5b. All five verb groups reuse the phase-5b async completion pattern
(respond fires from GLib callbacks, main loop never blocks):

- **browser.screenshot** — `webkit_web_view_get_snapshot` (visible region)
  → `GdkTexture` → `gdk_texture_save_to_png_bytes` → `g_base64_encode`,
  carried through a file-scope `SnapshotCallbackBox` (the C-callback
  no-capture rule again). The shared CLI's `--out` path writes a valid PNG.
- **browser.find.*** — all ten locators (role/text/label/placeholder/alt/
  title/testid/first/last/nth), finder scripts copied verbatim from the
  macOS `v2BrowserFind*` handlers; found elements get `@eN` refs via the
  same cssPath machinery as snapshot. find.first keeps the caller's
  selector, last/nth append `:nth-of-type` (macOS quirks preserved).
- **browser.frame.select / main** — `BrowserJS.run` grew the macOS frame
  prelude: a per-surface selector (`BrowserFrameSelectors`) resolves the
  same-origin iframe and shadows `document` inside the eval envelope, so
  *every* automation verb (eval/click/find/snapshot/…) is frame-aware.
  Cross-origin iframes → `not_supported`, like macOS.
- **browser.dialog.accept / dismiss** — the macOS JS-hook design:
  window.alert/confirm/prompt are overridden into `__cmuxDialogQueue`
  (FIFO) + `__cmuxDialogDefaults`, armed lazily by the first dialog verb
  (which returns `not_found` on an empty queue — that call is the arming
  step). Deviation noted in PARITY: pre-arm native dialogs are WebKitGTK's
  own, not deferred like macOS's WKUIDelegate queue.
- **browser.cookies.get / set / clear** — WebKitNetworkSession cookie
  manager. get_all_cookies transfers ownership of the GList *and* the
  SoupCookies (free both); add/delete are async per cookie, so a
  file-scope `CookieChainBox` chains them sequentially and frees the
  cookies when the chain ends. Wire shape matches the macOS HTTPCookie
  dict (session_only == no expiry; expires as Unix seconds).

Verified end-to-end against the dev instance on a local HTTP test page
(cookies need an http origin — data: URLs won't exercise them): all ten
locators return working selectors/refs, clicking a returned `@ref`
mutates the page, frame-scoped eval/click/find round-trip through
`frame #inner` → `frame main`, dialog FIFO + defaults behave exactly like
macOS (accept consumes the *oldest* entry; a prompt default only applies
once a prompt entry is consumed), cookie set/get/clear round-trips
including `document.cookie` visibility and expires, and the screenshot is
a pixel-faithful capture of the mutated page.

**Dogfood cycle 5** (focused on these verbs) passed everything except two
real bugs, both fixed and re-verified:

- **browser.screenshot on background-workspace surfaces** failed with a
  raw localized WebKit GError — unmapped GtkStack children can't be
  snapshotted. Now guarded with `gtk_widget_get_mapped` and a stable
  `invalid_state` message ("select its workspace once to enable
  screenshots"). Testing gotcha found while reproducing: `new-workspace
  --background` prints plain `OK workspace:N` even under `--json`, so
  scripts that grep JSON out of it get an empty ref and silently target
  the *selected* workspace — the first repro attempt tested nothing.
- **CLI `find role <role> <name>`** silently dropped a positional name
  and matched the first element of that role (shared-CLI bug, macOS
  inherits the fix): positional name is now honored Playwright-style
  (`--name` still takes precedence); the `browser find` help lines now
  spell out all locator forms.

A code-review pass over the diff (8 finder angles) surfaced four more
fixes, applied in the same commit:

- **frame.select validation now runs top-relative** (deviation from
  macOS, which validates inside the currently selected frame): the
  run-time prelude resolves stored selectors against the top document,
  so validating in the old frame rejected valid sibling-iframe switches
  (`frame '#a'` → `frame '#b'` failed with "Frame not found").
- **find.last/nth return the element's own CSS path** instead of the
  macOS `<query>:nth-of-type(n)` composite — :nth-of-type counts
  per-parent/per-tag, so for matches spread across parents the macOS
  selector points at a *different* element than the one matched (or
  none). Verified with a three-parent fixture.
- **Closed surfaces now clear their automation registries**
  (`BrowserElementRefs` + `BrowserFrameSelectors`) in
  `SurfaceRegistry.unregister` — previously refs accumulated for the
  process lifetime.
- Dialog verbs collapsed to a single JS round-trip; cookie helpers
  deduplicated (single `soup_cookie_get_expires` bind, `intParam` for
  expires parsing).

Rejected review candidates worth remembering: the always-on
`const document = __cmuxDoc` shadowing, the silent top-document fallback
when a selected frame disappears/turns cross-origin, substring domain
matching in cookies.get/clear, and the `all`-key quirk in cookies.clear
are all **verbatim macOS envelope/handler semantics** — kept for parity,
not bugs to fix unilaterally.

## 2026-07-16 — Parity sweep: storage, console/errors, download.wait, workspace verbs, notification aliases

Small-verb sweep that finishes the agent-facing automation surface, all on
the established patterns (async browser verbs, sync workspace verbs):

- **browser.storage.get/set/clear** — local/session via the frame-aware
  runner; get without a key returns the whole map (macOS scripts).
- **browser.console.list/clear + browser.errors.list** — the macOS
  telemetry hook script (console.* wrap + error/unhandledrejection ring
  buffers) ported like the dialog hooks: idempotent install prepended to
  the read script, one JS round-trip, armed lazily by the first call.
- **browser.download.wait** — path branch polls the filesystem off the
  main loop (g_timeout, 50ms). The no-path event branch times out by
  design: macOS's `v2BrowserDownloadEventsBySurface` has no writer
  anywhere, so its event branch *also* always times out. Real WebKitGTK
  downloads need a decide-destination handler — future work, noted in
  PARITY.
- **workspace.rename/next/previous/last** — rename pins a `customTitle`
  on the tab (new model field, persisted in the session snapshot as an
  optional so v2 files keep decoding): OSC title updates stop overwriting
  it, verified across a dev-instance restart. next/previous wrap;
  last reuses `SelectionHistory` (all selection paths already funnel
  through `select()`, including sidebar clicks). Focus-intent verbs per
  the socket focus policy.
- **notification.create_for_surface/create_for_target** — v2 aliases with
  macOS param/result shapes; for_surface defaults to the selected
  workspace, for_target requires workspace_id; both validate the surface
  belongs to the workspace.

Everything verified against the dev instance (storage isolation between
local/session, console capture-after-arming, error events, download file
appearing mid-wait, wrap-around stepping, last-toggling, rename pin
surviving restart + fresh OSC titles, both notification aliases over the
raw wire). INSIDE-CMUX.md's milestone line updated — the automation
surface is done; next up is the Ghostty Zig C-shim, then Flatpak.

## 2026-07-16 — Ghostty embedding shim: scouting + increment 1 (live surface)

Started the Ghostty-fidelity milestone. Full design in
[GHOSTTY-SHIM.md](GHOSTTY-SHIM.md) (written from three deep source sweeps
over the fork at `80d3fa0`); the shim itself lives on ghostty branch
**`linux-gtk-embed`** (local commit `eb3fac7`, unpushed — see below).

Increment 1 works end-to-end: `zig build lib-gtk -Dapp-runtime=gtk
-Dversion-string=1.3.0-dev` produces `libghostty-gtk.so` +
`ghostty_gtk_embed.h`, and the C harness
(`linux/tests/ghostty-embed-smoke.c`) hosts a **live Ghostty terminal
surface inside a plain foreign GtkApplication**: shell spawns, GL
renders, and the OSC title flows core → performAction → GObject `title`
property → host `notify::title` handler (`smoke: title changed:
hias@fedora:~`). No crash over the test window's lifetime.

What the fork changes are (all embed-gated, standalone Ghostty
unchanged): `.lib` artifact + `-Dapp-runtime=gtk` now selects the GTK
apprt; lib builds get the GTK/glad/gresource deps; `Application.default()`
resolves through an embed global (the process-default GApplication is the
host's); `wakeup()` pumps `core_app.tick` via coalesced idle sources
(`run()` never executes in embed mode); `setGtkEnv` skipped (host already
initialized GTK — its assertion trips otherwise, found by the first smoke
run).

Human-verified: typing, command execution, and rendering all work in the
smoke harness (`echo` round-trip on screen). Also observed: the embedded
shell inherits the host process's cwd — per-surface working-directory
plumbing is required for cmux integration.

Known issues for increment 2: a non-fatal GLib CRITICAL
(`g_application_get_dbus_connection` on the unregistered Application —
find and gate the call site); `startup()` never runs so its CSS-provider
attach is missing (overlay styling may look off); per-surface
working-directory/command plumbing (likely via a cloned per-surface
`config` GObject property).

**Blocked on repo topology**: hiasihaho has no push access to
manaflow-ai/ghostty, so `linux-gtk-embed` is local-only and the parent
submodule pointer stays at `80d3fa0` for now. (That base commit is itself
unreachable from any remote branch — a pre-existing orphan risk from the
macOS side; pushing our branch anywhere rescues it.) Options: a
hiasihaho/ghostty fork + .gitmodules URL switch on the linux-port branch,
or manaflow grants access / pulls the branch.

## 2026-07-17 — Ghostty shim increment 2: surfaces live inside cmux-adw

Ghostty terminals now run inside cmux-adw behind a double opt-in:
build with `CMUX_GHOSTTY=1 swift build` (links the shim; the
`CGhosttyEmbed` module only exists then, so `#if canImport` keeps
default builds VTE-only) and launch with `CMUX_TERM=ghostty`.

- Shim v2 (`ghostty` branch `linux-gtk-embed`, `1131dbb`): per-surface
  working directory + env vars via a cloned per-surface config —
  smoke-verified (`title changed: hias@fedora:/tmp`), and the human
  verified typing/rendering in the increment-1 harness.
- cmux side: `GhosttySurfaceFactory` mirrors the VTE factory (same
  CMUX_* identity env, cwd, scrolled-window container, registry entry);
  titles arrive via `notify::title`, bell via `notify::bell-ringing`
  rising edge, focus via an EventControllerFocus. `SurfaceRegistry` grew
  a third surface kind; title/cwd queries dispatch to GObject
  properties (`title`, `pwd`) for ghostty surfaces.
- Verified on the dev instance: OSC titles flow into the tab model
  (visible and background→selected workspaces, incl. cwd `/tmp`
  round-trip), session restore, splits (two ghostty panes), no crashes.

Known limitations (increment 3 backlog):
- `surface.send_text/send_key/read_text` are VTE-typed — ghostty panes
  need shim exports (`core_surface.textCallback`/`dumpTextLocked`; the
  embedded apprt shows the pattern). Until then the closed loop
  (agents driving panes) only works in VTE mode.
- Shells in never-shown background workspaces don't spawn until the
  workspace is first selected (unmapped GLArea → no core surface); VTE
  pre-sizes 80×24 and spawns immediately. Needs a realize-offscreen
  strategy or eager PTY sizing.
- `no resources dir set, shell integration disabled` — ghostty's shell
  integration scripts aren't found; consider exporting
  GHOSTTY_RESOURCES_DIR from the zig-out share dir.
- One unexplained one-off: in the first dev run, a background-created
  workspace's title never propagated (shell spawned fine); did not
  reproduce after rebuild. Watch during dogfood.
- The GLib CRITICAL (`g_application_get_dbus_connection` on the
  unregistered app) appears at surface spawn (systemd scope
  transition, gtk_post_fork) — harmless but should be gated.

## 2026-07-17 — SurfaceRegistry strong refs (daily-instance SIGSEGV)

The user's daily instance segfaulted at 00:06 inside
`vte_terminal_get_current_directory_uri` ← `g_type_check_instance_is_a`
(coredump pid 1207432): the 15-second session-autosave timer queried the
OSC 7 cwd through `SurfaceRegistry`, which held RAW widget pointers — a
destroyed VteTerminal left a dangling pointer and the type check faulted.
Forensics gotchas from the triage: the frame symbols in `coredumpctl
info` were garbage because the on-disk binary had been rebuilt since the
process started (only shared-lib frames were trustworthy), and grepping
the core for env vars matches *terminal scrollback* text too — anchor
exact `KEY=value` strings to tell the env block from displayed text.

Fix: the registry now takes a GObject strong ref on every registered
widget/container (terminal, browser, ghostty) and releases it in
`unregister`. A disposed-but-referenced widget degrades getters to nil
instead of crashing; refs on floating widgets don't sink them, so
container ownership is unchanged. Verified with workspace churn spanning
multiple autosave ticks in both VTE and ghostty modes.

## 2026-07-17 — Ghostty shim increment 3 + dogfood cycle 6 (first in ghostty mode)

Agents can drive ghostty panes: `surface.send_text/send_key/read_text`
dispatch by surface kind. The shim exports raw PTY writes (via the
now-pub `Surface.queueIo`, readonly guard intact — NOT paste semantics)
and screen-text reads (`dumpTextLocked` over an untracked selection:
active screenful, or the whole buffer for `--scrollback` — richer than
the VTE path). send_key reuses the VTE escape-sequence table through the
shared `sendBytes` path. Polish shipped alongside: `start.sh` dev2 slot
(the dev slot hosts the live self-hosted session now) and
GHOSTTY_RESOURCES_DIR export, resources installed by `zig build lib-gtk`
→ shell integration auto-injects; post_fork checks `getIsRegistered`
before asking for a dbus connection (the per-spawn GLib CRITICAL is
gone). The CSS worry from the design doc was moot — the provider
attaches in `Application.new`, not `startup()`.

**Dogfood cycle 6** (first on embedded Ghostty, against dev2): all seven
focus areas pass — verb round-trips, scrollback/lines variants,
background-workspace error + select-once recovery, churn stability (no
crash), OSC title tracking, bell → notification with correct refs, shell
integration env. Findings, all fixed same-day:

- `send` to an exited-shell pane silently returned OK → now errors
  `unavailable: Surface shell has exited` (Swift reads the Surface's
  `child-exited` GObject property; no shim change needed).
- The `unavailable` hint said "select its workspace once", which misled
  for splits added to a non-selected workspace (they need a RE-select) →
  reworded to "select its workspace to start it". True eager spawn stays
  on the increment-4 list.
- Unknown v1 verbs returned bare `ERROR: Unknown command` while v2 had
  the friendly not-implemented message → aligned.
- `workspace.list` rows now carry `needs_attention` (Linux extension) so
  agents can poll attention without a second call.

Increment 4 backlog: eager background spawn (unmapped GLArea — includes
the split-in-nonselected-workspace case), child-exited → auto-close pane
(the `close_surface` action hook; `child-exited` property notify is the
easy Swift-side trigger), the unreproduced title flake, then the default
flip to ghostty.

## 2026-07-17 — Ghostty increment 4 (part 1): window autoresize + auto-close

Two user-facing fixes, verified on dev2:

- **Panes now track the host window size.** The factory hosted surfaces
  in a plain `GtkScrolledWindow` (automatic policies) — a GtkScrollable
  child keeps its natural size there, so ghostty panes never resized
  with the window (split reallocation worked; window growth/shrink
  didn't). Fix: new shim export `ghostty_embed_surface_container_new`
  wraps the surface in Ghostty's own `SurfaceScrolledWindow`
  (hscrollbar never, vscrollbar bound to the user's `scrollbar` config).
- **Clean shell exits close the pane** via the Surface's `close-request`
  signal (designed exactly for embedding containers): same code path as
  the close-pane shortcut, last pane closes its workspace. Abnormal
  exits keep ghostty's overlay and don't auto-close. VTE panes keep
  their lingering behavior (no clean/abnormal distinction available
  without C varargs marshalling).

**Eager background spawn — assessed, deliberately deferred.** The two
viable designs are (a) fork-side: decouple `initSurface`/CoreSurface
creation from GLArea realization so the PTY spawns at 80×24 pre-map like
VTE — renderer-init surgery (OpenGL prepareContext runs off the realized
context); or (b) host-side: replace the workspace GtkStack with an
always-mapped container (GtkOverlay + opacity/can-target) so GLAreas
realize immediately — GPU/occlusion cost for every hidden workspace.
Both are half-day+ with real risk; the agent-facing gap is already
covered (clear `unavailable` error, select-once recovery, dogfood.sh
auto-select). Revisit before the default flip.

## 2026-07-17 — OPEN BUG: ghostty pane freezes after window resize

Reproduced with the user driving resizes while a monitor watched (dev2,
ghostty mode): after interactively resizing the window, the resized
pane's GLArea stops presenting frames — it keeps compositing its last
texture, so the pane LOOKS dead (typing shows nothing) and further
resizes don't repaint it. Fresh panes work until their first resize.

Forensics (all on the live wedged instance):
- Core is fully healthy: socket `send` reaches the shell (a keystroke
  typed at the GTK layer even reached the PTY — the pane is
  display-frozen, not input-dead), `read_text` returns instantly (no
  renderer-mutex deadlock), io thread processed 263 resize messages, the
  grid/PTY size is CORRECT for the final window size, CPU idle, all
  threads sleeping normally, no GL errors, no unrealize, no warnings.
- The embed tick is NOT the cause: `App.Mailbox.push` calls
  `rt_app.wakeup()` (App.zig:581) so redraw pushes do wake us; gdb on
  the wedged process shows `embed_tick_pending=false` (nothing starved),
  and post-wedge socket probes were fully processed (title changes in
  the log) — ticks run.
- Occlusion/visibility is not the mechanism (no `.visible` renderer
  messages at all in the run); focus events flow normally.
- Renderer `redraw_surface` pushes are unlogged (App.zig:243 filters
  them) — next session: instrument `glareaRender`/`Surface.redraw`/
  `redrawSurface` in the fork, reproduce, and trace where the chain
  renderer→app-tick→queueRender→GLArea::render breaks after a resize.

Further findings: the freeze survives a full unmap/remap cycle
(workspace switch away and back does NOT recover the pane) — remap
forces GLArea::render → drawFrame(true) synchronously, so a stale
result there means the RENDERER THREAD's prepared frame state stopped
updating, not just a missed queueRender. The renderer thread still
drains its mailbox post-wedge (resize/focus/reset_cursor_blink logged)
and there is no pause/resume mechanism in renderer/Thread.zig.

**RESOLVED DIRECTION: standalone ghostty from the same fork build
(zig-out/bin/ghostty) freezes identically after window resize — the
embedding shim is NOT the cause.** The bug lives in ghostty-core /
GTK-renderer / driver territory on this stack (fork base 80d3fa0,
GTK 4.20, GNOME 49 Wayland, AMD Mesa 25.3.6). Next-session leads, in
order: (1) GSK_RENDERER=gl / cairo comparison (first run handed to the
user tonight — capture the result); (2) search upstream ghostty issues
for post-resize freeze on AMD/GTK 4.20; (3) build upstream ghostty tip
and test — if fixed, rebase the fork; (4) if all reproduce, it's a
Mesa/GTK interaction — try GDK_DEBUG=gl-disable-* toggles and a distro
ghostty package for comparison.

Also shipped while investigating: `ghostty_embed_surface_grab_focus`
export + cmux uses it in the sync focus path (the Surface bin is
focusable:false; ghostty's own grabFocus targets the inner GLArea).
Resize itself was CONFIRMED WORKING at the core level (the earlier
"doesn't scale" impression was stale probe reads + old content laid out
for the previous width). **The default flip to ghostty is blocked on
this freeze.**

## 2026-07-17 — Resize freeze ROOT-CAUSED AND FIXED (fork patch, Darwin-gated)

The post-resize freeze was **a manaflow fork patch, not upstream and not
our embedding**: an anti-flash change in the SHARED `renderer/generic.zig`
re-presents the last completed frame on synchronous draws during size
changes ("let the normal render loop catch up on the next tick"). On
macOS async display-link draws eventually deliver the new frame; on GTK
every draw is synchronous (`drawFrame(true)` from the GLArea render
callback), so the early return latches after the first resize and the
surface replays its stale, old-size frame forever — terminal looks
frozen while input still reaches the PTY.

How it was found (the bisect that never needed to run):
- Build mode acquitted: fork ReleaseFast froze like Debug.
- Upstream acquitted: upstream@fork-date (worktree build) was healthy on
  the same machine — so the delta had to be fork patches.
- The fork is a GRAFT (squashed import, history unrelated to upstream) —
  `git merge-base` fails; compare CONTENT instead:
  `git diff <upstream-commit> <fork-base> -- src/` was small and pointed
  straight at `renderer/generic.zig` (+ the fork base commit's own title,
  "keep top-left gravity for stale-frame replay").
- An X11 screenshot-diff freeze detector was built
  (`linux/tests/ghostty-resize-bisect.sh`) but is UNRELIABLE on this
  stack: GTK ignores synthetic XSendEvent keys (use XTEST after
  windowactivate) and `import` cannot capture GL-presented pixels of
  XWayland windows (diff=0 even on healthy builds). xdotool windowsize
  works fine. Kept for reference/CI-on-X11 ideas.

Fix (ghostty `ae8ba5f0a`): both replay guards are now
`comptime isDarwin()`-gated — macOS compiles the identical code as
before; non-Darwin gets the pre-patch draw path. Verified: standalone
fork build survives aggressive resizing (human), and the embedded
cmux-adw dev2 instance resizes/splits/types cleanly with the rebuilt
shim (human). **The ghostty default flip is unblocked**; eager
background spawn remains the one open item before flipping.

## 2026-07-20 — Scroll snappiness fixed; ReleaseSafe cleared; mid-init leak found

Scroll felt sluggish embedded. Two causes, both fixed: the embed tick ran
at idle priority (starved behind input/redraw during scroll storms → now
G_PRIORITY_DEFAULT, ghostty `e9f17029e`) and the shim was a Debug build
(unoptimized renderer → ReleaseSafe is now the documented standard). Human
confirmed "supersmooth". Also: the desktop launcher is now the canonical
daily starter — the binary self-locates GHOSTTY_RESOURCES_DIR by walking
up from /proc/self/exe (cmux `571f85930`), and dogfood cycles now STREAM
the QA agent's live tool calls into the pane (`19dca2da4`,
dogfood-stream.py) instead of a silent banner.

**Investigation: dogfood cycle 7's "P1/P2 ReleaseSafe regression" was a
MISDIAGNOSIS — corrected.** The claim was that ReleaseSafe broke
socket-driven surface spawning and --cwd. Findings:
- The ReleaseSafe shim works perfectly in isolation (smoke harness with
  cwd=/tmp sets the title to /tmp, spawns the shell).
- A FRESH ReleaseSafe cmux instance passes P1 and P2 cleanly. My earlier
  "Debug fixes it" A/B was confounded: the fix was the RESTART, not the
  build mode (the dogfood ran on a dev2 churned through 122 cycles).
- **ReleaseSafe is safe for the daily** — normal use and normal
  dogfooding (QA cycles do real work per surface, so surfaces realize).
- Real bug, narrow: a **close-during-init race**. Clean slow measurement
  (each surface realized + shell-confirmed before close): fresh baseline
  35 threads → 61 after the first surface (one-time Mesa GL driver
  thread pool, NOT a leak) → stable at 61 across cycles 2-5 (realized
  surfaces close with ZERO per-cycle leak). But FAST churn (create+close
  within ~1-2s, before GLArea realize) leaks ~1.5 threads/close and does
  not settle (44→74 stable) — GL context / renderer+io threads spawned
  during async init aren't fully reclaimed when the widget is torn down
  mid-init. Ghostty side: core surface deinit (thread join) runs in
  finalize; GL release runs in glareaUnrealize → displayUnrealized, which
  has a "OpenGL resources likely leaked" bail-out if makeCurrent fails.
  The validation soak's artificial 122-cycles-in-115s hit this and
  eventually exhausted resources → the "P1/P2" spawn failures.

Status: the leak affects only sub-realize churn, which real workflows
don't do. Filed as a scoped future task (guard close against in-flight
init, or make dogfood soaks pace above realize). NOT blocking; the daily
is snappy and correct.

## 2026-07-20 — Terminal find overlay (nearly free from ghostty)

Find-in-terminal, a feature the VTE path never had. Ghostty's Surface
already ships the entire search overlay (entry box, next/prev, match
highlighting, Escape-to-close) — `Surface.setSearchActive(active, needle)`
is public and does all of it. Total cost to expose it: a ~10-line shim
export (`ghostty_embed_surface_set_search`, ghostty `aba33f97a`) plus a
header-bar magnifier button bound to Ctrl+Shift+F
(`findInFocusedPane` → `SurfaceRegistry.ghosttySetSearch`). Human-verified
on dev2: Ctrl+Shift+F opens the bar, typing highlights matches, Enter
cycles, Esc closes. Ghostty-only (VTE panes no-op).

## 2026-07-21 — Strict-CSP sites: automation un-broken via isolated-world fallback

Found while dogfooding browser verbs from inside the port: on GitHub every
DOM-level verb (snapshot, get.text, find, click, eval) failed with
`js_error: EvalError: Refused to evaluate a string as JavaScript…` — only
the WebKit-native reads (title, URL) worked. Root cause: WKWebView exempts
user-agent scripts from page CSP, but WebKitGTK main-world evaluation is
subject to it, and our eval envelope string-evals the verb script
(`eval(...)` in `BrowserJS.run`), which strict `script-src` policies
(GitHub: `script-src github.githubassets.com`, no `unsafe-eval`) refuse.
So the whole automation surface silently degraded on strict-CSP sites —
GitHub, most banks, many SPAs.

Fix (`BrowserAutomation.swift`): `BrowserJS.run` still evaluates in the
main world first (exact previous behavior; `browser eval` keeps seeing
page globals, macOS parity), and on a CSP eval-refusal (`"Refused to
evaluate a string as JavaScript"`) retries once in the named isolated
script world `cmuxAutomation` via the `world_name` parameter of
`webkit_web_view_call_async_javascript_function`. Isolated worlds share
the DOM but bypass main-world CSP, so DOM verbs behave identically there.
Verified on the dev instance against github.com: snapshot returns the full
role/name tree, `get text h1` reads, `eval` counts 721 anchors, and
`click` on the Releases link performs a real navigation (isolated-world
event dispatch reaches page handlers). Regression-checked main-world eval
on ghostty.org. Residual deviation: on strict-CSP pages `browser eval`
runs in the isolated world, so page JS globals are invisible there
(macOS sees them everywhere) — noted in PARITY.md.

## 2026-07-21 — Direction decided: WebKit-native automation, no CDP

Follow-up questions from the CSP session ("do we want CDP? what about the
console? why did dev say vte?") settled the architecture question. Full
reasoning + increment list: `../../roadmap/06-webkit-native-automation.md`.
Summary of record:

- Our JS-injection verbs are the content-script/WebDriver-classic subset —
  the same mechanism Playwright uses for element interaction. Kept as the
  workhorse.
- What page-JS can never reach (trusted input, network interception,
  debugger, cross-origin frames, CSP-proof console capture) we take from
  the **native WebKitGTK API**, not from a CDP engine: WebKit doesn't
  speak CDP, and Chromium/CEF embedding is rejected (dependency swap,
  loses GTK integration). Fedora ships `/usr/bin/WebKitWebDriver`
  (webkitgtk6.0 2.52.4); WebKitAutomationSession is in our headers.
- Console verbs verified working live (wrap-based, main world) on normal
  sites; strict-CSP blind spot documented — the lazy-armed wrap lands in
  the isolated world there and captures nothing the page logs. Fix is
  roadmap/06 increment 1 (document-start user script + script message
  handler; user scripts are CSP-exempt user-agent scripts).
- Sighting explained: `start.sh status` reported the ghostty daily as
  `terminals=vte` — an artifact of `ldd` on a "(deleted)" `/proc/pid/exe`
  after a rebuild, plus my plain `swift build` really had produced a
  VTE-only binary (both fixed/documented above and in the gotchas).

## 2026-07-21 — Console capture v2 (roadmap/06 increment 1) ✅

Killed the strict-CSP console blind spot documented the same day. The old
hooks wrapped `window.console` via the eval envelope, armed lazily on
first use — on a strict-CSP site that arming landed in the isolated world,
wrapped the wrong world's console, and captured nothing the page logged.

Replaced with the native WebKit path: a **document-start user script**
(`webkit_user_script_new` + `webkit_user_content_manager_add_script`)
wraps console.*/error/unhandledrejection in the MAIN world and posts each
entry through a **script message handler**
(`register_script_message_handler`, signal connected first per the
WebKitGTK race warning) into a per-surface app-side ring buffer
(`BrowserConsoleLog`, 512 entries, cleared in `SurfaceRegistry.unregister`).
User scripts are user-agent scripts — exempt from page CSP and eval-free.
`console.list/clear` and `errors.list` keep their exact wire shape but now
read the app-side buffer (no JS round-trip).

Verified on a purpose-built strict-CSP page (`script-src 'self'`, served
with the header, logging at load): main-world eval was refused (`eval 1+1`
answered 2 via the isolated-world fallback, proving CSP really was
strict), yet console list returned the page's own log/warn/error **with no
arming call ever made**, and errors.list caught a thrown error with its
source file. Regression-checked on a non-CSP page (capture + main-world
eval seeing page globals), plus clear and per-surface isolation.

Deliberate semantic: entries logged by our own isolated-world automation
are NOT captured — we record what the page logs, not what we log.

## 2026-07-21 — W3C WebDriver opt-in (roadmap/06 increment 2) ✅

Trusted input, the one thing our JS-injection verbs fundamentally cannot
do. WebKitGTK speaks W3C WebDriver (not CDP); an app opts in by allowing
automation on its web context, then answers two signals.

Implementation (`BrowserWebDriver.swift`, gated on `CMUX_WEBDRIVER=1`):
`webkit_web_context_set_automation_allowed` on the default context,
`automation-started` → set application info + connect the session's
`create-web-view`, which constructs the driver's view with the
construct-only `is-controlled-by-automation` property (6.0 ships only
`webkit_web_view_new(void)`, so `g_object_new_with_properties`) on the
automation network session (ephemeral profile — the driver does NOT get
the human's cookies) and presents it in its own window.

**API archaeology:** WebKitGTK 6.0 exports `set_automation_allowed` /
`is_automation_allowed` / `get_network_session_for_automation` and
documents `WebKitWebContext::automation-started` in
`/usr/share/gir-1.0/WebKit-6.0.gir`, but Fedora's installed C headers
OMIT the two functions. Prototypes are therefore declared in
`Sources/CWebKit/shim.h` against the real exported symbols.

Verified end-to-end with the real `/usr/bin/WebKitWebDriver`:
- Session creation returns `"browserName":"cmux","browserVersion":"1"` —
  our application info surfacing through WebDriver capabilities, proving
  the whole handshake fired.
- Navigation, element lookup, click and send-keys all work.
- **The payoff, measured on one page:** WebDriver click/keys →
  `click isTrusted=true | keydown isTrusted=true`; the same page driven
  by our JS verbs → `click isTrusted=false`.

Gotchas found: capabilities must OMIT `browserName` (we report "cmux", so
asking for "webkitgtk"/"MiniBrowser" fails capability matching); the
driver launches the browser binary itself, so point
`webkitgtk:browserOptions.binary` at a wrapper that sets an isolated
CMUX_APP_ID/SOCKET_PATH — otherwise it collides with the daily; and one
session at a time unless `--replace-on-new-session`.

Scope note: this drives a driver-owned window in a driver-launched
instance, not the human's existing panes (that is the WebDriver model).
Adopting a cmux split as the automation view is the follow-up.

## 2026-07-21 — WebDriver split adoption: driver and cmux share one pane ✅

The automation view is now a real cmux pane instead of an orphan window.
`create-web-view` builds the driver's view, then hands it to
`BrowserAdoption.adoptIntoSplit` (wired in CmuxApp, which owns the model
bindings): a `.browser` leaf is spliced into the selected workspace and
the pre-made view is registered in `BrowserAdoption.pending`;
`BrowserSurfaceFactory.create` adopts that view instead of constructing
its own. Standalone-window fallback remains when there is no UI yet.

**Bug found and fixed while verifying — ordering matters.** The first
implementation registered the pending view *after* calling `split()`.
Mutating the tab layout can trigger a re-render (and therefore the
surface factory) before the call returns, so the factory built its own
blank view: WebDriver drove an invisible orphan while the visible pane
stayed empty (measured: driver url = the test page, cmux url on the pane
= empty, `#out` not found). `adoptBrowserSplit(register:)` now invokes
the registration callback BEFORE the model mutation. Same class of race
as any "publish before you mutate" ordering bug.

Verified in attach mode against a running instance:
- Session creation grows the workspace 1 pane → 2 panes.
- **Same surface from both sides**: WebDriver `GET /url` and cmux
  `browser url --surface surface:2` both report the test page.
- **Combined power on one pane**: WebDriver trusted click → cmux
  `get text #out` reads `click isTrusted=true`; cmux `snapshot` returns
  the role/name tree with element refs; console capture v2 records
  entries — all against the driver-controlled view.

## 2026-07-21 — WebDriver test harness: 9/9 incl. a live GitHub click

`linux/tests/webdriver-smoke.sh` (+ `linux/tests/README.md`) is now the
regression test for the whole WebDriver stack, runnable beside the daily
instance (own app id/socket/session). Nine assertions: automation opt-in ·
attach session without launching a browser · split adoption grows the
workspace · driver and cmux report the same URL for the adopted pane ·
WebDriver click yields `isTrusted=true` · console capture v2 on the
driver-controlled pane · cmux snapshot on github.com (isolated-world CSP
fallback) · a WebDriver click really navigates GitHub
(`/cmux` → `/cmux/issues`) · cmux observes that navigation on the same
pane. Result: **9 passed, 0 failed.**

Getting there cost four rounds, each a lesson now encoded in the harness
and its README:

- **Hidden elements.** `a[href$="/issues"]` matches several nodes on
  GitHub; the first three are `displayed=False` and WebDriver correctly
  refuses with `element not interactable`. That strictness is a genuine
  behavioral difference from our JS verbs, which would dispatch on a
  hidden node regardless — real-user semantics vs. blind dispatch. The
  harness now picks the first *displayed* match.
- **Hand-escaped JSON.** Selectors contain double quotes, so
  `"value":"$1"` produced invalid JSON and matched nothing. Payloads are
  built with `json.dumps` now.
- **A false-passing assertion.** "cmux sees the driver's navigation"
  compared two URLs that were both unchanged. Navigation assertions must
  require `after != before`.
- **Stale test state.** A `--keep` run leaves the fixture server holding
  its port, which poisoned the next run into five unrelated-looking
  failures. The script now frees its ports and kills its own app-id
  instance before starting.

Also confirmed while debugging: **each WebDriver session adopts its own
pane** (a second session added a third pane), and a suspected staleness
bug in `browser url` was a false alarm — the query had targeted the first
session's pane; the correct pane agreed with `location.href` and the
snapshot title.

## 2026-07-21 — Flakiness check: 8/8 green, plus a leak the green runs hid

Ran `webdriver-smoke.sh` five times, then three more after hardening.
**All 8 runs: 9 passed, 0 failed** — no flakiness in the WebDriver /
adoption stack. Runtime was near-identical each run because it is
dominated by fixed waits, not variance.

The exercise still paid for itself twice:

- **Leaked fixture server, masked by the green runs.** The suite started
  its HTTP server as `cd "$WORK" && python3 -m http.server &`, so `$!`
  held the *wrapper subshell's* pid; cleanup killed the wrapper and
  orphaned the server, which kept holding the port after every run. It
  never showed up as a failure because the pre-flight cleanup frees that
  port at the start of the next run — a self-masking leak. Fixed with
  `--directory` (no subshell) plus a `free_port` backstop in cleanup;
  verified by checking the port immediately after each of three runs.
- **Latent timing flake removed.** The GitHub section used a fixed
  `sleep 6`; on a slower network that fails in a way that looks like a
  product bug. Now polls for the link (≤20s), which is both more robust
  and *faster* in practice: 27s → 20s per run.

Lesson worth generalizing: "the suite is green" is not the same as "the
suite is clean" — check for leaked processes/ports after a run, not just
exit codes.

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
- `cmux new-workspace --background` prints plain `OK workspace:N` even
  with `--json` — a script that greps JSON keys out of it gets an empty
  ref, and a later `--workspace $EMPTY` silently falls through to the
  SELECTED workspace (the flag value gets eaten by the adjacent arg).
  Parse the `OK <ref>` line, and verify the target workspace in the
  reply of whatever you create next.
- A plain `swift build` produces a VTE-ONLY binary and silently overwrites
  the shim-linked one on disk (`Package.swift` gates the shim on the
  `CMUX_GHOSTTY=1` env var at manifest evaluation time). Promotion trap:
  the next daily restart would demote the human's terminals to VTE. Always
  `CMUX_GHOSTTY=1 swift build` before promoting; verify with
  `ldd .build/debug/cmux-adw | grep libghostty-gtk`. (`start.sh status`
  now reads `/proc/<pid>/maps`, so a post-rebuild "(deleted)" exe no
  longer misreports the running backend as vte.)
- Adwaita model mutations can re-render (and run the surface factory)
  before the mutating call returns. Anything the factory must see —
  e.g. a pre-made web view for WebDriver adoption — has to be registered
  BEFORE the model is touched, never after.
- WebKitGTK main-world JS evaluation is subject to the PAGE's CSP (unlike
  WKWebView, which exempts user-agent scripts). Anything injected with
  `call_async_javascript_function`/`evaluate_javascript` that string-evals
  will throw `EvalError: Refused to evaluate…` on strict-CSP sites unless
  it runs in a named isolated world (which shares the DOM but bypasses
  main-world CSP). `BrowserJS.run` handles this; new injection paths must
  too.

## 2026-07-21 — SPA extraction dogfood (pocketyoga): two real bugs, one fixed

Dogfood cycle 6, run against the **dev** instance (see trap below), focus:
"extract all yoga poses from a client-rendered Vue SPA using ONLY cmux
browser verbs". Result: the agent extracted **563/563 poses, 0 missed, 0
spurious, 562/562 descriptions**, scored against the site's own
`poses.json`. The browser stack is genuinely capable of this job — the
value of the run was the two defects it surfaced on the way.

**Bug A — `browser eval` result transfer was quadratic (FIXED).**
`SocketClient.send` in `CLI/cmux.swift` rescanned the *entire* accumulated
`Data` for a newline after every 8 KB read: `N/8192 × O(N)`. Measured
before → after: 1 MB 1.43s → 0.24s, 3 MB 11.65s → 0.50s, 6 MB 44.32s →
0.87s (51×), 16 MB ~5min projected → 2.15s. Now linear. `sawNewline` is
monotonic, so scanning only the newly-read chunk is semantically
identical; the change is plain Swift stdlib in the shared CLI, so macOS
gets it too. Symptom worth remembering: **no error, no truncation — it
just looked like a hang**, which is worse than failing.

**Bug B — `goto` returns before the navigation commits (OPEN).**
`v2BrowserNavigate` (`BrowserSurfaces.swift:131`) calls
`webkit_web_view_load_uri` and returns OK synchronously. WebKit loads
async, so a following `eval`/`wait` can run against the *previous*
document and report success. Reproduced independently of the agent:
12 × (`goto` → `eval 'location.pathname'`) gave **10 correct, 2 stale**.
This is the dangerous class — not a crash but silent wrong data, and a
`wait` predicate that happens to be true on the old page passes
instantly. Fix direction: defer the response until
`WEBKIT_LOAD_COMMITTED` (the socket layer already supports async
`respond`), and/or `goto --wait-selector/--wait-function` as an atomic
navigation barrier. Decide whether blocking becomes the default.

Verified-good in the same run: `browser wait --selector/--function` with
correct OK/rc=1 semantics (settle detection needs **zero sleeps** — an
85-page crawl ran at 0.64 s/page), `fill` triggering real Vue reactivity
and debounced refetch, JS state persisting across `eval` calls on one
document, and honest error surfaces (`js_error`/`not_found`/`timeout`).
Known friction: `snapshot` truncates node text at ~110 chars with no
override; no `eval --file`/stdin, so scripts must be inlined into shell
strings.

Traps this cycle added:

- **Dogfood must target the dev instance now that Ghostty is default.**
  Ghostty surfaces spawn their shell on first map, so the tester's
  *background* workspace stays shell-less — and on the daily instance the
  harness deliberately skips the `select-workspace` that would start it
  (focus etiquette). A daily-targeted run would sit there and time out.
  `CMUX_SOCKET_PATH=/tmp/cmux-dev.sock linux/scripts/dogfood.sh …`.
- **An oracle is ground truth only for the surface under test.**
  `poses.json` holds 563 poses, but `visibility` splits them 167
  primary / 312 secondary / 84 tertiary, and the index page links *only*
  the 167 primary. Asserting "did you get all 563?" against an
  index-only extraction would score a perfect result as a 70% failure.
  (The agent got all 563 anyway, by reading the app's in-memory store and
  crawling detail pages.)
- **Check the product's own surface before declaring a primitive
  missing.** The pre-run design note claimed a `wait_for_js` wrapper was
  "the key missing primitive"; it was inferred from the *test harness's*
  helpers rather than from `cmux browser --help`, where
  `wait --selector/--text/--url-contains/--load-state/--function
  --timeout-ms` has existed all along. The QA agent found it in two
  minutes. Grep the CLI surface before designing a replacement for it.

## 2026-07-21 — navigation barrier: `goto` no longer returns on a stale page

Fixes bug B from the SPA-extraction dogfood above, blocking-by-default as
decided. `browser.navigate` / `back` / `forward` / `reload` moved from the
synchronous v2 group into the async one and now hold their response until
the new document is committed.

**How it resolves**, in order: `WEBKIT_LOAD_FINISHED` (fully loaded — what
a caller means by "go here"), else `WEBKIT_LOAD_COMMITTED` once the
deadline passes (the stale-document hazard is gone, subresources may still
be in flight; reported as `load_state`), else a real `timeout` error —
with no commit at all the *old* page would still be answering, so claiming
success would be a lie. Default budget 10s, `--timeout-ms` to change it,
`--no-wait` to opt back into fire-and-forget.

`load-changed` is connected **before** the load is requested; polling after
the fact is precisely what made the old code race. Optional
`--wait-selector`/`--wait-function`/`--wait-load-state` chain into the
existing `browser.wait` machinery *inside* the same barrier — issued as two
separate commands there is still a gap the old document can answer in.

Result: the live-site race went 2-stale-in-12 → **0 in 30**; against the
new suite's deliberately delayed fixture, 20/20 clean where `--no-wait`
(the old behavior) is 20/20 stale.

Three further bugs surfaced while building it:

- **Stale load events settle the wrong barrier.** Starting a navigation
  cancels any in-flight one, and the cancellation *also* emits
  `LOAD_FINISHED` — the first version honored it and returned "finished"
  for a load that was never ours (the unreachable-host assertion returned
  OK in 116ms). Fixed by requiring `COMMITTED` before `FINISHED` counts:
  a commit is the earliest point the event is provably ours. **My own
  regression test caught this in my own fix** — worth remembering as an
  argument for writing the test before believing the patch.
- **The transport silently truncated every `timeout_ms` over 15s.** Both
  `ControlSocketServer.dispatchOnMainLoop` and the CLI capped at a flat
  15s, so `wait --timeout-ms 20000` died at 15s with a transport timeout
  that reads *exactly* like the condition never being met — the caller
  cannot distinguish "your predicate failed" from "we hung up on you".
  This is almost certainly the dogfood agent's "transient 20s timeout".
  Both ends now derive their budget from the request's own `timeout_ms`.
- **`goto` folded trailing flags into the URL.** `subArgs.joined(" ")`
  took *all* remaining args, so `goto <url> --snapshot-after` navigated to
  `"<url> --snapshot-after"`. Flags are now parsed out first.

macOS has the same navigation race (`v2BrowserNavigate` → `navigateSmart`
→ immediate `.ok`), so the barrier is a genuine Linux-side improvement
rather than a port artifact; noted in FEATURES.md and worth mentioning
upstream.

New suite: `linux/tests/browser-navigation-smoke.sh` — 8 assertions,
4 clean runs, and `webdriver-smoke.sh` still 9/9.

## 2026-07-21 — screenshot papercuts (found by a second session using the app)

A parallel Claude session driving a browser pane from a fresh workspace
reported that `browser screenshot` is undocumented and discards the image
without `--out`. Both true, with a nuance worth recording: the verb *is*
in `cmux browser --help`, and was missing only from the global
`cmux --help` browser list — which is where anyone looks first.

Three fixes:

- **Global `cmux --help` now lists `browser screenshot`.** A verb
  documented in only one of two help surfaces is undiscoverable in
  practice.
- **The no-`--out` case no longer lies.** The PNG was captured,
  base64'd across the socket, and dropped on the floor while printing a
  bare `OK` — which reads as "screenshot taken" and sends the caller
  hunting for a file that was never written. It now says the image was
  not saved and names both ways to keep it (`--out`, `--json`). Same
  class as the quadratic transfer and the 15s cap: *no error, no
  truncation, just behavior that looks like something else.*
- **New `--full-page`.** We asked WebKit for
  `WEBKIT_SNAPSHOT_REGION_VISIBLE`, so a page laid out wider or taller
  than the pane was silently cut off — the reporting session's screenshot
  had every description line severed mid-word, and nothing in the image
  says so. `--full-page` uses `WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT`:
  measured 408x704 (viewport) vs 980x1202 (full document) on the same
  pane, with the clipped text, the second transition section and the
  footer all restored. Viewport stays the default — it is what the human
  sees, and it matches macOS.

Not a bug, checked: the page rendered "Mountain with Prayer Hands" for
`/pose/Mountain`. Straight after shipping a navigation barrier that is
exactly the right shape to cause that, it had to be ruled out — the
site's own data file gives `name: "Mountain"` the display name "Mountain
with Prayer Hands" (tadasana + pranamasana), so the render was correct
and the oracle agreed.

macOS parity note: `BrowserPanel.takeSnapshot` uses a default
`WKSnapshotConfiguration`, i.e. the visible viewport too — so the
clipping is shared behavior, and `--full-page` is a Linux-side addition
rather than a port fix.

## 2026-07-21 — Web Inspector pane (roadmap/06 increment 3)

`cmux browser inspect` opens DevTools for a browser surface in a real cmux
split beside it. Human-confirmed rendering on the dev instance.

**The API is not shaped the way it looks.** Probed empirically before
writing anything (`inspector-probe.c`, webkitgtk-6.0 2.52.4):

- `webkit_web_inspector_get_web_view()` returns **NULL** both before and
  after `show()`. The widget exists only *inside* the placement signal
  handler — so the destination pane must already exist when `show()` is
  called; there is no "create it, then fetch the widget".
- The returned object is a `WebKitWebViewBase` with **`WEBKIT_IS_WEB_VIEW`
  false**. It is a GtkWidget but NOT a WebKitWebView, so it must never go
  through the browser surface factory, which calls `webkit_web_view_*` on
  whatever it adopts. Reusing `BrowserAdoption` would have been UB.

**The bug the probe could not catch.** The isolated probe (a web view
alone in a GtkWindow) emitted `attach`. Inside cmux's pane tree WebKit
emits **`open-window`** instead — it decides it cannot dock. The first
implementation claimed `open-window` (returned TRUE) without placing
anything, which suppressed the window *and* left an empty pane: strictly
worse than either alone. The human's screenshot is what caught it; the
app reported success throughout. Both signals now route through one
placement path, and TRUE is returned **only if placement succeeded**,
otherwise WebKit keeps its fallback. Lesson filed in LESSONS.md: a probe
in a simplified environment does not transfer — the surrounding widget
tree changed WebKit's decision, and nothing in the probe could have
revealed that.

**Async, like the navigation barrier.** WebKit places the inspector on its
own schedule, well after the split lands. `browser.inspect` therefore
completes asynchronously and polls up to 3s, returning `attached:
true/false` — reporting OK at split time would have claimed a DevTools
pane that was in fact empty. Verified end state: `attached: true`, widget
allocation 408x347, `mapped=1`.

**Not persisted, deliberately.** WebKit only surrenders the widget during
its own signal, so a restored inspector pane would be permanently empty.
`layoutSnapshot` now returns nil for them and a split with one pruned side
collapses to the survivor (a workspace of nothing else falls back to a
terminal, so the workspace itself is never lost).

macOS parity note, checked rather than assumed: macOS cmux **does** have
DevTools (`BrowserPanel.toggleDeveloperTools/showDeveloperTools`, via
WKWebView's private `_inspector` through runtime selectors). The
difference is presentation — theirs is WebKit's own inspector, ours is a
first-class cmux pane you can move and close like any other — and that we
use public API. Not a ★ feature; a differently-shaped one.

Also removed here: the superseded synchronous `v2BrowserHistory` in
BrowserSurfaces.swift. It had been dead since the navigation barrier
landed (ControlProtocol routes to the async version), but a racy
implementation sitting in the tree is an invitation to re-route to it.

## 2026-07-21 — popup routing: window.open lands in a pane (roadmap/06 increment 5)

`window.open()` and `target="_blank"` now open a browser pane beside their
opener instead of doing nothing. Human-confirmed rendering.

**The hole was a default.** `javascript-can-open-windows-automatically`
defaults to **FALSE**, and while it is off WebKit never emits `create` at
all — so popups produced no pane, no error, and `window.open` returning
null. OAuth flows, payment popups and "open in new tab" links all
dead-ended silently. Same family as today's other finds: it looked like
something else and reported nothing.

Probed first (`linux/tests/popup-probe.c`), which corrected three things
before they became bugs:

- `webkit_web_view_new_with_related_view()` **does not exist in
  WebKitGTK 6.0**. The opener relationship is a **construct-only**
  `related-view` property, so it must go through
  `g_object_new_with_properties` (the variadic `g_object_new` is unusable
  from Swift) — the same shape as WebDriver's
  `is-controlled-by-automation`. Sharing the web process is what keeps
  `window.opener` alive; verified `true` on a `window.open` popup.
- **WebKit loads the target URL into the view we return.** The probe
  deliberately loaded nothing and `ready-to-show` still reported the
  target URI. Loading it ourselves would fetch every popup twice.
- Returning NULL is a clean block — the page simply sees `window.open`
  return null.

`adoptBrowserSplit` gained a `nextTo:` anchor: a popup must land beside
its **opener**, which is not necessarily the focused surface and may live
in a workspace the human is not looking at. It also now only moves focus
when the anchor's workspace is already selected, so a background popup
cannot reach out and steal focus (socket focus policy).

**Burst budget.** Enabling the setting disables the popup blocker, so a
page can ask for panes in a loop. Routing them into visible panes is
friendlier than hidden windows, but it is still an unbounded request from
the page: 5 popups per opener per 10s, excess declined and logged.
Verified 8 requested → 5 created. Compare roadmap/05 — page- or
agent-drivable resource growth is the same class of problem.

**Known limitation (from the human's screenshot, not visible in the CLI
output):** every popup splits "right" off its opener, so each one halves
the remaining width. Two popups are comfortable; five are slivers. The
burst cap bounds the damage but does not fix the layout. Options if this
becomes annoying: split the larger dimension instead of always right,
reuse an existing popup pane for the same opener, or route popups to a
sibling workspace. Deliberately not guessed at yet.

Verified end to end: opener + `window.open` pane + `target=_blank` pane
with correct URLs; `window.opener` true for `window.open`, null for
`target=_blank` (correct — modern browsers imply `noopener` there).
New suite `linux/tests/browser-popup-smoke.sh` (6 assertions);
webdriver-smoke 9/9 and browser-navigation-smoke 8/8 still pass, which
matters here because popup routing changed `adoptBrowserSplit`, the same
helper WebDriver adoption uses.

macOS parity, checked rather than assumed (the first draft of the
FEATURES entry claimed this as a Linux-only feature and was wrong):
macOS **does** route popups, in
`BrowserPanel.webView(_:createWebViewWith:…)`, and its logic is currently
**richer than ours** — it weighs middle-click intent, modifier flags and
open-externally rules to choose new-tab vs new-window vs hand off to the
system browser. The Linux path handles the plain cases only. Worth
porting that decision logic later; the burst budget is the one piece
Linux has that macOS does not.

## 2026-07-21 — split-direction stopgap + `cmux search` across panes

**Stopgap: splits follow the longer axis.** `adoptBrowserSplit` always
split "right", so every popup halved the width — the human's screenshot
showed four popups as unreadable vertical slivers. It now splits along
the pane's longer axis (`preferredSplitDirection`, falling back to
"right" for an unrealized pane). Measured with four popups by asking each
browser pane for its own `window.innerWidth/innerHeight`: worst aspect
ratio went from ~0.2 (143x700 slivers) to ~0.55 (97x176). **This fixes
shape, not size** — five panes in half a window are still small, and the
AdwTabView work is the real answer. Recorded as a stopgap, not a fix.

**`cmux search <query>` — text search across every pane.** Chosen over
`WebKitFindController` first because the two are different features
wearing one name: interactive find (live highlight, next/prev, one pane)
versus "which of my panes mentions this?". A shared engine would leak
immediately — one side is a line buffer with scrollback, the other a DOM
with frames — so they share a result shape and nothing else.

This half needed **no new WebKit API**: terminal text already comes from
the `surface.read_text` path (now factored into `terminalText(for:)` so
the two can never disagree), and a browser pane's text is one
`document.body.innerText` eval away. Terminal panes answer synchronously,
browser panes are dispatched in parallel and the response waits for the
last one.

Flags: `--workspace`, `--kind terminal|browser`, `--regex`,
`--case-sensitive` (insensitive by default), `--scrollback`,
`--max-per-surface`. `--json` returns per-hit `surface_ref` /
`workspace_ref` / `pane_ref`, which is the agentic payoff: find the pane
showing the error, then focus or drive it.

`innerText`, deliberately, not `textContent` — script bodies and
`display:none` content would otherwise produce matches for text no human
can see on screen. Both cases are asserted.

**Results are a snapshot** (a browser repaints, a terminal scrolls) and
terminal coverage is bounded by what the backend returns. Inspector panes
are skipped: they host WebKit's own UI, and searching it would report
matches the user never wrote.

Three bugs found while testing, two of them mine rather than the code's —
worth recording because both are easy to mistake for product bugs:

- **Real bug:** the CLI case read `args` (full argv) instead of
  `commandArgs`, so the query became
  `"/path/to/cmux search Tadasana"`. Invisible in the human output ("No
  matches"); obvious the moment `--json` echoed the query back. An
  argument that is echoed in the response is worth having.
- **Real bug:** terminal hits were captioned with `tab.title`, which
  follows the *focused* surface — so a terminal match was labelled with
  the browser pane's page title. Now labelled with the shell's live cwd.
- **Test error, not a bug:** searching for "Tadasana" on the *Tree* pose
  page found nothing, correctly (Tadasana is Mountain). And `send
  --workspace` targets the FOCUSED surface, which was the browser, so the
  marker never reached the terminal. Both looked like search failures.
  The suite now uses a local fixture with unambiguous needles and targets
  the terminal surface explicitly.

New suite `linux/tests/pane-search-smoke.sh` (11 assertions, first-run
green). webdriver-smoke 9/9, browser-navigation-smoke 8/8,
browser-popup-smoke 6/6 — the last two matter because the split-direction
change touches `adoptBrowserSplit`, which both use.

## 2026-07-21 — find-in-page for browser panes (roadmap/06 increment 5)

Ctrl+Shift+F worked in terminal panes (Ghostty's overlay) and did nothing
in browser panes. It now opens a find bar backed by
`WebKitFindController`, and the same controller is drivable over the
socket as `cmux browser find-in-page`.

Probed first (`linux/tests/find-probe.c`), which found the trap that
would otherwise have shipped:

- `search()` reports the **total** match count via `found-text`.
- `search_next()`/`search_previous()` emit `found-text` too — but with
  the count argument set to **1**, not the total. Trusting it would make
  the counter read "1 of 1" on every step. The total is therefore kept
  from the initial search and the current index tracked in our own state.
- `failed-to-find-text` is the no-match signal; `search_finish()` clears
  the highlight.

One probe result was deliberately NOT designed around: three
`search_next()` calls fired in a single main-loop iteration produced a
`failed-to-find-text` instead of wrapping. That is almost certainly the
probe firing async operations without letting WebKit process them, not
API behaviour — recorded as unexplained rather than treated as fact.
Wrapping works correctly when stepped one call at a time (asserted).

**Structural change:** a browser pane's container is now a GtkBox holding
[find bar, web view] instead of the bare web view, since the bar needs
somewhere to live. `registerBrowser` already kept the container and the
web view as separate pointers, so nothing else had to change — but this
touches every browser pane, so all four existing suites were re-run
(webdriver 9/9, navigation 8/8, popup 6/6, search 11/11) before and after.

**Bug found by the socket verb, not by the UI:** a new search did not
reset the previous query's `total`, and the verb polls until the count
settles — so it returned the *old* numbers immediately. `NEEDLE
--case-sensitive` reported "1 of 3" instead of "1 of 1", and a
non-existent string reported "1 of 3" instead of "No results". Fixed with
an explicit `awaitingResult` flag rather than inferring "done" from a
non-zero count. This is the same stale-read shape as the `goto` barrier
and the eval-count trap: **polling on a value that has a valid-looking
stale reading cannot tell "not yet" from "unchanged".**

Adding the socket verb was what made this testable at all — the feature
is otherwise a GTK widget that only a screenshot can check. It also means
an agent and the human drive the *same* controller, so highlighting is
identical rather than a parallel implementation.

New suite `linux/tests/browser-find-smoke.sh` (11 assertions). One of its
assertions was wrong on the first run — after `--previous` lands on match
3, `--next` correctly wraps to 1, so the intended mid-sequence check had
to step off the boundary first. Test error, not a product bug.

## 2026-07-21 — per-pane tab strips (AdwTabView); popups become tabs

A pane now holds several surfaces behind an AdwTabView tab strip, and
popups land there as tabs instead of forcing another split. Measured with
three popups: **5 panes → 2**, and the opener pane keeps its full
408x704 instead of collapsing to ~100x176.

**Cheaper than it looked, for two reasons.** `adw_tab_view_new()` is
reachable straight from Swift through adwaita-swift's `CAdw` module — the
earlier claim that this needed a C shim was wrong. And the design was
already half-built: `PaneLeaf` always carried both `paneId` and
`surfaceId`, and the *protocol* was already plural (`surface_count`,
`surface_refs`, `selected_surface_ref` — `list-panes` was hardcoding 1).
Only the model was capped at one surface. This finished an intended
design rather than inventing one.

`PaneLeaf` now holds `[PaneSurface]` + a selected index, with
back-compat accessors (`surfaceId`, `kind`, `workingDirectory`) meaning
"the surface this pane is showing". **All 144 `.surfaceId` call sites
compiled unchanged.**

**That clean build is the hazard, and it deserves stating plainly:** the
compiler cannot flag a site that ought to enumerate *every* surface but
still sees only the selected one. Those were audited by hand —
widget construction, registry cleanup, session save, pane search and
`list-panes` all use `allSurfaces` now. The registry-cleanup one is the
dangerous one: leaving it would have destroyed the widgets of every
background tab.

`adw_tab_bar_set_autohide` keeps this free for the common case — a
one-surface pane shows no bar and looks exactly as before.

**Closing semantics** (the human asked for these specifically, and they
are the part that can strand state): closing one tab of a multi-tab pane
removes only that tab; the pane survives until its last tab goes, and
then the pane goes with it. Four assertions, all passing.

**Known gap:** the session snapshot format stores one surface per leaf,
so a restored multi-tab pane comes back as sibling *panes*, not tabs.
Chosen deliberately over silently dropping the extra tabs — a shell's cwd
is worth more than the tab grouping — but a proper fix needs a schema
version bump.

**The popup suite failed 4 assertions after this change and was updated,
not silently repaired**: it asserted *pane count increases*, which is
exactly the behaviour this change reverses. It now asserts on surface
counts, plus two new checks that pin the actual goal (popups must NOT add
splits; the tabbed pane must keep full width). Two test-only findings: a
pane's surface refs no longer track its pane ref once it has tabs (ask
the protocol, don't derive), and a background tab reports **0px** — right
for tabs, impossible with splits, and it made the first version of the
width assertion measure the wrong surface.

Also added: `~/.local/share/applications/com.manaflow.cmux.dev.desktop`,
a GNOME launcher for the isolated dev instance (runs `start.sh dev`, so
it inherits the double-daily refusal and app-id isolation). Pre-flighted
the promotion path by restoring the human's real 5-workspace session file
(a copy) under the new binary in a throwaway instance: all five restored,
no errors.

Suites after the refactor: webdriver 9/9, navigation 8/8, popup 12/12,
search 11/11, find 11/11.
