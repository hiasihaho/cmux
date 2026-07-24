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

## 2026-07-21 — session schema v3: normalized surfaces, real browser state

Multi-tab panes now round-trip. The v2 format inlined a surface into each
layout leaf, so a pane could only ever persist one — the tab work shipped
with extra tabs coming back as *sibling panes*. That was a normalization
problem, not a platform one.

**macOS was already right, and does not use anything mac-only.** Read
before designing (`Sources/SessionPersistence.swift`): a workspace stores
`panels: [SessionPanelSnapshot]` flat, and the layout tree references them
— `SessionPaneLayoutSnapshot { panelIds: [UUID], selectedPanelId: UUID? }`
*is* tabs-per-pane, persisted. v3 mirrors that: `surfaces` flat per
workspace, `LayoutSnapshot.pane(surfaceIds:selectedId:)`.

Just as important, `SessionBrowserPanelSnapshot` stores **plain strings** —
url, zoom, back/forward URL lists — and deliberately *not*
`WKWebView.interactionState`. Nothing to port around.

**v2 stays decodable.** `restore()` probes the version and migrates;
refusing an old file would silently discard a real session. Verified
against the human's actual 5-workspace file (a copy).

**Browser state is layered, and the layering is the design.** Portable
fields (url/zoom/history URLs) mirror macOS and are inspectable in the
JSON. WebKitGTK's own `webkit_web_view_get_session_state()` blob rides
alongside, base64, capped at 512 KB. The rule that makes an opaque
format safe to adopt: **it is never load-bearing** — tried first, and a
missing/stale/version-rejected blob costs nothing because the portable
path still restores. Strategies live in an ordered array; adding one is a
function and a line.

That buys something macOS cannot do: **the restored back/forward list is
real**. macOS emulates history with shadow stacks
(`restoredBackHistoryStack`, `usesRestoredSessionHistory` in
BrowserPanel) because WKWebView has no API to rebuild a list from URLs.
We hand WebKit its own state back. Asserted: after a restart, `back` and
`forward` genuinely navigate.

Three bugs found while testing, all in the new code:

- **A save that races surface creation persisted `url=""` forever.**
  Adopting a popup mutates the model, which triggers an *immediate* save —
  and at that instant WebKit has not committed a URI to the new view. The
  tab then came back blank. Fixed with a last-known-good URL cache;
  asserted ("no browser surface persisted an empty URL"). Note the shape:
  the 15s timer would have corrected it, so this only bit on a quick
  quit — which is exactly when a user expects their session to be saved.
- **`load_uri` after `restore_session_state` duplicates the current
  entry**, so `back` landed on the page you were already looking at —
  indistinguishable from history restore not working. Fixed with
  `go_to_back_forward_list_item`, which navigates *within* the restored
  list.
- The first round-trip test compared `surface:N` refs across a restart.
  Refs are reassigned on load, so that comparison is meaningless; the
  suite compares UUIDs.

**Known gap:** browser state is only captured on a model change or the 15s
timer, because a navigation is not a model change. A quit within seconds
of navigating persists the previous URL. Fixing it properly means
capturing on `load-changed`, which is a per-navigation write to the
session file — deliberately not done yet.

New suite `linux/tests/session-persistence-smoke.sh` (10 assertions:
migration, tab round-trip, selection, URLs, navigable history). All six
suites green: webdriver 9/9, navigation 8/8, popup 12/12, search 11/11,
find 11/11, session 10/10.

## 2026-07-21 — browser.tab.* (closing a parity gap the tab work unlocked)

`browser.tab.list / new / switch / close`, mirroring macOS's verbs of the
same name. These existed on macOS long before Linux had anywhere to put a
tab; now that panes hold several surfaces they map straight onto the
model — a "browser tab" is a browser surface inside a pane, switching one
is `selecting`, closing one is `closeSurface`.

Followed macOS where it was already right: `tab.new` resolves its anchor
in the same order (explicit `pane_id`/`target_pane_id` → explicit
`surface_id` → the workspace's focused surface), and the entries keep
macOS's `id`/`ref` wire shape. Deviated in one place on purpose: `index`
is the position **within its pane**, because that is what "tab 2" means
to someone looking at a tab strip — macOS lists browser panels
workspace-wide, which was the only sensible reading when a pane could
hold just one.

One display bug caught in testing: the CLI printed `?` for every ref,
because `formatHandle` expects a `surface_id`/`surface_ref` pair while
these entries use macOS's `id`/`ref`. Worth noting the shape — matching
the macOS wire format is right, and it silently broke a helper that
assumes our own convention.

Verified: list shows index + selection, `new` adds a tab without adding a
pane, `switch` moves the selection, `close` removes only that tab. All
six suites green (61 assertions).

## 2026-07-21 — browser state captured on navigation (not on the 15s timer)

A navigation is not a model change, so browser state used to reach disk
only via the periodic save: quit a few seconds after navigating and the
session file still held the previous URL — exactly when a user expects
their session captured. Browser views now connect `load-changed` and, once
a load commits, record the URL and request a **debounced** save (1.5s;
one navigation emits several load events and this rewrites the whole
session file). Asserted: navigate, quit 3s later, the new URL is on disk.

### The pane-search "regression" that was not one

Right after this change `pane-search-smoke` dropped to 9/11 — both
failures on the terminal side. Chased properly rather than assumed:

- Stashed the change and ran at HEAD: **still 9/11**. Not mine.
- Bisected the binary across four commits (`fc84a441`, `c93a6ae8`,
  `988d0c15`, `4bed15be`) with a minimal repro: **all four failed**,
  including commits that had passed this same suite an hour earlier. Code
  that both passes and fails is not a code regression.
- Root cause: a Ghostty surface spawns its shell on **first map**. A
  selected workspace only maps if the instance's *window is actually on
  screen*; these test instances now open occluded (the host also has two
  qemu VMs at ~300% CPU). Fresh instance: startup workspace's shell came
  up in 1s, a newly created one never did in 60s, and the app log showed
  **zero** lines — the factory never ran, which is deterministic, not slow.

The suite now detects the precondition and **skips those two assertions
loudly**, naming the cause, instead of reporting "search finds nothing in
terminals" — a missing precondition dressed up as a product failure. The
browser assertions need no mapped window and still run.

Worth keeping: the discriminator was that only `pane-search` exercises
terminals at all, so one suite failing while five passed was itself the
clue. And the A/B that settled it only worked because the repro was
reduced to *create workspace → select → poll for shell*, small enough to
run against four binaries.

## 2026-07-21 — Xvfb unlocks visual verification, and immediately finds a bug

`xorg-x11-server-Xvfb` installed. cmux-adw runs under a private X display
and can be screenshotted:

```sh
Xvfb :99 -screen 0 1400x900x24 &
env -u WAYLAND_DISPLAY DISPLAY=:99 GDK_BACKEND=x11 ... cmux-adw &
DISPLAY=:99 import -window root shot.png
```

Both `GDK_BACKEND=x11` **and** unsetting `WAYLAND_DISPLAY` are required —
GTK4 prefers Wayland whenever that variable is set and ignores `DISPLAY`.

This closes the gap recorded in the visual-verification memory: UI can now
be checked without asking the human, and test instances get a
guaranteed-mapped window instead of depending on the desktop's state.

**It found a real bug within minutes.** With four surfaces in a pane
(`surface_count: 4`), the tab strip renders **one** tab, labelled
"Browser" — not the four page titles. Model-level assertions all pass,
because the model is right; only the widget is wrong. Likely cause, to
confirm: the skeleton rebuild `g_object_ref_sink`s and detaches every
surface container, but a container inside an `AdwTabPage` is owned by that
page, so `adw_tab_view_append` afterwards does not take all of them. The
"Browser" label is the same story from the other side —
`tabTitle(for:)` fell through to its default, meaning the registry lookup
for that surface returned nothing at build time.

Worth stating plainly: the human looked at this earlier and said it
"looks quite good already". It does, at a glance — a pane with a tab bar
and a working page. The count being wrong is only visible if you compare
against the model, which is exactly the comparison a screenshot plus a
socket query makes cheap and neither makes alone.

New: [DEPENDENCIES.md](DEPENDENCIES.md) — build, Ghostty, GNOME 49/50,
test and runtime dependencies with the versions developed against and
why each is needed, aimed at a future podman image for other developers.

## 2026-07-21 — root cause of the one-tab strip (found by screenshot)

`surface_count: 4`, one tab rendered. Two independent bugs, both invisible
to model-level assertions because the model is correct:

1. **`detachFromParent` (TerminalSurfaces.swift:385) only knows GtkStack
   and GtkPaned parents.** When a pane has tabs, its surface containers
   live inside the AdwTabView, so on a skeleton rebuild they are *not*
   detached — and the following `adw_tab_view_append` is handed widgets
   that still have a parent, which GTK refuses. Only the one container
   that happened to be unparented becomes a tab.
2. **Tab titles are computed once, at build time.** `PaneTabs.tabTitle`
   runs before a freshly adopted popup has loaded, so both the title and
   URL lookups are empty and it falls back to the literal "Browser" —
   then nothing ever updates it.

Fix direction (deliberately not rushed): the clean answer to (1) is to
stop destroying the AdwTabView on rebuild. Cache it per pane and update
its pages incrementally, so the *tab view* is what gets reparented — and
reparenting a tab view is something `detachFromParent` already handles,
because its parent really is a GtkPaned or GtkStack. Adding an AdwTabView
branch to `detachFromParent` instead is the tempting one-liner and is
wrong: libadwaita's only public page removal is `adw_tab_view_close_page`,
which emits `close-page` — our handler for that closes the *surface*, so
a rebuild would delete the user's tabs. (2) wants a `notify::title` hook
that updates the page title, mirroring the workspace-title path.

Recorded rather than fixed in the same breath because the honest fix
changes how panes are rebuilt, and that is the machinery every other
browser feature sits on.

## 2026-07-21 — one-tab strip fixed: the tab view is now persistent

Verified by screenshot, which is also how the bug was found. Before: four
surfaces, one tab labelled "Browser". After: three surfaces, three tabs
labelled "opener" / "popup-target" / "popup-target", and the view reports
`n_pages == pane.surfaces.count` exactly.

**The fix is architectural, not a patch to `detachFromParent`.** The tab
view is no longer rebuilt with the layout; it is cached per pane
(`PaneTabs.views`) and its pages are *reconciled* against the model —
close what is gone, append what is new, reorder, retitle, select. What
gets reparented across a layout rebuild is therefore the wrapper box,
whose parent genuinely is a GtkPaned or the GtkStack, which
`detachFromParent` already handles. The surface containers never leave the
tab view at all.

Adding an AdwTabView branch to `detachFromParent` was the tempting
one-liner and would have been a worse bug: libadwaita's only public page
removal is `adw_tab_view_close_page`, which emits `close-page`, and our
handler for that closes the **surface** — a rebuild would have deleted the
user's tabs. Programmatic removal now sets `PaneTabs.isReconciling`, which
both the close-page and selection handlers check, so model-driven page
changes are never mistaken for user actions.

Second bug, independent: tab titles were computed once at creation, when a
freshly adopted popup has neither title nor URL, so they read the literal
"Browser" forever. Titles now refresh on every sync *and* from the browser
view's own `notify::title` — the workspace title only follows the focused
surface, but a tab label has to update whichever surface it belongs to.

Two things worth keeping from the diagnosis:

- The trail ran through three wrong guesses before instrumenting.
  Logging the append (`parent=`, append-failed, and `n_pages` vs
  `surfaces.count`) settled it in one run. **Instrument earlier when a
  widget and a model disagree** — neither side's logs alone can show it.
- The final "still missing one tab" was not a bug at all: AdwTabBar keeps
  a minimum tab width and *scrolls*, so a ~405px pane shows three of four.
  `n_pages` is the authoritative check; pixel-counting tabs is not.

Also: `pkill -f "Xvfb :99"` killed the running shell — `pkill -f` matches
the agent's own command line, which INSIDE-CMUX.md already warns about and
which bit again here. Kill by exact name (`pgrep -x`) instead.

All six suites green: webdriver 9/9, navigation 8/8, popup 12/12,
search 11/11, find 11/11, session 11/11.

## 2026-07-21 — test harness refactor: lib.sh, run-all.sh, Xvfb everywhere

Six suites each carried ~50 lines of duplicated setup, teardown and
port-freeing, and every lesson learned had to be applied six times (or,
in practice, to whichever copy was being edited). They now share
[`lib.sh`](../../linux/tests/lib.sh):

- `start_instance` / `kill_instance` (by `CMUX_APP_ID` in
  `/proc/<pid>/environ`, never `pkill -f`), `start_fixture_server`
  (`--directory`, no wrapper subshell), `free_port`, `cx`, `expect`,
  `wait_for_shell`, `first_surface_ref`, `screenshot`.
- **Every suite runs on its own Xvfb display**, derived from its fixture
  port. This is the substantive change: a Ghostty surface spawns its shell
  on first *map*, so terminal assertions previously depended on whether
  the test window happened to be visible on the human's desktop.
  `pane-search-smoke` now passes 11/11 with **no skips**, where on the
  real desktop its two terminal assertions had to be skipped.
- `skip` counts separately from pass and fail, so a missing precondition
  can masquerade as neither.

`run-all.sh` runs all six sequentially (parallel is how the
"shell never spawned" flake appears on a loaded machine) and separates
assertion failures from setup errors. One command, one summary:
**62 assertions passed, 0 failed, 2m34s.**

Sizes: `browser-find-smoke.sh` went 121 → 66 lines; the boilerplate is
gone from all six.

Two self-inflicted bugs while doing it, both worth recording because they
are the *same* mistake in different clothes:

- A regex written to delete the suite's old `cleanup() {` matched
  `cleanup() {` inside the **`suite_cleanup() {`** I had just added, and
  ate the file from there. Identical in shape to the earlier
  `s.index()` truncation of BrowserSurfaces.swift: a pattern that matches
  more than the one place you pictured. Restored from git and redone with
  an anchor that could not match the new text.
- `local extra=("${INSTANCE_ENV[@]:-}")` expands an *unset* array to one
  **empty word**, so every suite that did not set it ran
  `env "" nohup cmux-adw` and died with `env: '': No such file or
  directory`. It looked like four suites breaking at once; it was one
  character of bash semantics. `[ -n "${INSTANCE_ENV+x}" ]` guards it.

Both were caught because the suites are run after every change, which is
the point of having them.

## 2026-07-21 — divider positions persist (fraction, like macOS)

First of the four remaining gaps, taken first because it was the smallest
and because it proves the v3 schema extends without another migration.

Stored as a **fraction** of the paned's extent rather than pixels — the
same choice macOS makes (`SessionSplitLayoutSnapshot.dividerPosition`,
read back as `min(max(…, 0), 1)`). A pixel offset restored into a
differently sized window is simply wrong, and the window is routinely a
different size next launch.

Two pieces of existing machinery made this small: the in-session rebuild
already keys divider positions by tree path (`""`, `"0"`, `"01"`…), so
the persisted map reuses that scheme and the two cannot drift; and
`balanceFreshDividers` already solved the awkward part — a fresh paned
reports extent 0, so the position cannot be set at build time — with a
tick callback that retries until allocation. The restored fraction rides
the same callback instead of its hardcoded `total / 2`.

`dividerPosition` is **optional**, so v3 files written before this still
decode; asserted, because silently discarding a session over a new field
would be a bad trade for a cosmetic feature.

Verified end to end: 0.5 → browser pane 404px, 0.25 → 609px, on the same
window. `resize-pane` is not implemented on Linux (PARITY ❌), so the
drag could not be simulated through the socket — the test edits the
persisted fraction and measures the result instead, which exercises the
restore path that is actually new.

Suites: 65 assertions, 0 failed (session-persistence now 14).

## 2026-07-21 — the dev launcher was deleting its own session every start

Reported by the human: launching "cmux (dev)" from the desktop forgets all
panes. Not a session-restore bug — `start.sh` did this on every start:

```sh
rm -f "/tmp/cmux-$slot.sock" "/tmp/cmux-$slot-session.json"
```

The session file was wiped by construction, so the instance could never
restore anything. That was defensible while `dev` was a throwaway
verification instance where a clean slate is the point; it became wrong
the moment the desktop launcher turned it into somebody's environment.
Only the stale socket is removed now, the session lives in
`~/.local/state/cmux/dev-session.json` (out of `/tmp`, which is cleared on
reboot), and `start.sh dev --fresh` restores the clean-slate behaviour for
a test run. The existing `/tmp` session was copied over rather than
dropped.

Two related things the report surfaced, worth stating because both look
like the same symptom:

- **The dev instance never shares the daily's session.** Separate
  `CMUX_APP_ID`, socket and session file — that is the isolation the whole
  dev-instance pattern depends on. Launching dev will never show the
  daily's panes, by design.
- **Session restore does not restore processes.** It restores layout,
  working directories and browser state (URL, history, zoom). A restored
  shell is a *new* shell; the previous tty and whatever was running in it
  are gone. macOS is the same, and additionally persists scrollback *text*
  — the gap tracked in PARITY, and the reason a restored macOS pane at
  least still shows what was on screen. Nothing restores a live process.

Also confirmed while checking: the human's daily session file is intact
and still schema v2, because the daily runs the pre-v3 binary. It migrates
on their next restart — the migration path is asserted.

## 2026-07-21 — pane zoom (macOS "Toggle Pane Zoom")

Second of the four. Ctrl+Shift+Z, a toolbar button, and `cmux zoom-pane`
(`pane.zoom`) — macOS has the command but no socket verb, so this is the
now-familiar pattern: expose UI features over the socket too, which makes
them testable without a screenshot and usable by an agent.

Implementation is a single model field, `TerminalTab.zoomedSurfaceId`.
When set, `sync()` builds only that pane instead of the split tree; the
other containers stay unparented but alive (the registry holds strong
refs), so un-zooming puts them back rather than respawning shells. Zoom is
part of the skeleton signature, or toggling would not rebuild.

Two behavioural choices worth recording:

- **Zooming a different pane switches to it** rather than un-zooming.
  "Zoom this one" is the intent; un-zooming would cost a second keystroke
  to get where the user asked to go.
- **Zoom is deliberately not persisted.** It is momentary "let me see
  this" state, and restoring into it would hide panes the user had
  forgotten they had. Asserted, so a future session-schema change cannot
  quietly start persisting it.

Verified geometrically and visually: browser pane 404px → 818px → 404px,
and the screenshot shows the pane filling the content area with the
terminal gone. New suite `pane-zoom-smoke.sh` (7 assertions) — noticeably
short because `lib.sh` now carries the setup; it also exercises the
`screenshot` helper as a real assertion.

Suites: 7 suites, 72 assertions, 0 failed.

## 2026-07-21 — Ghostty panes track their working directory again

Reported by the human: after the launcher fix, panes and browser state
restore correctly but Ghostty panes reopen in the wrong directory.

Not a session bug. Ghostty reports the cwd with
`OSC 7 file://$HOSTNAME$PWD` and validates the host against
`gethostname()` before trusting it — deliberately, since any remote shell
can send OSC 7 (`stream_handler.zig`: *"OSC 7 is a little sketchy because
anyone can send any value from any host (such an SSH session). The best
practice terminals follow is to validate the hostname to be local."*).
`isLocal` accepts only `"localhost"` or an exact `gethostname()` match.

On this host:

```
gethostname()  fedora-13.fritz.box
$HOSTNAME      fedora            ← stale, inherited
```

so every report was rejected — `warning(io_handler): OSC 7 host (fedora)
must be local`, once per prompt — and the pane's `pwd` property never
updated, so the session stored the spawn directory forever.

Measured rather than assumed: **bash sets `HOSTNAME` itself, but only when
it is not already in the environment.** `env -i bash -c 'echo $HOSTNAME'`
gives the correct FQDN; `env HOSTNAME=stale bash -c …` gives `stale`. A
desktop session started before the machine was renamed therefore poisons
every shell beneath it, indefinitely.

Fix: cmux passes the real hostname to the shells it spawns, alongside the
`CMUX_*` identity vars it already sets. That repairs the cause and leaves
Ghostty's security check alone — relaxing `isLocal` was the other obvious
option and would have traded a real protection for a convenience.

Verified against the exact failing condition: the app started with a
deliberately stale `HOSTNAME=fedora`, then `cd /etc` in a pane →
**zero** OSC 7 rejections and `/etc` recorded in the session. Two
assertions added, including one on the rejection count so a future
regression shows up as the warning it really is.

(One bash trap on the way: `grep -c` prints `0` *and* exits non-zero when
there are no matches, so a `|| echo 0` fallback yields `"0\n0"`.)

Suites: 7 suites, 74 assertions, 0 failed.

## 2026-07-21 — browser address bar

Third of the four. Until now a browser pane could only be pointed
somewhere by `cmux browser goto` or by following a link — a human could
not type a URL into it, which macOS panes have always allowed.

The interesting part is not the widget but the resolver, and it is
**macOS's own rules ported deliberately rather than approximated**
(`resolveBrowserNavigableURL`), because the awkward cases are where two
implementations drift:

- `localhost:3000` / `127.0.0.1:8080` are checked *before* generic URL
  parsing, since `URL("localhost:3777")` reads `localhost` as a **scheme**
  — and they resolve to `http`, not `https`;
- anything containing a space is a search, never a URL;
- a bare `example.com` is promoted to `https`;
- a scheme we do not navigate (`javascript:`, `data:`) resolves to
  nothing rather than being loaded.

Non-URL text falls through to a search engine. macOS keeps the engine in
user defaults; Linux has no settings surface yet, so it is `CMUX_SEARCH_URL`
with the same default rather than a hardcoded choice nobody can change —
and the test points it at a local fixture, so a suite run never contacts a
search engine.

The bar mirrors navigations driven from anywhere (it rides the same
`load-changed` handler added for session capture) and refuses to overwrite
the entry while it has focus, so a page load cannot eat what someone is
typing.

**Tested by actually typing into it.** `xdotool` drives real clicks and
keystrokes on the suite's private X display, so the assertions cover the
widget and the resolver together — asserting on the resolver alone would
have tested the easy half. Verified: typed `127.0.0.1:8419/a.html` with no
scheme → `http://…`, a non-URL query → the fixture search URL.

New suite `browser-urlbar-smoke.sh` (5 assertions). 8 suites, 79
assertions, 0 failed.

## 2026-07-21 — the browser pane had no way in

Prompted by the human asking whether macOS has an "open browser pane"
feature. It does — and surveying the whole command surface turned up a
sharper problem than the one asked about.

**macOS binds 28 keyboard commands; Linux bound 6.** More to the point,
several macOS commands map onto verbs Linux *already had*, with no way to
reach them from the keyboard or the UI at all:

| macOS command | Linux verb | reachable? |
|---|---|---|
| Open Browser, Split Browser Right/Down | `browser.open_split` ✓ | no |
| Toggle Browser Developer Tools | `browser.inspect` ✓ | no |
| Next / Previous Workspace | `workspace.next/previous` ✓ | no |
| Rename Workspace | `workspace.rename` ✓ | no |

So the browser pane, the Web Inspector pane, the tab strip, find-in-page
and the address bar were all built and tested — and a person sitting in
cmux could not open a browser pane without dropping to the CLI. The
capability was finished; the way in was never wired. Worth remembering as
a category: *building the verb is not shipping the feature*, and a
verb-level test suite cannot notice the difference.

Bound now: **Ctrl+Shift+B** opens a browser pane (splitting along the
longer axis, so it does not shred the layout) and **Ctrl+Shift+I** opens
DevTools for a focused browser pane, both with toolbar buttons. DevTools
is a no-op on a terminal pane rather than an error.

Verified by driving the real keys with xdotool on the private display:
1 pane → Ctrl+Shift+B → 2 panes with the new one a browser at
`about:blank` → Ctrl+Shift+I → 3 panes with "inspector widget placed" in
the log, and a screenshot showing terminal, browser-with-address-bar and
the DevTools pane (Elements/Console/Graphics) side by side.

Still unbound but cheap, since the verbs exist: next/previous workspace,
rename workspace. Not implemented at all: directional pane focus
(`focusLeft/Right/Up/Down` — needs geometry-aware logic and pairs with the
`surface.focus` ❌ in PARITY), next/prev surface, jump-to-unread, open
folder, JS console, flash, multi-window.

8 suites, 79 assertions, 0 failed.

## 2026-07-21 — workspace and pane navigation shortcuts

The cheap half of the command-surface gap: **Ctrl+Shift+PageDown/PageUp**
for next/previous workspace (the `workspace.next/previous` verbs existed
unbound) and **Ctrl+Tab / Ctrl+Shift+Tab** to cycle the focused pane
(new `stepFocusedSurface`, which walks *every* surface including
background tabs so a tabbed pane is not treated as one).

Cycling a surface also selects its tab, so stepping through a tabbed pane
actually shows each page rather than silently focusing something hidden.

**One binding did not work and the reason is worth keeping:** the first
attempt used Ctrl+Shift+`]`. With Shift held, that key produces
`braceright`, not `bracketright` — so the accelerator never matched what
was actually pressed. It failed silently, exactly like a feature that
was not wired at all. Ctrl+Tab has no such ambiguity. Any shortcut whose
key changes glyph under Shift needs the shifted keysym, or a different
key.

Caught only because the shortcuts were driven with real key events under
xdotool; a unit test of the handler would have passed.

macOS binds 28 commands, Linux now binds 12. The remainder is written up
in CATCHUP as an explicit to-do, split into "needs a small dialog"
(rename workspace) and "real work, no verb yet" (directional pane focus,
jump-to-unread, open folder, JS console, flash, multi-window).

8 suites, 79 assertions, 0 failed.

## 2026-07-21 — terminal scrollback survives a restart

Fourth and last of the gaps. A restored pane now shows what was on it.

**The unknown resolved in an unexpected direction.** The worry was that
Ghostty offered no way to put text on a terminal without it reaching the
shell: every termio message is a *write*, which goes to the pty and is
handed to the child as input — replaying a user's own history that way
would execute it. Reading the code found `Termio.processOutput`, the
entry point the pty read loop already uses, but no message routed to it.

So the fork gained one (`ghostty` `1bda2cc75`, branch `linux-gtk-embed`):
`inject_output` carries owned bytes to the io thread, whose handler calls
`processOutput`. Threading is correct **by construction** — it runs
exactly where the read loop already runs, so the parser is still driven
from one thread and no new locking appears. The shim exports it as
`ghostty_embed_surface_write_display`, beside the existing `send_text`
(pty) and `read_text`.

That makes the Linux path cleaner than macOS's, which writes the text to
a temp file, passes its path in the child's environment, and relies on
shell integration to print it at startup. No temp file, no environment
variable, no dependence on the user's shell — and no route by which the
text could reach the shell as input. Asserted directly: after a restart
the marker is on screen **and** there is no "command not found", which is
what a send_text replay would have produced.

Two macOS decisions copied rather than rediscovered
(`SessionPersistencePolicy`): truncate to a per-terminal budget, because
the session file is rewritten on every structural change; and truncate
**ANSI-safely**, because a cut landing mid escape sequence replays
malformed control bytes into a fresh terminal. The replayed block is also
wrapped in a reset so captured text ending mid-colour cannot bleed into
the first prompt.

Only the visible screen is stored, not full history — `read_text` can
return the whole buffer, and persisting megabytes per pane on every save
would be the wrong trade.

Restore is retried: a Ghostty surface has no terminal until it is first
mapped, so a background workspace may not be able to accept the replay
for some time. It retries for ~10s, then drops the text rather than
holding the expectation forever.

session-persistence-smoke is now 19 assertions; 8 suites, 82 total, 0
failed.

## 2026-07-21 — scrollback moved out of the session file; the limit is now a setting

Asked for: a configurable cap, up to "keep everything". Measuring first
showed why the cap existed, and that raising it naively would have been
harmful.

**The cap was compensating for where scrollback lived.** Inline in
`session-linux.json`, which `saveIfChanged` rewrites on every model
change — so *every line of terminal output* made the document dirty and
triggered a full rewrite. The dev session file was already **327 KB** per
save storing only the visible screen. Uncapped, with Ghostty's default
10k-line buffer, that is megabytes rewritten many times a minute.

Scrollback now lives in one file per surface next to the session
(`<session dir>/scrollback/<uuid>.txt`), written only when that surface's
text actually changed and pruned when the surface disappears. Measured:
session JSON **327 KB → 1158 bytes**, with the text in a 15 KB sibling.
A pane that is not scrolling now costs nothing per save, which is what
makes a large limit affordable.

`CMUX_SCROLLBACK_LIMIT` sets the budget; **0 keeps everything**. Measured
against 3000 lines of output: 4k → 816 lines, 64k (default) and unlimited
→ all 3023.

Two things the implementation had to get right, neither obvious:

- **The read, not just the write, needed bounding.** Change-gating the
  write leaves a full-buffer copy happening on every model change.
  Capture is throttled to once per 2s per surface; otherwise raising the
  limit would move the cost from writing to reading rather than removing
  it.
- **"Limit" had a cliff.** The first version only read history when the
  budget exceeded the default, so 64k kept the visible screen (30 lines)
  while 65537 kept 3000. Fixed by always reading history and letting the
  limit bound it — a limit should say *how much is kept*, not switch
  capture modes.

Sessions written earlier today still carry scrollback inline; restore
prefers the file and falls back to the inline value, so the first upgrade
loses nothing.

Next for this feature: an XDG config file (so the setting is not
env-var-only) and a preferences window — adwaita-swift already binds
`PreferencesPage`/`SwitchRow`/`SpinRow`/`ComboRow`, so the UI needs no
shim, and `CMUX_SEARCH_URL`, `CMUX_TERM` and this limit give it three
real settings on day one.

8 suites, 83 assertions, 0 failed.

### Scrollback replay into workspaces nobody has opened yet (2026-07-21)

Reported after the feature landed: *"i had a split one at the right side
of the first tab and both horizontal ones had no content"*. The split
turned out to be a red herring — a split alone replays fine. What
actually decided it was **whether the workspace was selected at restore**.
The workspace holding the empty panes was a background one.

Root cause, in two layers:

1. **The text was thrown away.** A pane in an unselected workspace is
   never mapped, so its terminal never starts. The replay polled for ~10s
   and then *discarded* the pending text — so any workspace not opened
   within ten seconds of a restart came back empty forever, while its
   scrollback file still sat on disk holding the content.
2. **Keeping the text was not enough.** The obvious follow-up — keep it,
   and retry once whenever the view syncs — still failed, and the fix was
   verified as not working before it shipped. The sync runs *before* GTK
   has mapped the newly shown pane, so the single retry always missed.

Replay is now a **restartable poll**: each view sync starts a fresh
~10s chain for any surface still holding text (guarded by a `polling` set
so a burst of syncs cannot stack chains), and giving up ends the chain,
never the text.

One more trap found on the way: `ghostty_embed_surface_write_display`
returns success as soon as the *core surface* exists, which happens well
before the pane is mapped. The bytes are queued into a terminal that has
not started and are simply lost — a success the caller believes. Replay
therefore gates on `gtk_widget_get_mapped` first, which is the real
"there is a terminal here" signal.

Verified end to end, and the negative direction too: with the original
discard reinstated the new assertion fails (`expected '2', got '0'`), so
the test genuinely guards the regression rather than merely passing.
`session-persistence-smoke` now covers both split panes of a workspace
first opened 15s after the restart, plus a re-selection check that the
text is not replayed twice.

Note for later: only Ghostty panes capture and replay scrollback —
`ghosttyReadText` returns nil for VTE surfaces, so under the VTE backend
this feature is simply absent (not broken).

### The staircase, and output lost at close (2026-07-21)

User report with screenshot: after `ls`, close, reopen, the replayed
listing came back as a staircase — every line starting where the previous
one ended — and sometimes came back not at all. Two distinct bugs.

**The staircase: LF without CR.** `read_text` returns clipboard-shaped
text, rows joined with bare `\n`; `inject_output` hands those bytes to the
terminal parser, where LF means "down one row" and nothing else. macOS
never meets this bug because it replays through the pty, whose line
discipline (`ONLCR`) rewrites LF→CRLF on the way out — the trick it gets
for free by the route it takes. Bypassing the pty is what makes our path
simpler and safer; the CR is the bill for it. `replayPayload` now
normalizes LF→CRLF (collapsing CRLF first so it is idempotent; a lone CR
is left alone — in captured output that is column-0 movement the writer
meant).

**Output lost at close.** Terminal output is not a model change, so a
pane's text reached disk only on the 15s periodic pass — run `ls`, close
the window, reopen, and the pane misses its last seconds. Same shape as
the browser-navigation capture bug fixed on 07-20, now on the terminal
side. Fixed with a `close-request` hook on the window that runs one final
save while the terminals are still alive (an application-`shutdown` hook
would read every pane as already destroyed), with the scrollback read
throttle bypassed for that save only (`capture(force:)`) — being 2s stale
is fine when another save follows, and fatal when none does.

Two more findings from verifying it:

- **`xdotool windowclose` is not a close.** It calls `XDestroyWindow`,
  which never sends `WM_DELETE_WINDOW`, so GTK's `close-request` never
  fires and the hook looked broken while being merely untested. The A/B
  harness (and now the suite) sends a real WM_DELETE ClientMessage via a
  20-line C helper (`tests/helpers/wmdelete.c`) — the same close a window
  manager's ✕ performs.
- **`ScrollbackStore.write(nil)` deleted good files.** "Could not read"
  (shell not started, widget tearing down) was treated as "pane is
  empty", removing the very file that would have restored the pane. Now
  only a surface that genuinely reports text may retire its file.

Verified causally, not just green: A/B with the identical binary
(`CMUX_DISABLE_EXIT_SAVE=1` as the control arm), closing 1s after `ls` —
with the hook, output not yet on disk at close time was rescued (3/3
firings logged); without it, the run that had nothing on disk stayed
empty, which is precisely the reported bug. Suite: 8 suites green,
session-persistence now 25 assertions including the polite-close round
trip and a column-0 (un-staircased) check.

## 2026-07-21 — trailing `--json` leaked into the browser URL

`cmux browser open https://news.ycombinator.com --json` navigated to the
literal URL `https://news.ycombinator.com --json` — WebKit showed "Die
Adresse kann nicht angezeigt werden" and the flag was silently eaten.
Found live while dogfooding article summarization.

Root cause: global flags (`--json`, `--id-format`) are only parsed
*before* the command word; anything after lands in `commandArgs`, and
`browser open`/`goto` join their leftover args into the URL string with
spaces. The skill docs (`skills/cmux-browser/SKILL.md`) show trailing
`--json` as the canonical form, so this was a real usage path, not abuse.

Fix in `CLI/cmux.swift` (shared source, builds on both platforms):

- `runBrowserCommand` now strips `--json` and `--id-format <v>` from its
  args the same way it already stripped `--surface`, honoring the `--`
  terminator, so every browser subcommand accepts trailing output flags.
- `open`/`open-split`/`new` and `goto`/`navigate` reject any leftover
  `--…` token with "unknown flag" instead of joining it into the URL —
  a typo now errors instead of navigating somewhere broken.

Verified against the live instance: trailing `--json` returns JSON with a
clean URL, `--jsn` and `--snapshot-after-typo` error out client-side
(no split created), leading-flag form unchanged. Also confirmed
"multiple browser surfaces" disambiguation still works — the second
browser pane in the workspace was the human's, not a stray.

### The catch-up merge: 5657 commits, and upstream's CLI ported (2026-07-22)

The fork's `main` had drifted since the port began. The dry-run assessment
found the merge itself cheap — seven conflicting files across 5657
incoming commits, everything else disjoint — but one conflict hid the
real bill: `CLI/cmux.swift`, shared into the Linux build by symlink, had
grown upstream from one 14k-line file into **85 files / 62k lines**
importing four internal packages and a stack of Apple frameworks. The
user chose the full port over decoupling, and it landed the same night:
the complete upstream CLI now builds and runs on Linux, and all 8 suites
(88 assertions) pass with it driving our server.

What the port actually consisted of, roughly in effort order:

1. **Hunk resolution** (21 in cmux.swift). Upstream's rewritten socket
   client won wholesale — EINTR-safe writes, per-verb response timeouts.
   Our Linux verbs (`search`, `zoom-pane`) and navigation-barrier flags
   survive beside upstream's new dispatch. `--background` restored as an
   alias of `--focus false` (every suite and agent uses it).
2. **Package wiring.** CmuxFoundation, CmuxSettings, CMUXAgentLaunch,
   CmuxControlSocket into linux/Package.swift; swift-crypto replaces
   CryptoKit off-macOS (conditional dependency, macOS graph untouched).
3. **Mechanical guards** across ~60 files: `import Darwin` → Glibc,
   os/OSLog/Security/SQLite3 behind canImport, explicit CoreFoundation
   imports (macOS's Foundation re-exports it; corelibs doesn't).
4. **Compat layers**, one file per package: `Darwin.`-qualified syscall
   shims, OSAllocatedUnfairLock over NSLock, a no-op OSLog Logger that
   still type-checks `privacy:` interpolations, and
   `String(localized:defaultValue:)` returning the development string —
   corelibs has no String.LocalizationValue at all.
5. **Real ports, not stubs**: peer credentials via SO_PEERCRED +
   /proc/<pid>/stat ancestry walk (same security boundary as Darwin's
   LOCAL_PEERCRED + sysctl), process introspection via /proc,
   SecRandomCopyBytes → getentropy, kqueue/DispatchSource file- and
   process-watches → polling twins, and a Linux FileWatcher actor
   (mtime polling) so settings hot-reload still works.
6. **Server/ and Coordinator/ compile out** — those trees are the mac
   app's side of the socket; Linux has its own (ControlProtocol.swift).
   That also dropped the lone @Observable, dodging a Fedora toolchain
   quirk (libswiftObservation leaves swift::threading::fatal undefined;
   `--allow-shlib-undefined` matches what plain swiftc accepts).

Traps that cost a round each, worth remembering:

- **The pbxproj is the authority on what a shared target compiles.**
  `JSONCParser`, `RemoteRelayZshBootstrap` and five more live in
  `Sources/`, not `CLI/` — the Xcode CLI target compiles them in. And
  parsing the pbxproj with a 24-hex id regex silently missed the
  entries with 8-char ids; the "missing symbol" errors were the tell.
- **An unpinned transitive dependency broke a pinned one.**
  adwaita-swift references `meta` by branch; a fresh resolve picked up
  a meta where `blockUpdates` went internal, breaking the pinned
  adwaita-swift revision. The main tree never noticed — its cached
  checkout was old. linux/Package.resolved is committed from now on.
- **VTE-only builds had silently rotted** — scrollback code called
  ghostty* helpers unconditionally; always building CMUX_GHOSTTY=1 hid
  it. Honest no-op fallbacks restore the VTE build.

macOS is untouched: every change is behind canImport/os guards, in
Linux-only compat files, or under linux/. The macOS build itself cannot
be verified from this machine — noted for the next VM run.

### Browser profiles (2026-07-22)

roadmap/07, first feature built against the freshly merged upstream: the
CLI half (`browser profiles list/create/rename/clear/delete`, payloads,
slugs) already existed in the shared binary — the Linux side only had to
answer it. `BrowserProfiles.swift` keeps one `WebKitNetworkSession` per
profile (that sharing is what makes a profile one container), the
built-in default maps to WebKit's default session so pre-profile state
stays put, and the store/data live beside the session file so test
instances are isolated for free. Panes join a profile via
`browser open --profile <slug|id|name>` — a Linux-port extension flag
(macOS selects via the pane popover; agents need a flag), candidate for
upstreaming. Popups inherit the opener's session through `related-view`
and the assignment record follows. v3 snapshots carry `profile` per
browser surface; absent = default, old files decode unchanged.

Three findings, each worth its LESSONS weight:

- **The construct-only race, relearned.** The profile assignment was
  parked *after* `split()` returned — but mutating the tab layout can
  re-render and run the surface factory before `split()` returns, so
  every profiled pane silently landed in the default session. The
  adoption code had learned exactly this and documented it ("observed
  exactly that way"); `split()` now takes the same pre-mutation
  `prepare:` hook. Isolation testing is what caught it: the *other*
  pane seeing the cookie was the only assertion that failed honestly
  while four others passed by accident.
- **Session cookies don't persist — by design.** `document.cookie`
  without `max-age`/`expires` is a session cookie; no browser writes it
  to disk. The restart assertion failed against perfectly correct code
  until the fixture set `max-age`. Cookies *do* need
  `webkit_cookie_manager_set_persistent_storage` on a custom session
  (the data directory alone only covers storage/cache) — verified both
  ways against cookies.sqlite.
- **`clear`/`delete` require the profile's panes closed** (macOS clears
  live stores; our stricter rule keeps "cleared" meaning cleared) — and
  delete of the built-in default is refused, mirroring upstream.

Suite: browser-profile-smoke.sh, 14 assertions — CRUD + slug rules,
cookie isolation, same-profile sharing, popup inheritance, delete guard
rails, and the restart round trip (3 work panes + 1 default pane each
back in their own container, cookies intact).

Noticed while debugging, parked: after a session restore, `list-panes`
with no --workspace reports "Workspace not found" until a workspace is
explicitly selected — pre-existing selection-resolution quirk, suites
always pass --workspace.

### VTE scrollback parity (2026-07-22)

Scrollback persistence now works under both terminal backends. The
dispatch is backend-neutral (`SurfaceRegistry.scrollbackText` /
`writeDisplay` / `readyForReplay`): Ghostty surfaces keep the fork's
`inject_output` and map-gating; VTE surfaces capture the whole retained
buffer via `vte_terminal_get_text_range_format` (range from the vertical
adjustment's `lower` — read as the GtkScrollable interface *property*,
since CVte's view of GTK has no GtkScrollable cast type — to the cursor
row) and replay via `vte_terminal_feed`, VTE's exact analog of
inject_output: parsed as output, never handed to the shell. VTE
terminals are ready at creation, so the restartable-poll machinery just
succeeds on its first attempt there.

The suite initially reported the replay broken while it worked: the
marker had scrolled 200 lines up, and VTE's `read_text` was
viewport-only (a documented PARITY gap). Closing the gap —
`scrollback:true` now returns the full retained buffer on VTE too — made
the assertion honest and removed a real limitation in one move.

vte-scrollback-smoke.sh (CMUX_TERM=vte instance): capture beyond the
viewport, replay after restart, column-0 check, not-executed check.
The LF→CRLF normalization carried over untouched — it lives in the
backend-neutral `replayPayload`, exactly as hoped when the staircase
was fixed.

### Settings file + preferences window (2026-07-22)

The three env-var-only settings now persist. Storage is the same file
macOS uses — `~/.config/cmux/cmux.json` — under a `"linux"` object so the
schemas can never collide and one dotfiles repo serves both platforms.
Resolution order is **environment > file > default**, deliberately:
every suite and script depends on an explicit `CMUX_SCROLLBACK_LIMIT=0`
beating whatever the file says. The file is re-read mtime-gated on
access, so external edits (hand, dotfiles sync) apply without a watcher,
and the preferences window writes through the same type.

The window (Ctrl+comma / gear button) is raw libadwaita C —
adwaita-swift binds the preference rows but not `GtkScale`, and the
scrollback budget genuinely wants a slider. It got one: marks at
16 KB / 64 KB / 256 KB / 1 MB / 8 MB / All (a linear byte axis is
useless across three orders of magnitude; the slider moves across
presets). Off-preset values from a hand-edited file snap to the nearest
stop. Terminal backend is a ComboRow (Ghostty/VTE, "applies to the next
launch" — the Ghostty runtime initializes once); search URL an EntryRow
applying to the next search. Screenshot-verified under Xvfb.

settings-smoke.sh: file limit bounds capture (4096 → 4096-byte file),
backend=vte keeps Ghostty uninitialized, CMUX_TERM env beats the file,
window opens on Ctrl+comma, config file never clobbered by reads.

Note for CAdw work: interface types (GListModel) have no struct in
CAdw's view — pass what CAdw's own functions return directly instead of
casting through the system headers' names.

### Keyboard reachability: five commands a person could not press (2026-07-22)

CATCHUP item 5, the "what can a person actually reach" list:

- **Directional pane focus** (Ctrl+Shift+arrows) — nearest pane by real
  widget geometry (`gtk_widget_compute_bounds` against the window root;
  axis distance primary, cross-axis drift as tie-breaker ×2 so "left"
  never jumps diagonally past a straight neighbor). List order cannot
  express "the pane to the left" once splits nest. No-op under zoom.
- **surface.focus** (parity verb) — selects the workspace, raises the
  pane tab when the surface is a background tab, moves focus. The
  focus-grab itself rides the existing view-sync (one mutation path).
- **surface.trigger_flash** (parity verb + `cmux trigger-flash`) — a
  double opacity dip on the pane container; reads clearly on terminals
  and browsers without any CSS machinery.
- **Rename workspace** (Ctrl+Shift+E) — AdwAlertDialog with a prefilled
  entry, Enter activates Rename; same pinned-custom-title path as
  `workspace.rename`. NOT F2: the focused terminal legitimately consumes
  function keys, so an F2 window shortcut simply never fires —
  discovered by pressing it under Xvfb and watching nothing happen.
  `adw_dialog_set_focus` before present, or typing goes to the terminal
  behind the dialog.
- **Jump to unread** (Ctrl+Shift+U) + **Open folder as workspace**
  (Ctrl+Shift+O, GtkFileDialog folder picker).

All bound at the window level (`Window.keyboardShortcut`) — no chrome
buttons; these are muscle memory, not discoverable UI.

**The regression the suite caught for free:** `cmux notify` had silently
stopped working since the catch-up merge — upstream's CLI now sends
`notification.create_for_caller`, a method our server never implemented.
Every agent Stop/Notification hook was failing quietly. Implemented with
caller/preferred-workspace resolution + desktop delivery; the
jump-to-unread test was the tripwire. Protocol drift of exactly this
kind is worth a capabilities sweep against the merged CLI at some point.

ui-commands-smoke.sh: 8 assertions, all keyboard paths driven by real
xdotool keystrokes.

### promote.sh: the binary-promotion checkpoint, wrapped (2026-07-22)

Promotion used to be a hand-run ritual (verify on dev, announce, human
restarts). `linux/scripts/promote.sh` wraps it: build → optional suite
(`--test` refuses to promote a red build) → force a `session.save` (new
socket verb with final-save semantics, so scrollback is captured
unthrottled even though the stop is a SIGTERM, which never runs the
close-request exit save) → stop the target by environ match → start via
start.sh. Restore brings everything back; `claude --continue` resumes
the session.

Self-hosting guard: the script identifies the shell's own instance by
socket and refuses to promote the instance it lives in — tested both
ways (simulated inside-dev shell refused; this session's real shell
would be refused for daily). `--slot dev2` runs the identical code path
against a disposable instance, which is how the script itself was
verified end-to-end (marker survived the promote).

### The capabilities sweep: hunting quiet renames (2026-07-22)

The notify regression (create_for_caller) proved the class exists, so
the whole surface got swept: every v2 method the merged CLI can put on
the wire, diffed against every method the Linux server dispatches —
`linux/scripts/capabilities-sweep.py`, committed so every future merge
re-runs it.

Result: 212 sendable methods, 150 initially missing. Classified:

- **Quiet breaks of claimed features, now fixed (9):**
  `browser.devtools.toggle` (the `browser devtools` alias silently died
  while `browser inspect` still worked — aliased to the same handler),
  `notification.jump_to_unread` / `mark_read` / `dismiss` / `open`
  (CLI commands `jump-to-unread`, `mark-notification-read`,
  `dismiss-notification`, `open-notification` — the internals existed
  since the shortcut work; only the wire names were missing),
  `browser.zoom.set` (`browser zoom in|out|reset`, riding the existing
  zoom persistence), `window.current` + v1 `current_window`, and
  `settings.open` (`cmux settings open` → the preferences window).
- **Relief:** bare `cmux <dir>` sends `workspace.create` — the headline
  open-directory flow was never broken. `file.open`/`project.open` are
  macOS file/Xcode openers, honestly erroring.
- **Honestly missing, not renames (~140):** vm.*, remotes.*,
  workspace.group.*, workspace.remote.*, canvas.*, feed.*, auth.*,
  layout.*, screencast/trace/network route — macOS features the port
  has never claimed. The unknown-method error is the correct answer
  until each is built.

ui-commands-smoke grew the verb round trip (mark/open/dismiss, zoom,
devtools alias): 13 assertions.

### The sweep's blind spot: v1 verbs (2026-07-22)

Exercising the upstream `/cmux` skill against the port immediately hit
two commands the v2 sweep had declared clean: `list-windows` and
`reload-config` both speak **v1** — plain socket lines via
`sendV1Command`, a dimension the sweep never scanned. Fixed five:
`list_windows` (single window until the multi-window phase),
`reload_config` (invalidates the settings cache; honest reply notes that
ghostty config applies to new terminals only), `focus_window` (presents
the window), `refresh_surfaces` (OK — the Linux view sync is continuous,
nothing stale to rebuild), `notify_target_async` (alias of
notify_target). The remaining six v1 gaps are multi-window and macOS
test-harness internals, honestly erroring.

capabilities-sweep.py now scans both protocol generations. The lesson
generalizes: a coverage tool's blind spot looks exactly like a clean
report — the skill doubled as a test plan precisely because it walks
the surface a *user* walks.

### GAPS batch 1: tree, clear-history, last-pane (2026-07-22)

First pass over the new GAPS.md Now table, three S-effort verbs:

- **system.tree** — one-call topology (windows → workspaces → panes →
  surfaces with type/title/url) plus active and caller paths. The CLI's
  own tree renderer consumed the payload unchanged, markers and all —
  the payload shape was read from the CLI first, not guessed.
- **surface.clear_history** — one escape serves both backends: ED 3
  (CSI 3 J) fed as terminal *output* through the shared writeDisplay
  path erases scrollback and only scrollback. No per-backend API needed.
- **pane.last** — tmux last-pane, toggle semantics. History is fed by
  the GTK focus-enter funnel; the subtlety worth remembering: the note
  must happen BEFORE the handler's no-change guard, because verb-driven
  focus updates the model first and the GTK echo then hits the guard —
  the early return was starving the history of exactly those entries.

The restore-selection quirk did NOT reproduce on the current binary
(four attempts, both selection shapes) — moved to a watch note in
GAPS.md rather than fixing ghosts.

ui-commands-smoke: 19 assertions.

### GAPS batch 2: tab.action (2026-07-22)

`cmux tab-action` / `rename-tab` work now — the last S row of the Now
table. Supported keys mirror macOS's names: rename/clear_name pin a
per-surface title (a `PaneTabs.customTitles` store with precedence over
OSC/URL titles, persisted as `SurfaceSnapshot.title`, cleaned on
unregister), close_left/close_right/close_others walk the pane's surface
list through the existing close path, new_terminal_right and
new_browser_right reuse the popup-adoption `addingTab` insertion, and
reload goes through a registry helper because only CWebKit-bound files
may touch WebKit types (the module-boundary rule held: ControlProtocol
cannot even name WebKitWebView). Unsupported keys (duplicate, pin,
mark_read, move/detach, full-width) error with macOS's shape.

ui-commands-smoke: 22 assertions.

### GAPS batch 3: browser.highlight, and a shared-CLI collision (2026-07-22)

The last S row hid two findings. First, three of its four methods
(addscript/addstyle/addinitscript) are no longer sent by the merged CLI
at all — rows retired, not implemented; tracking follows the wire, not
old lists. Second, `browser highlight` was broken on BOTH platforms by
the merge: our find-bar work had aliased `highlight` onto the
find-in-page block, and upstream's dedicated element-highlight block sat
below it as dead code. The union merge preserved both, ours matched
first. Dropping the alias un-shadowed upstream's subcommand; the server
side is a fifteen-line entry in the existing selector-verb envelope (2s
outline), which contributed the retry and not-found diagnostics for
free. UPSTREAM.md §4c flags the CLI fix for the next upstream PR.

### GAPS batch 4: surface.move + surface.reorder (2026-07-22)

The `/cmux` skill's fast-start verbs. Both are pure model mutations —
`reorderingTab` and `addingTab(toPane:at:)` in the layout tree — because
the pane-tab reconciliation already does all the widget work: it closes
the page on the source strip (isReconciling guards the surface), and
unparent-appends the SAME container on the target strip. That reuse is
why a cross-workspace move keeps the terminal running: the suite sends a
marker, moves the pane to another workspace, selects it, and reads the
marker back through the same shell process. Position resolution
(index/before/after) is shared between the two verbs and computed
against the list without the moving surface (standard move semantics).
Moving the last surface out of a workspace closes it — after the insert
has safely landed.

One suite lesson re-learned: "poll, don't sleep" — the cross-workspace
assertion flaked once at a fixed 3s under full-suite load; the
reparented surface needs a map+draw cycle before read-screen sees it.

### GAPS batch 5: pane swap/resize/break/join — and two crashes worth their scars (2026-07-22)

The four tmux-compat pane verbs. swap exchanges two panes' CONTENTS
(identities and divider geometry stay — the reconciliation reparents the
tabs); resize walks the pane's widget ancestry to the nearest paned of
the matching orientation and shifts its divider (amounts are cells,
≈10px/18px); break removes the surface into a new workspace (refusing
tmux-style when it is already alone); join is surface.move in disguise
and delegates to it.

What the debugging bought, beyond the verbs:

- **Registry refs were imaginary.** `g_object_ref` on a FLOATING widget
  does not take ownership — the first parent's ref_sink consumes the
  floating ref, so the registry's "strong ref" never existed. The tell:
  detaching a moved pane from its GtkPaned destroyed it instantly
  (parent held the only real ref) and killed the shell ("pty fd
  closed"). retain() is ref_sink now.
- **Raw gtk_widget_unparent out of a GtkPaned is a delayed bomb** — the
  paned's internal child pointer survives, and destroying the paned
  later disposes the "removed" child anyway. detachWidget uses the
  proper per-parent removal, and deliberately does NOT touch AdwTabView
  children (ripping a page's child out segfaults the later close_page —
  the second crash of the night).
- **The window's focus ref can be a subtree's last ref.** Destroying the
  old skeleton then defers the paned's dispose to the next focus change,
  which runs MID-focus-iteration and segfaults deep in
  gtk_widget_focus_move (backtrace: gtk_window_root_set_focus →
  g_object_unref → gtk_paned_dispose). The sync now points window focus
  elsewhere before gtk_stack_remove. This is the GTK-reparenting trap
  family's third documented member.
- **Known limitation, precisely characterized:** relocating a
  never-tabbed Ghostty pane respawns its shell (cwd survives; scrollback
  and running processes do not). An extra ref keeps the old shell but
  leaks its io thread — worse. Tabbed panes relocate safely. Tracked in
  GAPS, belongs to roadmap/05.
- **debug.surfaces** (the doctor verb, at the user's suggestion): one
  line per surface — backend, parent type, realized/mapped, container
  refcount, readable. Every field is a probe some debugging round had
  hand-instrumented; extend it rather than re-instrumenting. Candidate
  seed for a future `cmux doctor` suite.

ui-commands-smoke: 35 assertions.

### The harness batch: run.sh, freshness, flake hunter, assertion ledger (2026-07-22)

The four S-items from the harness roadmap (linux/tests/README.md), cut
ahead of the remaining parity rows because every later batch runs
through this tooling. Interactivity was explicitly deferred — flags
only, so agents and CI can never hang on a prompt.

- **`run.sh`** is the front door: the gate, `--list` (rendered from
  suites.tsv), single suites with `-smoke` optional, `--keep`,
  `--build` (CMUX_GHOSTTY=1), and the flake hunter.
- **Freshness preflight**: suites test `.build/debug/` binaries as-is,
  so a forgotten build silently tests yesterday's code — the class of
  lie no assertion can catch. `lib.sh` warns per run, the gate checks
  once up front and suppresses the per-suite copies
  (CMUX_TEST_NO_FRESHNESS_WARN). `find -L` follows the CmuxCLI/CLI
  symlink so shared-CLI edits count. Warn, never fail: deliberately
  testing an old binary (a bisect) stays legitimate.
- **Flake hunter**: `--repeat N` / `--until-fail [--max N]` on one
  suite, per-iteration tally + duration, full log of every red
  iteration kept in /tmp/cmux-flakehunt/. The night before, "is this a
  flake or a regression" cost hand-re-runs; now it is one flag.
- **Assertion-count ledger** (suites.tsv): the gate FAILS a suite whose
  executed count drops below its ledger row — an early exit that skips
  half a file can no longer read as green (same class as macOS's
  "Executed 0 tests" unwired-test trap). Counts update in the same
  commit as intentional changes, so shrinkage is visible in diffs.
  Suites with skips are waived: a skip collapses whole assertion
  blocks, so the count is only meaningful on skip-free runs. Per-suite
  durations print in the gate as a side effect.

The batch's own shakedown produced three findings, two of them caught
by the new tooling itself:

- **Freshness false positive, fixed:** per-binary comparison cries wolf
  — SwiftPM legitimately skips relinking a product a change doesn't
  reach (a CmuxAdw edit never relinks the CLI), so the CLI binary
  looked permanently stale. Compare sources against the NEWEST binary
  only: its mtime is "when the last build ran".
- **The merged CLI prints legacy-alias notices** ("'new-workspace' is
  now an alias…") into captured output; `cx()` sets CMUX_QUIET=1 now.
- **Poll for completeness, not first evidence.** Converting the vte
  capture leg to poll-with-forced-saves (`force_save` in lib.sh — raw
  v2 session.save, promote.sh's call) first broke the suite
  DETERMINISTICALLY: breaking when the marker appeared saved a
  mid-`seq` snapshot, and the staircase assertion failed on the
  missing tail. The flake hunter caught it in one command (4/4 red at
  9s where ~60s was normal — the duration column alone was
  diagnostic). Poll condition = marker AND seq's last line; the suite
  ended both robust and ~4× faster (13s).

**The gate-flake hunt the batch turned into.** Three consecutive full
gates went red in the restart-replay family while every suite was
green in isolation — first vte-scrollback (3 red), then again (2 red),
then bisecting the gate into halves MOVED the red to
session-persistence (22/3). That movement was the tell: not a culprit
suite, but a nondeterministic class. Two harness fixes made it
diagnosable: run-all now keeps every suite's FULL output under
/tmp/cmux-gate-logs/ (the summary filter was discarding the failure
diagnostics), and the bg-split leg's instrumentation line printed
"(files holding the marker before restart: 1)" — proving the loss was
CAPTURE-side: the timed save ran before the second pane's output
landed, so one pane's scrollback file never held the marker and the
replay assertion blamed the restart. The cure across every capture
point in both suites: **verify state, don't schedule it** — poll the
scrollback files for the marker (forcing saves while polling) BEFORE
killing the instance, and never trust a sleep to mean "captured".

Then the verification polls themselves kept flaking, and the kept-log
diagnostics (empty scrollback dir + healthy `debug.surfaces` right
after three forced saves) finally named the saboteur: a **leaked
scratch instance from the previous night's batch-5 work** (`swptest`,
session in /tmp) was still alive — and because
`ScrollbackStore.directory` is `dirname(sessionPath)/scrollback`,
every `/tmp`-session instance SHARES one directory and
`prune(keeping:)` runs on every save. The leaked instance's 15s timer
deleted the suites' capture files whenever it fired inside a capture
window — which suite went red depended on whose window it hit: the
whole "moving red" (vte → session-persistence → settings, capture-side,
sometimes "none bytes") was one process. Three durable outcomes: the
product fix (per-session scrollback dir) is a GAPS Now row; lib.sh
pre-flight now WARNS about any foreign /tmp-session cmux-adw
(`warn_if_foreign_tmp_instance`); and suites stamp a capture epoch
(`mark_capture_epoch` / `fresh_marker_files`) so only this run's files
count — including the exit-save leg, which could false-PASS on a stale
file. The operational lesson is older than the code: **clean up your
scratch instances** — INSIDE-CMUX already said so, and this is what a
day of ignoring it costs. Also on the way: `v2()` promoted from
ui-commands into lib.sh (shared raw-JSON sender with a timeout), and
pane-zoom/browser-profile turned out to share PAGE_PORT 8418 — and
therefore an X display — a latent --keep collision now split.

Verified: freshness logic four-case tested in isolation (stale / fresh
/ missing / suppressed); flake hunter proven on a real red (4/4 with
kept logs) and a real green (4/4 at stable duration); full gate green
after the capture-verification hardening; ledger seeded from a live
gate and its drop-detection proven by inflating one row.

### Per-session scrollback directory (2026-07-22)

The product half of the saboteur incident: `ScrollbackStore.directory`
was `dirname(sessionPath)/scrollback`, so any two instances whose
sessions shared a directory also shared — and cross-pruned — their
scrollback files. Now it is `<session-stem>-scrollback/` beside the
session file (`session-linux-scrollback/` for the daily,
`cmux-<suffix>-session-scrollback/` per suite). `read(for:)` keeps a
read-only fallback to the legacy shared dir so the first restart after
the upgrade still replays; it is never written or pruned, and
vte-scrollback-smoke grew a permanent upgrade-simulation leg (files
relocated to the legacy path must still replay — delete that leg
together with the fallback). lib.sh exports SBDIR so suites stop
hand-deriving the path: if the app regressed to the shared dir, every
capture assertion would go red on its own.

### surface.respawn: VTE in place, ghostty refused honestly (2026-07-22)

`cmux respawn-pane` (and the tmux-compat `respawn-pane -k`, which
claude-teams teammates use). The CLI sends `surface.respawn` with a
shell-line `command` (default `exec ${SHELL:-/bin/sh} -l`), optional
`working_directory`.

VTE panes respawn IN PLACE: the same VteTerminal gets a fresh
`vte_terminal_spawn_async` — so scrollback survives — and the old
child is killed by pid rather than trusting the pty-close SIGHUP to
reach a shell that may ignore it. The pid comes from VTE's spawn
callback (a `SpawnPidBox` carries the surface id through the C
callback), recorded at first spawn and at every respawn.

Ghostty panes refuse with `unavailable` naming the reason: the shim
owns their spawn, and respawn there belongs to the roadmap/05 shim
work together with live config reload. ui-commands pins its instance
to `CMUX_TERM=ghostty` (it always ran ghostty via the user config —
now the refusal assertion doesn't depend on that config) and asserts
the refusal; vte-scrollback grew a three-assertion respawn leg
(command runs, old pid dead, scrollback survives). Live-verified on a
scratch instance first: custom command, default command, and the old
shell's pid confirmed dead.

### Eager background spawn: the realize half, and where the rest lives (2026-07-22)

The sync now force-realizes hidden ghostty subtrees
(`realizeHiddenGhosttys`). Two things the experiment established, both
worth their ink:

- `gtk_widget_realize` realizes ANCESTORS, never children — and the
  shim's lazy init hooks the GLArea's own realize, several levels below
  the registered bin. The walk must recurse. After it, every surface in
  a never-shown workspace reports realized=true mapped=false in
  `debug.surfaces` (the doctor verb earning its keep again).
- Realized is NOT running: the shim initializes "when the widget's
  GLArea is first realized AND SIZED" (lib_gtk_embed.zig), and GtkStack
  never allocates hidden children, so the size half never arrives and
  the shell still waits for first selection. Forcing allocation of
  unmapped widgets from outside layout would be fighting GTK; the
  correct remainder is shim-side eager PTY sizing (spawn with a default
  80×24 grid when unallocated, or an explicit ensure_started API) —
  exactly the "realize-offscreen strategy or eager PTY sizing" the
  increment-4 note predicted. GAPS carries the diagnosis; the realize
  half stays because the shim increment needs it anyway.

The eager-realize pass fronts the GL-context cost of hidden panes
(bounded — first show would have paid it), renderers stay dormant
until map.

### Ghostty shim increment 3: respawn, eager spawn, live reload (2026-07-22)

The three GAPS rows that converged on the shim, done as one increment
(GHOSTTY-SHIM.md has the C API). The macOS reading paid off twice:

- **macOS does NOT respawn in place.** `respawnTerminalSurface` tears
  the surface down and builds a replacement with the same panel id,
  replaying scrollback via file+env. Mirrored exactly: pending-command
  handoff (registry) → nonce-forced rebuild (respawnNonce in the model,
  part of the shape signature) → factory mounts the replacement via
  `new_with_command` → in-memory replay (the disk file gets overwritten
  by the replacement's own capture). cwd carries over via OSC 7. VTE
  keeps its cheaper in-place respawn.
- **Eager spawn was one export away.** `ensure_started` initializes a
  realized-but-never-allocated surface at a stand-in size. Agents can
  now drive panes in never-shown workspaces (the CATCHUP item-1 gap,
  open since increment 4's backlog).
- **Live config reload is one performAction.** ghostty's own
  config-change propagation does the per-surface work.

The debugging ledger, each with a permanent artifact:

- `surface.list` listed only each pane's SELECTED surface, so the
  shared CLI's surface resolution failed for background tabs
  ("Surface ref not found") — every workspace-scoped CLI command was
  affected, not just respawn. Now `allSurfaces`. Found by bisecting a
  suite red down through batch-5's swap into a cross-workspace-move +
  tab combination.
- PaneTabs reconcile keyed pages by surface id, so a respawned surface
  (same id, new container) kept its STALE page and the replacement
  never mounted. Reconcile now closes a page whose child differs from
  the registry's container.
- The same-sync GL-init miss (see GHOSTTY-SHIM.md increment 3) — the
  respawn verb schedules settled main-loop passes; without them the
  replacement in an unmapped workspace waited for the next unrelated
  model change.
- `readyForReplay` gated ghostty on MAPPED — correct before eager
  spawn (map was when the terminal came to exist), wrong after.
  Readable (core exists) is the honest signal now.
- ui-commands grew the increment section (respawn + replay + eager +
  live reload, 39 assertions); the refusal assertion it replaces died
  young, as it should.

### The docs crawl: dogfooding the browser stack on the product's own manual (2026-07-22)

To understand how cmux concepts are *meant* (user request), the port
crawled `https://cmux.com/docs/*` through its own browser verbs — not a
headless agent, a visible pane in a background workspace of the daily
instance. One surface, 21 navigations (`goto` → `wait --load-state
complete` → `get text body`), 20 pages, **zero verb failures** — the
navigation-barrier and CLI-transfer fixes from the pocketyoga cycle
held on a second real site. Two observations, neither a defect: the
site locale-redirected to `/de/` (WebKitGTK faithfully sends the host's
Accept-Language — crawl pinned `/en/` for canonical terms), and a
locale-prefixed nav initially hid links from a too-narrow selector.

Yield: `CONCEPTS.md` (the distillation), five new GAPS rows (OSC
777/99 verify, agent-native session resume, shortcut rebinding,
keyboard batch, TextBox), concept annotations on the Later families,
and one bug found by the parallel UX survey (pane-tab drag desync →
GAPS Now). The headline discovery: the macOS feature surface is
substantially larger than the sweep's method inventory suggested —
right sidebar (Vault/Dock/files), canvas layout, diff/markdown
viewers, status lanes, workspace templates, agent resume — all now
recorded with intent, not just method names.

### browser.console.show: the JS console, and CLI shadowing bug #2 (2026-07-22)

The GAPS-Now row, resolved with the macOS survey as the spec: macOS
builds no console UI (it flips WebKit's inspector to the Console tab
via private selectors), and WebKitGTK offers no public flip — the
inspector widget is not even a WebKitWebView, so nothing can script the
frontend. The Linux contract is therefore: the DevTools pane for the
target exists and is focused. Deliberately better than `browser.inspect`
in one respect: repeat calls focus the existing pane instead of
stacking splits. Bound to Ctrl+Shift+J (not macOS's Alt+Cmd+C:
Ctrl+Shift+C is terminal copy, Ctrl+Shift+J is Linux browser muscle
memory) through the same handler as the verb.

The debugging story is the valuable part. The server-side reuse logic
tested broken through the CLI — second call split again — yet worked
perfectly via a raw socket call. strace on the CLI showed why:
`browser devtools console` was sending `browser.inspect`. Our sweep-day
`devtools` alias on the `browser inspect` block shadowed upstream's
dedicated devtools block 450 lines below (toggle/console dispatch),
exactly the §4c highlight pattern — the second instance of that class
in two days (UPSTREAM.md §4d; the fix un-shadows macOS too). Also
resurfaced in passing: the list-panes-after-restore watch-list quirk
(conditions recorded in GAPS).

ui-commands-smoke grew three assertions (creates once / focuses
thereafter / verb answers OK): 42 in the suite.

### Claude Code agent teams runs on the Linux port (2026-07-22, late)

The kb prediction ("nearly free") held. The staged probe:

1. **Zero-cost shim probe** — `cmux claude-teams --version` proved the
   wrapper + shim write work on Linux; driving `cmux __tmux-compat`
   directly from a pane found the mutating verbs (split-window,
   new-window) already working and everything else failing on ONE
   missing verb: `surface.current`. Implemented in macOS's wire shape;
   full round trip green (list-panes/send-keys/capture-pane/kill-pane).
2. **The real run then failed differently** — Claude's harness died
   with "Could not determine current tmux pane/window". A traced shim
   showed the env was `default,0,0` / `%1`: the launcher builds the
   shim's TMUX identity from `system.identify`'s `focused` block, and
   the port's identify was flat — no focused block at all. Added in
   macOS's exact envelope (additive; flat fields kept).
3. **Second real run: complete lifecycle in ~30s.** Teammate spawned as
   a native split five seconds after launch, both panes carrying live
   OSC mission titles ("⠐ Spawn teammate…" / "⠐ Run shell command…"),
   marker echoed, lead captured it via capture-pane, kill-pane closed
   the split, lead reported success and idled.

Traps recorded: (a) the launcher owns `~/.cmuxterm/claude-teams-bin/` —
hand-editing the shim there breaks the next launch with a Cocoa
file-exists error; delete the dir and let it regenerate. (b) The
`--dangerously-skip-permissions` confirmation dialog must be answered
in-pane before anything happens — a headless driver has to send "2\n".

`tmux-compat-smoke.sh` (5 assertions) pins both server contracts and
the in-pane round trip, Claude-free. 13 suites, 163 assertions green.

### The UX batch: five decisions in one pass (2026-07-23)

The UX-PARITY decision queue, approved per recommendation and landed
together — every piece screenshot-verified under Xvfb before commit:

- **Header diet** — 14 persistent buttons → 4 (sidebar, split×2,
  browser) + a GNOME primary menu owning find/zoom/devtools/console/
  rename/open-folder/close-pane/preferences *with their accelerators*
  (adwaita-swift MenuButton registers them; GTK localizes the shortcut
  labels in the popover for free — "Umschalt+Strg+F" on a German
  system). Workspace/pane stepping went keyboard-only, re-bound at
  window level since their buttons had carried the bindings.
- **Omnibar** — back/forward/reload cluster + trailing profile button.
  The profile popover lists profiles (pane's own marked) and picking
  one opens the same page as a new split in that container —
  `network-session` is construct-only, so in-place switching cannot
  exist on WebKitGTK; routed through the same v2BrowserOpenSplit path
  as `browser open --profile` (shared-behavior rule).
- **Attention tiers** — macOS's one-accent three-tier language on the
  GNOME accent: flash ring (tier 1, double blink ~0.9s) and persistent
  unread pane ring (tier 2) as CSS outlines from one app-level
  provider (`AttentionStyle`); the sidebar dot stays tier 3 until the
  rich-row work. Tier 2 syncs from the scene body (the saveIfChanged
  idiom) — widget-class writes only, so every notification mutation
  path is covered by one line. Restyling the flash also fixed a latent
  use-after-free: the opacity version captured the widget pointer
  across its timers; the ring re-resolves the registry every tick.
- **Debug button** behind `CMUX_DEBUG_UI=1`.
- **Suppression contract** — all three documented rules (workspace
  active / window focused / panel open) in ONE decision path,
  `DesktopNotifier.deliver`, with outcome breadcrumbs (`cmux: desktop
  notify sent|suppressed(reason)`) replacing three drift-prone inline
  copies of rule one. ui-commands asserts the breadcrumb exists.

Localization note: the port's user-facing strings remain bare English
by existing convention (no i18n infra on Linux yet); the menu's
shortcut labels are the exception GTK localizes itself.

### Unfocused-split dimming, and the attention system becomes assertable (2026-07-23)

macOS's `showsInactiveOverlay: isSplit && !isFocused`, as a fourth CSS
class: unfocused panes of a split fade to 0.78 opacity, synced in the
same scene-body pass as the rings. The enabling change: `debug.surfaces`
now reports each container's `css_classes`, so the whole attention
language — dim, unread ring, flash — is suite-assertable instead of
screenshot-only. ui-commands grew four assertions (dim present on the
unfocused pane, absent on the focused one, swaps on focus move, bell
adds the unread ring).

Test-harness lesson recorded the hard way: the new block switched
workspace selection to test the swap, and the downstream respawn-replay
assertion went red — its target's workspace must stay selected because
an unmapped pane keeps its replay *pending* by design (the scrollback
lesson resurfacing as test-ordering coupling). Suite blocks that change
selection must capture and restore the incoming selection.

### The corp-network accident: goto's timeout left the load running (2026-07-23)

The dev box joined a corporate network and browser-navigation-smoke went
red: its "unreachable" fixture address (10.255.255.1) is routable 10/8
space there, and a real host answered in 227ms. Hardening the test with
a local tarpit (accepts the TCP connection, never sends a byte) exposed
a genuine barrier hole the instant-failing no-route path had hidden:
**on timeout the barrier reported failure but never stopped the load.**
The provisional navigation kept running — able to commit minutes later
and yank the pane to a page the caller was told it never reached — and
its hanging context answered evals with an empty document ('undefined'
where the previous page's marker should be). Fix: the timeout branch
now calls `webkit_web_view_stop_loading` before responding; the tarpit
test is deterministic on any network, and the failed-navigation
assertions went red→green across the fix in this session's runs.

Transferable lesson: "reserved" addresses are only unreachable on the
networks you tested from; a tarpit you own beats an address you assume.
macOS's own barrier may share the hole — UPSTREAM.md §4e.

### scratch.sh — the ad-hoc instances get their own wrapper (2026-07-23)

The human's catch: "didn't we have a wrapper for xvfb?" — the SUITES do
(lib.sh start_xvfb, per-suite displays :90-:139); ad-hoc probes did
not, and every scratch instance this week was hand-rolled onto a
hardcoded :93 — which put a screenshot instance on a running gate's
display and produced a false-red (2 phantom browser-navigation
failures). `linux/scripts/scratch.sh` now owns the ad-hoc case:
start/env/shot/stop/list, a free display strictly in :140-:159,
isolated app ids killed only by env match, sessions under
~/.local/state/cmux/scratch/<tag>/ (never /tmp). Verified through the
full lifecycle. Rule of thumb now written in INSIDE-CMUX: suites use
lib.sh, ad-hoc uses scratch.sh, nobody types `Xvfb` by hand.

### Tab drag-reorder wired, and the harness goes hermetic (2026-07-23)

The GAPS-Now desync: AdwTabBar accepted the drag visually and the next
reconcile silently reverted it — no `page-reordered` handler existed.
Wired now, through the same mutation path as `surface.reorder`
(shared-behavior rule), with the reconcile's own `reorder_page` wrapped
in `isReconciling` because programmatic reorders emit the same signal.
The suite drives a REAL pointer drag (gesture-not-registering is a
skip; a registered drag the model ignores is a red).

The drag test earned its keep before it ever passed: its screenshot
probe caught a **Ghostty config-error dialog** ("theme Adwaita-Dark not
found" — from the developer's real ~/.config/ghostty) stacked over the
window at the origin, eating every pointer event. Key-driven tests
never noticed: `xdotool key --window` targets the window directly and
sails past the dialog. Fix: `start_instance` now defaults to a hermetic
`XDG_CONFIG_HOME` (INSTANCE_ENV still overrides — settings-smoke keeps
its own fixture), and scratch.sh isolates the same way. Suites no
longer depend on whatever lives in the developer's dotfiles.

Cross-pane tab drag (macOS supports it) remains unwired — UX-PARITY
tracks it; moves stay verb-only.

### The wiring atlas + a live viewer in our own browser (2026-07-23)

Comprehensive component-level docs of the port, as mermaid graphs that
read from the code — `docs/linux-port/wiring/` (9 pages, ~30 diagrams:
topology/sockets, the claude-teams shim, control protocol, surface
lifecycle, attention pipeline, session+scrollback, browser stack,
build→promote). Sibling to MENTAL-MODEL (that is *what cmux is*; this is
*how our port is wired inside*).

The viewer is the point as much as the docs: `wiring/viewer.html` +
`linux/scripts/wiring-serve.sh` render markdown+inline-mermaid in a cmux
browser pane, **live-reloading** on `.md` edits — the human-AI loop the
human asked for (agent edits a diagram, human watches it change,
comments, iterate). It reuses cmux's OWN vendored mermaid.min.js /
marked.min.js (`Resources/markdown-viewer/`) served from the repo root,
so no CDN — robust on the corp network. Assessed palma's viewers first:
its milkdown editor bundle is self-contained (0 CDN refs, inline mermaid
+ visual canvas) but coupled to palma's server API; its plain viewer
needs CDN. A thin own-viewer beat reverse-engineering either.

Verified through the browser verbs: all 9 pages render every mermaid
block to an SVG (1/1…4/4, zero syntax errors), driven and screenshotted
via `cmux browser eval/screenshot` on a background workspace. Two bugs
found and fixed in the loop: the viewer read `location.hash` only at
load (no hashchange listener — nav-clicks worked, URL/back-forward
didn't), and same-fragment `browser goto` does not reload the document
(cache-bust query per doc forces a real reload — worth remembering for
any future browser-driven verification).

Note: `markdown.open` is still unimplemented on Linux (macOS-only, GAPS
Later) — implementing it natively would turn this into a first-class
cmux markdown panel with the same vendored assets. Good future board
item; the browser-pane viewer covers the need today.

### The parity dashboard + an automated macOS-surface survey (2026-07-23)

Answering "how do we track drift against a macOS that keeps moving?" —
the user's call was the heaviest option: a roll-up board AND automated
discovery. Two deliverables:

1. **`macos-surface-survey.py`** — the app-side twin of
   capabilities-sweep.py. The sweep catches new CLI *verbs*; this catches
   new macOS *app* surface — the enablement is that since the catch-up
   merge the macOS Sources/ live in this tree, so it extracts the
   enumerable sets (the 125-case `Action` command registry, 11
   `PanelType`s, 18 settings sections) and diffs them against a reviewed
   `macos-surface-ledger.json`. A future merge that adds a command shows
   it as `NEW (triage)`; `--check` exits nonzero to gate. Each extractor
   asserts a sane minimum so a shape change fails loudly instead of
   faking "no drift". Proven: dropping a ledger entry flags it NEW.
   Seeded coverage: commands 40 done / 27 gap / 58 later (32%), panels
   2/11, settings 1/18 done.
2. **PARITY-DASHBOARD.md** — the board of boards: a coverage mermaid
   diagram, the discovery cadence (both tripwires after every merge →
   GAPS), and links to the six single-responsibility ledgers. Explicitly
   NOT a new backlog — an index. Live-viewable as page ⓪ of the wiring
   atlas (the viewer resolves the `../` path), verified rendering through
   the browser verbs.

Design stance recorded: keep the focused ledgers (each one update
trigger), don't merge into one "source of truth" doc (rot). The tools
are the live truth; the dashboard is the human view; one-shot surveys
(UX, docs crawl) complement but don't replace the repeatable tripwires.

### Parallel-dogfood harness — testbed proven (2026-07-23)

Designed and rehearsed a harness for running several agents on DISJOINT
work packages at once, to dogfood the claude-teams feature on real work.
The realization: every hard primitive already existed this week — git
worktree isolation, scratch.sh (per-agent cmux instance), browser
profiles (per-agent WebKit container), claude-teams (teammates as
splits). The harness is orchestration over them, not new invention.

Safety property: STATIC scope-disjointness. Each package declares the
files it may touch; `pkg-harness.sh check` refuses to dispatch on
overlap (guard at dispatch time, not merge time), and `collect` asserts
each branch changed only in-scope files. Disjoint branches merge
conflict-free by construction, integrated through a LOCAL BARE repo so
the human's checkout + origin are never touched until deliberate promote.

Full rehearsal on a synthetic port-shaped testbed, every step green
(PARALLEL-DOGFOOD.md): 3 disjoint packages init→add→check→simulate→
collect(scope-compliant)→integrate(clean 3-way merge via bare repo); the
NEGATIVE case (a 4th package overlapping a scope) was refused by check
(exit 1); verify-runtime gave two agents distinct sockets+displays
(:140/:141) + distinct profiles, no collision; teardown left nothing
behind. Also answers the user's questions directly: worktrees yes (git
layer), own browser profiles per agent yes (proven), local bare repo yes
(the integration point + testbed).

Tooling: linux/scripts/pkg-harness.sh (init/add/check/simulate/list/
collect/integrate/verify-runtime/teardown) + pkg-report-template.md.
Next: run it for real with claude-teams teammates on a disjoint cluster
(browser / keyboard / teams-siblings / sidebar-ui), integrator reviews,
human promotes. A `parallel-dogfood` skill can encode the protocol once
the real run confirms the flow.

### ADR workflow: decisions become trackable + reviewable (2026-07-23)

Decisions were captured but scattered (UX-PARITY's decisions list,
roadmap/ docs, PROGRESS prose, commit bodies). Added a proper ADR log —
`docs/linux-port/adr/` — numbered records with a Proposed→Accepted→
Superseded lifecycle, a template, and an index (adr/README.md). ADRs hold
the decision + rationale + alternatives; GAPS holds backlog, PROGRESS
evidence, roadmap detailed design. Seeded with the parallel-dogfood
harness (0001) plus five backfilled load-bearing decisions:
interaction-parity-sacred (0002), out-of-band scrollback (0003),
DevTools-as-pane (0004), focused-ledgers-and-discovery-cadence (0005),
ghostty-embed-strategy (0006, kept "open review" to demonstrate the log
tracks not-fully-settled decisions too). Next: run the first real
parallel-dogfood batch (browser + teams-siblings).

### Build-isolation for parallel code packages — solved (2026-07-23)

The blocker for real parallel code batches: a fresh worktree has no
ghostty shim and no Swift .build, so a naive code package rebuilds the
world (minutes) per worktree. Solved by sharing what's identical across
worktrees on the same commit:
  - shim: symlink <wt>/ghostty/zig-out → the main checkout's zig-out
    (no per-worktree zig build);
  - .build: btrfs REFLINK copy (cp --reflink=auto, copy-on-write) — the
    worktree's build writes break extent sharing, so main's .build is
    never touched.
Measured: seed 0.9s, first incremental build 29s (vs minutes
from-scratch), worktree binary independent and linking the shared shim
(ldd → ~/cmux/ghostty/zig-out/lib/libghostty-gtk.so). Baked into
`pkg-harness.sh add --build`; tests/CLI packages skip it (they drive the
main binary via scratch.sh). Also fixed the harness base ref: init now
records the --from repo's current branch (so a real batch forks from
linux-port, not a stale main). ADR-0001 consequences updated: build
isolation resolved. Ready for the first real batch when there's time to
watch it.

### Parallel-dogfood batch 1 — two teammates, real work, integrated (2026-07-23)

First REAL run of the parallel-dogfood harness (ADR-0001): two
claude-teams teammates as native splits, each on a disjoint package in
its own worktree, integrated by this session as the integrator.

- **browser (code):** ephemeral "leave-no-trace" browser panes via a
  reserved virtual profile "ephemeral" — `browser open --profile
  ephemeral` mints a fresh `webkit_network_session_new_ephemeral()` per
  pane (no cookies/cache/storage on disk, dies with the pane), with
  reserved-name guards on create/rename/delete/clear and the
  construct-only-session ownership handled (g_object_unref the
  construction ref only for ephemeral, since it's uncached).
  browser-ephemeral-smoke: 10 passed. browser-profile regression: 14.
- **teams-siblings (tests):** teams-siblings-smoke verifies the sibling
  launchers' (codex-teams/omc/omx/omo) shim+env setup on Linux — 14
  passed, 6 honest skips (agent binaries absent). It empirically
  corrected the task's premise: omc/omx resolve their binary BEFORE
  writing the shim (absent ⇒ no shim); codex-teams writes no tmux shim
  (app-server path). A real finding a no-op rehearsal couldn't produce.

Harness verdict: the isolation held perfectly — both branches
scope-compliant (each touched only its declared files; browser correctly
left ControlProtocol.swift untouched though in-scope), ~/cmux untouched
until deliberate integration, build-isolation (shared shim + reflink
.build) made the code teammate's builds fast. Integrator did what the
teammates deliberately left: cherry-picked both branches, registered
both suites (run-all.sh + suites.tsv: browser-ephemeral 10, teams-siblings
20-with-skips-waived), updated PARITY/GAPS. Teammate-discovered follow-up
(no URL-bar affordance for ephemeral) → GAPS Next. Both teammates filed
proper reports; quality was high enough to merge with light review. The
parallel-dogfood pattern works on real code.

### Harness lifecycle fix — worktrees follow the agent, not the merge (2026-07-24)

Batch 1's teams-siblings teammate caught a bug from the inside: the
integrator ran `pkg-harness teardown` right after integrating, reaping
worktrees out from under still-live agents — so a teammate asked to do
more (the human had just installed `codex` to extend the siblings test)
had no working dir. Root cause was a mental-model error: teammates were
treated as fire-and-forget jobs, but they're persistent collaborators
that can be re-tasked and answer questions.

Fix (pkg-harness.sh): `integrate` is already non-destructive (merges the
pushed branch from the bare repo — never needs a worktree). Added
`release <id>` for per-agent cleanup on dismissal, and `teardown` now
refuses while packages remain (`--force` to override), so you can't reap
a live agent's worktree by reflex. Documented in PARALLEL-DOGFOOD.md
(refinement 3) and ADR-0001 consequences. This is the harness improving
from its own users' friction — exactly the feedback loop a
findings/friction channel (idea 2) is meant to formalize.

### Batch-2 follow-up: codex extension + a real product bug found (2026-07-24)

After the lifecycle fix, the still-live teams-siblings teammate was
re-provisioned a fresh worktree and re-tasked (human had installed
`codex`). It un-skipped one real assertion: with codex present,
`cmux codex-teams` now gets past binary resolution and launches its real
mechanism — `codex app-server --listen ws://127.0.0.1:<port>` — and the
suite verifies that loopback port actually binds (the stage a tmux shim
never reaches). It ran codex under an isolated HOME (only `codex`
symlinked in) with /dev/null stdin so unauthenticated codex EOFs out
rather than blocking. 15 passed / 0 failed / 6 skipped with codex;
verified the codex-absent path stays green too (14/0/7) so CI without
codex is safe. The authenticated teammate-*split* stays honestly skipped
(needs interactive-authed codex).

The valuable find: **codex-teams leaks its `codex app-server` child on
teardown.** Confirmed at source — `codexTeamsTerminateProcess` does only
`process.terminate()` (SIGTERM to the immediate child); the app-server
escapes the process group and ignores SIGTERM, orphaning a loopback-bound
server on abnormal exit. Shared CLI ⇒ macOS affected. Recorded UPSTREAM
§4f + GAPS Now (SIGKILL-escalation / killpg fix). A dogfood agent, tasked
only with a test, found a real product bug in the shared CLI.

Also acted on the teammate's harness-friction note: `pkg-harness add`
(build-free packages) now symlinks the worktree's linux/.build to the
main build, so lib.sh finds the prebuilt CLI without the agent
hand-symlinking it. And the lifecycle fix worked — the worktree stayed
put this time.

### Four Proposed ADRs from the batch-1/2 learnings (2026-07-24)

Running two real parallel-agent batches surfaced a cluster of open
architectural questions (raised by the human). Captured as Proposed ADRs
— decisions framed, not made — to think through as a set:
- **0007** harness layer & extensibility (scripts vs skill vs built-in
  command vs a cmux plugin system; cmux-mac has no code-plugin API, only
  config+skill extensibility). Lean: skill now, built-in command as
  eventual target, no plugin system just for this.
- **0008** agent runtime lifecycle — nothing reaps an agent's scratch
  instances / browsers on dismissal or death (they orphan, like the
  codex-teams app-server). Lean: track+reap on release, plus a
  liveness reaper; cmux-owned surface lifetime is the clean end-state.
- **0009** agent work visibility — only part of agent work reaches main
  via reports (this session's best findings came from reading the pane);
  panes show agent TYPE not NAME. Lean: richer reports + a name↔pane
  mapping so pane-review is systematic.
- **0010** visible isolated displays — agent Xvfb runs are invisible,
  which fights cmux's transparency ethos. Lean: proactive screenshot
  stream now, x11vnc-to-pane as the live-visible aspiration.
They interlock (0008/0009 share an agent↔surface registry; 0009/0010 the
"watch agent X" story). No implementation yet — the decisions come first.

### ADR atlas + a generic reusable atlas viewer (2026-07-24)

Two atlases now (wiring + ADR), so the viewer became a reusable harness
component instead of a per-atlas copy. `docs/linux-port/atlas/viewer.html`
is generic — `?atlas=<dir>` renders any doc set with an index.json;
`linux/scripts/atlas-serve.sh <name>` serves any registered atlas (wiring
| adr | a literal dir). The old wiring/viewer.html was retired and
wiring-serve.sh is now a thin shim over atlas-serve.sh, so both atlases
share ONE viewer (verified: both render through it in a browser pane).

The ADR atlas's value-add over a folder of markdown is a decision GRAPH:
`adr-atlas-graph.py` reads the ADR files (status + cross-references) and
generates `adr/_overview.md` — a status-coloured mermaid of all 10 ADRs
and their interlocks, plus a status table. `--check` gates staleness, so
the landscape stays current as ADRs are added (same generated-not-
hand-kept discipline as the dashboard + surface survey). An atlas is now
"a directory + index.json"; adding a third is trivial. Ties to ADR-0007
(this IS the harness generalizing into reusable pieces) — worth folding
into that decision.

### ADR-0009 implemented — agent work visibility (2026-07-24)

Accepted and built. Two parts:
- **Richer report template** (`pkg-report-template.md`): added
  decision-carrying required fields — Findings, Product bugs discovered,
  Honest limitations/skips, Harness friction, Escalations — plus a
  surface-identity line. The frame stays tight; the point is that a
  finding not in a field is invisible to the main session.
- **Agent-populated name↔pane registry** (the reliable approach — NOT a
  pane-title change, since Claude Code overwrites titles): each agent
  records its own `$CMUX_SURFACE_ID` from inside its pane into
  `.pkg/<id>/surface` as task step 1, and the harness reads it back —
  `pkg-harness panes` / `pane <id>` / `review <id>` (reads the agent's
  live screen by name). No more walking the tree and guessing who's who.

Also hardened a latent bug the visibility test surfaced: the batch-2
`.build`-symlink friction fix could abort `add` under `set -e` when a
worktree lacked a `linux/` dir (synthetic testbed) — now guarded.
Norm recorded in PARALLEL-DOGFOOD.md: `review <id>` a surprising report's
pane before acting. ADR-0009 → Accepted; the decision graph regenerated
(0009 now green).

### system.capabilities drift fixed + sweep self-check (2026-07-24)

A parity-dashboard question ("do we know exactly which socket methods
are missing?") surfaced that the answer was yes — `capabilities-sweep.py`
lists all 127 by name — but also that the port's own advertised
`system.capabilities` list had drifted 16 methods behind the dispatcher:
`browser.tab.*` (4), `browser.profiles.*` (5), `browser.find_in_page`,
`browser.highlight`, `browser.inspect`, `search.panes`, `pane.zoom`,
`surface.action`, `notification.create_for_caller`. All were dispatched
fine; they just weren't advertised, so an agent introspecting
capabilities before calling was under-told. The reverse direction
(advertised-but-not-dispatched) was clean.

Fix: added the 16 to the `"methods"` array in `ControlProtocol.swift`,
and gave `capabilities-sweep.py` a hard-failing self-check — it now
parses the advertised array and diffs it against the dispatched case
labels in both directions, exiting 1 on any mismatch (the CLI-vs-server
report above it stays informational). Verified live on a scratch
instance: 131 methods over the wire, all 16 present.

Trap for the ledger: the two "missing methods" baselines differ.
The sweep's 127 is CLI-sendable vs Linux-dispatched; diffing macOS's
*advertised* server list instead gives 134 — macOS advertises methods
its CLI never sends (mobile.*, terminal.*, remote.tmux.*), and its CLI
sends families its own capabilities array omits (canvas.*,
workspace.todo/status.*, remotes.*, handled in ControlCommandCoordinator
— macOS's advertised list has drifted too; upstreaming candidate).

### Features board: measured status over authored pages (2026-07-24)

ADR-0011 (Accepted, implemented same day) + ADR-0012 (Proposed: pin
dashboards to the sidebar). The features atlas
(`docs/linux-port/features/`, `atlas-serve.sh features`) gives the
feature-level overview the verb/command ledgers don't: per-feature pages
authored with purpose/usage/implementation, status columns *measured* —
the anti-drift lesson from the same-day capabilities incident.

Pieces:
- `linux/scripts/capslib.py` — the capability parsing (CLI-sent,
  Linux-served/advertised, mac advertised/served) extracted from
  `capabilities-sweep.py` so the sweep and the board measure identically.
  Found a mac-column subtlety on the way: the shared CLI carries
  Linux-added verbs (`pane.zoom`, `session.save`), so "CLI sends it" must
  not count as "macOS has it"; and macOS dispatches `canvas.*` without
  string case labels anywhere in `Sources/` (name-mapped dynamically), so
  those read as absent — documented limitation in `mac_methods()`.
- `linux/scripts/features-board.py` — emits `_board.md` + `index.json`
  from the pages' front matter (`verbs:` mappings → per-verb mac/dev/
  daily table; ⚠ when an authored claim contradicts measurement).
  `--check` fails on verb typos. Generated files are **gitignored** (the
  daily column reads machine-local state); `atlas-serve.sh features`
  regenerates on serve, so there is no staleness class at all.
- `promote.sh` stamps `promote-<slot>.json` (state dir) after starting
  the instance: date, repo SHA, live capabilities snapshot — the board's
  *daily* column. Verified against dev2 (`--slot dev2 --no-build`:
  manifest with 131 methods stamped, instance stopped after).
- Seed pages calibrate granularity (one FEATURES.md bullet ≈ one page):
  browser tabs (full parity), pane zoom (mac 🟡 — command exists, verb is
  ours), session persistence (mac verb `session.restore_previous` vs our
  `session.save`), workspace groups (mac-only, 0/17 verbs).

Daily column reads "?" until the next real promote stamps
`promote-daily.json` — correct by design (the manifest records
promote-time truth; hand-stamping now would claim daily runs HEAD, which
it doesn't).

### ADR-0013 Proposed — pane tags & (maybe) attention workflows (2026-07-24)

Captured the human's idea to extend 0009's name↔surface registry to also
hold tags (address/group/attention by tag), and further out a tag-based
state machine where panes run tools/skills/prompts on triggers — an
attention-driven workflow engine. The ADR's job is discipline: it
separates three levels — (B) tags on the registry (cheap, do when we next
touch it), (C) pane state (only if useful, and as parity with the
existing attention pipeline / macOS status lanes, not a new concept),
(D) a trigger→action engine (do NOT build speculatively; it overlaps the
Workflow tool, teams, notification hooks, custom-commands — set a
trigger condition: only when a concrete workflow can't be expressed with
those). Also records the workspace-groups relationship (a group ≈ a
coarse UI-level tag; keep separable — groups are macOS parity, this is
novel). Proposed; the graph regenerated (13 ADRs now).

### ADR-0013 (B) implemented — tags on the registry (2026-07-24)

The cheap, useful layer of the tag idea: `pkg-harness tag/untag <id>
<tags…>`, `tags [--tag <t>]`, and a `--tag <t>` filter on
`list`/`panes`/`review`. Tags live in `.pkg/<id>/tags` (orchestrator sets
them, or an agent self-tags by appending — the bridge toward C without
building C). The payoff: address/group agents by tag instead of one by
one — `review --tag blocked` reads every pane in that group. C (pane
state) and D (workflow engine) stay open/paced per the ADR.

Fixed a `set -e` gotcha found in testing: `[ cond ] && x=…` at statement
level aborts a function when the test is false (it silently emptied the
no-filter path, swallowed inside `$(_ids …)`); an `if` is the safe form.

### Features board: uniqueness verified + first unique pages (2026-07-24)

Extended the features-board generator (ADR-0011) to answer "is this
*really* a cmux-adw-unique feature?" — not by trusting the authored `mac:`
glyph but by MEASURING it. A `mac: none` page now gets a Unique column:
★ (verb-verified — its mapped verbs are absent from the macOS
advertised∪dispatched set), ★ᵃ (authored — no verb to measure, judgment
flagged as such), or **⚠ false** (macOS actually serves the verbs — the
claim is rejected). Plus a "Unique to cmux-adw" summary section. Proved
the ⚠ guard fires on a deliberately-bogus page.

Authored the first three genuinely-unique pages, each verified against
Sources/ before claiming uniqueness: browser.identify (★ verb-verified —
confirmed not in the macOS-served set), the Ghostty/VTE backend chooser
(★ᵃ — macOS is Ghostty-only, no VTE in Sources), and ephemeral browser
panes (★ᵃ — macOS's only `ephemeral` hits are an unrelated URLSession
config + a tmux mirror, not leave-no-trace panes). The existing four
pages are parity features (blank Unique column). `--check` green, 7
pages. Board files stay gitignored (generated); pages + generator commit.

### Features board taxonomy: product / inbuilt / meta (ADR-0014, 2026-07-24)

The board grew three genuinely different kinds of thing; a flat list
conflated them. Added a `kind:` front-matter field driving three sections
(features-board.py): **product** (leaf features, measured vs macOS with
the verified-uniqueness column), **inbuilt harnesses** (product
subsystems that are frameworks — control socket, browser automation,
attention pipeline — same measured treatment, grouped apart), and **meta
harnesses** (the dev tooling we built to develop/measure/verify the port
— comparison harness, parallel-dogfood — a different table: what it
detects/does + a `check:` verify command + its ADR, and NO vs-macOS
column, since comparing our dev tooling to macOS's product is a category
error). Authored 4 demonstrating pages (browser-automation +
attention-notifications as inbuilt; comparison-harness + parallel-dogfood
as meta). The board is now a complete map: what the port does AND what we
built to prove it.

Also answered the "improve the comparison harness?" question: it already
exists (capslib + capabilities-sweep + macos-surface-survey), and the
measured-over-asserted discipline is already in all three; the features
board's verified-uniqueness (★/★ᵃ/⚠) is the cleanest expression, now
documented as the "Comparison harness" meta page. `--check` green, 11
pages. ADR-0014 Accepted; graph regenerated (14 ADRs).

### VNC live agent display — ADR-0010 B stage-1 POC proven (2026-07-24)

ADR-0010 asked whether an agent's isolated Xvfb display could be
live-visible in a cmux pane. Proved it with zero app changes: `scratch.sh`
instance on :140 → `x11vnc -localhost` (must launch with
`env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE`, else x11vnc sees the Wayland
session and exits) → `websockify --web /usr/share/novnc` → noVNC with
`?autoconnect=true&resize=scale` in an ordinary browser surface in a
background workspace. Verified without focus theft via
`cmux browser eval` (noVNC_connected) — which also surfaced two facts:
backgrounded browser surfaces keep their WebKit page running (the VNC
session connects and holds while never visible), but `browser screenshot`
requires visibility (`invalid_state`). Per-agent scaling is structural:
display `:140+k` → ports `5920+k`/`6081+k`. Stage 2, if the live view
earns it: a native pane type on `gtk-vnc2` (GTK4 VncDisplay — already
installed on the host; `-devel` in the Fedora repos). POC page:
`poc/0002-vnc-live-agent-display.md`; ADR-0010 stays OPEN on the
native-pane question.

### ADR-0010 accepted — screenshots + live VNC, and the pointing channel (2026-07-24)

hias decided: A and B **both**, with the insight that settled it — B is
not just watching. The VNC pane is interactive, so the human can click
the element they *mean* inside the agent's display, then the agent reads
it back. Deixis ("this one, here") — inexpressible in a screenshot
stream. Wired in as `scratch.sh watch` (x11vnc+noVNC → browser pane in a
background workspace of the caller's cmux, ports :N→rfb 5900+N / web
6900+N, localhost-only), `watch-status` (verifies processes, noVNC
serving, and that the pane is *actually connected*, via `browser eval` —
the meta-feature's check), `point` (xdotool pointer read + crosshair-
marked shot), `unwatch` (kills strictly by recorded pid after /proc
cmdline verification; `stop` implies it). Measured end-to-end: a click
injected at (140,75) through VNC really operated the scratch instance's
sidebar, and `point` returned exactly x=140 y=75 with the crosshair on
the clicked row. POC-0002 graduated to adopted (`features/12` — first POC
to complete the authored-intent → measured-reality loop). Two traps
re-confirmed: x11vnc dies on sight of WAYLAND_DISPLAY (launcher scrubs
it), and `pkill -f` matched the caller's own command line again (exit
144; third documented hit — hence pid-verified kills only).

### Workspace groups stage 1 — the verb family, model-true (2026-07-24)

The first "grouping features" family from the deferred list, chosen by
hias over ADR-0012/0013 alternatives. All 17 `workspace.group.*` verbs
now serve on Linux with macOS wire parity, mapped verb-for-verb from the
macOS source (CmuxWorkspaces WorkspaceGroupCoordinator + the socket
coordinator): membership is a per-workspace `groupId` relation — the
group stores NO member list; the anchor is a real member that renders as
the header; the sidebar invariant is contiguous runs, anchor-first,
pinned tier above unpinned (`normalizeGroupContiguity`); anchor close —
and anchor `remove` — dissolve the group; `create` adopts explicit
`child_workspace_ids` or falls back to the sidebar selection; placements
are `afterCurrent|top|end` with tolerant spellings (`group.new_workspace`
defaults to afterCurrent like the macOS setting default, the
`workspace.create` group path to top like its macOS handler).
`new-workspace --group/--group-placement/--group-reference` — which the
shared CLI has been sending all along and Linux silently dropped — now
validates and joins at creation. Persistence: optional `groups` array in
session v3 + per-workspace `groupIndex`, anchor by member index (UUIDs
change on restore). `workspace-groups-smoke` (34 assertions) covers the
family end-to-end including the save/restart round-trip;
session-persistence-smoke still 25/25; capabilities self-check green.
PARITY 🟡 (verbs full, sidebar still renders flat); stage 2 (sidebar
sections UI) is a GAPS "Next" row. The features board's contradiction
guard did its job mid-commit: `linux: none` with measured-served verbs
would have flagged ⚠ — the page moved to `partial` in the same change.

### Workspace groups stage 2 — the sidebar renders sections (2026-07-24)

The sidebar is group-aware: header rows with a real disclosure chevron
(a flat Button inside the row — its click toggles collapse and never
reaches row selection; clicking the header itself selects the anchor,
the macOS semantics for free since the header's row id IS the anchor's
workspace id), indented members, "(N)" counts on collapsed headers, and
attention aggregation (a hidden member's dot surfaces on its collapsed
header — asserted with a notification onto a hidden member). The
projection `SidebarRows.project(tabs, groups) → [SidebarRowModel]` is a
pure value snapshot shared verbatim between SidebarView and a new
`debug.sidebar_rows` verb (debug.surfaces precedent), so suite
assertions on the verb ARE assertions on the rendered rows —
workspace-groups-smoke grew to 39 with rendered-row coverage.

**New trap, paid for and documented:** adwaita-swift's ListBox differ
updates rows in place by id; a row whose VIEW STRUCTURE changes between
renders (plain Text ⇄ HStack when a workspace becomes a group header)
keeps its stale widget silently — the header rendered the anchor's old
title with no chevron. Fix: every row keeps a structure-stable shape by
wrapping in EitherView (a ViewStack keyed by the condition — the
supported structure-switch container). Corollary of the
snapshot-boundary family: rows are value snapshots AND shape-stable.

Verified with clean-session screenshots (expanded, chevron-clicked →
collapsed with count) plus an xdotool click on the chevron confirming
collapse-without-selection-theft; a first confusing shot turned out to
be session restore faithfully resurrecting the previous demo's
collapsed group — persistence proving itself by surprise.

### Workspace groups last mile + adversarial QA (2026-07-24)

Colors and icons render on group headers (hex-validated tinted swatch;
SF Symbol names mapped onto GTK themed icons, folder default), and the
app menu gained group management — New Group from Workspace / Rename
Group / Move Group Up/Down / Ungroup — each routing through the SAME v2
implementations the socket verbs use, with a generalized
`UIDialogs.promptText` (the rename dialog, parameterized). Menu flow
verified end-to-end with synthetic input: xdotool drove menu → dialog →
type → Enter and the group appeared via the verbs.

Then the correctness pass the feature deserved: the FULL suite gate (15
suites, 195 assertions, 0 failed) plus an adversarial QA agent hammering
a scratch instance — fuzzing params, torturing persistence with
unicode/markup/garbage, interleaving pin/move/set_anchor, injecting
markup through group names. Verdict: invariants held everywhere, one
real defect found: `validatedHex` used `{3,8}` while Pango parses only
3/4/6/8 hex digits, so a 5/7-digit color passed the guard, broke the
header markup into raw `<span…>` source, persisted through session
restore, and stayed broken until replaced. Fixed red-first: three suite
assertions failed on the buggy build, then the grammar fix + non-string
param rejection (set_color/set_icon) + the misleading
empty-child_workspace_ids error turned the suite green at 47.
Lesson re-learned: a "renderer guard" must encode the RENDERER'S
grammar, not a plausible superset — and adversarial QA on supposedly
done code keeps paying (cf. the dogfood cycles).

### The comfort survey: four agents map macOS UX depth (2026-07-24)

hias asked what drag-and-drop, right-click, iconography, and color
comfort cmux-mac has that the port lacks — and what the unported right
sidebar actually is. Four exploration agents read the macOS sources;
their reports are consolidated in MACOS-UX.md (new doc-map entry; UX-
PARITY now links to it as its evidence base). Highlights: DnD is a
four-type system (surface tabs with edge-split/center-insert drops,
sidebar reorder incl. drag-into/out-of-groups and cross-window moves,
Vault sessions dragged onto panes to RESUME them, Finder file drops
with a Shift-toggled text-vs-preview policy); the workspace-row context
menu alone has ~30 items and every management surface has one; the
icon inventory runs from reload⇄stop swaps to hover-only close
buttons; color is a system (16-swatch palette, rail/fill styles,
dark-mode brightening, WCAG-adaptive foregrounds, semantic status-lane
colors). Biggest correction: CONCEPTS.md's "dock = terminal controls"
was legacy framing — the Dock is a window-global secondary SPLIT AREA
(full terminal/browser panes that survive workspace switches), seeded
optionally from dock.json, trust-gated only for project configs, with
NO dock.* verb family (generic verbs + --placement dock). CONCEPTS
corrected in place. MACOS-UX ends with a proposed mirror order
(browser-chrome state polish → hover affordances → context menus →
workspace colors → tab icons → DnD → minimal Dock) — awaiting the
human's pick.

### Comfort mirror ①: browser chrome state polish (2026-07-24)

First slice of the MACOS-UX mirror order. The URL bar now behaves like
the macOS omnibar: back/forward buttons disable (and dim, via GTK
sensitivity) when there is no history in that direction, the reload
button swaps to a stop button (`process-stop-symbolic`, and actually
stops the load) while a page is in flight, and an https page shows the
lock (`channel-secure-symbolic`) as the entry's primary icon. Synced
from `load-changed` + `notify::is-loading` per surface; the projection
(`BrowserURLBar.chromeState`) is shared with a new
`debug.browser_chrome` verb per the wiring/09 rule, so
browser-navigation-smoke asserts the rendered truth (8 → 14
assertions: history-edge sensitivity both ways, rest-state icon, http
= no lock, fresh-surface both-disabled). Verified visually on a live
https page: dimmed chevrons + lock in one shot.

### Comfort mirror ②: hover affordances — and the runaway-pointer trap (2026-07-24)

Sidebar rows gained the macOS hover comfort: a hover-revealed ✕ on
workspace/member rows (closes via the same path as workspace.close) and
a hover-revealed ＋ on group headers (workspace.group.new_workspace
path). Implementation is pure CSS — `.cmux-hover-reveal { opacity: 0 }`
+ `row:hover` — so no motion-controller escape hatch, and the buttons
are always present, keeping rows structure-stable (wiring/09 rule 2).
Verified by screenshot (only the hovered row shows its ✕) and by
xdotool click-through; workspace-groups-smoke → 50.

**The trap this hunt paid for — bare xdotool drove the HUMAN'S
desktop.** The new suite block called `xdotool` without a DISPLAY
prefix; lib.sh never exported DISPLAY, so every synthetic click went to
the ambient display — on this dev box, `:0`, the developer's live GNOME
session (pointer jumps + stray clicks at fixed coordinates across
several suite runs) — while the suite's own window, on its private
Xvfb, received nothing. Every observed "flake" (clicks that worked on
scratch but not in the suite, a chevron that worked only when manually
prefixed, counts that moved between runs) was this one bug wearing
different costumes; three plausible theories (first-frame latency,
display reuse, screen size) were each disproven by isolated replication
before the real cause surfaced. Fixes: lib.sh `start_xvfb` now
`export DISPLAY="$XDISPLAY"` so a bare xdotool can never escape the
suite again, and the suites keep their explicit prefixes. Lesson for
LESSONS-style recall: when a synthetic-input assertion flakes, verify
WHICH DISPLAY the input lands on before theorizing about timing.

### Comfort mirror ③: sidebar context menus (2026-07-24)

Workspace rows and group headers answer right-click with real menus —
the macOS core slice: rows get Rename Workspace… / Close Other
Workspaces / New Group from Workspace… ⇄ Remove from Group (by
membership) / Copy Workspace ID / Close Workspace (destructive-styled);
headers get New Workspace in Group / Rename Group… / Pin⇄Unpin /
Collapse⇄Expand / Ungroup / Delete Group. Mechanics: one window-level
GtkGestureClick (button 3, bubble phase — panes keep their own
right-clicks), `gtk_widget_pick` + ancestor walk to the
navigation-sidebar row, popover of flat buttons in the profile-popover
idiom (SidebarContextMenu.swift); GtkGesture pointers stay opaque
through the C importer like GtkStyleProvider. Menu CONTENT is a pure
projection (SidebarContextMenuModel) shared verbatim with a new
`debug.sidebar_menu` verb, and every action routes through the same v2
implementations the socket verbs use — the menu is just another caller.
Sidebar rows now also expose `pinned`/`in_group` via debug.sidebar_rows.
Suite → 54: three menu-projection assertions plus a real right-click →
"Remove from Group" click-through; verified visually (member and header
menus, destructive items in red).

### Comfort mirror ④: workspace colors (2026-07-24)

Workspaces carry identity colors, macOS-parity end to end: the EXACT
16-swatch palette (`WorkspacePalette`, the macOS originalPRPalette
hexes), reachable from the row context menu as "Workspace Color…" — a
popover of 16 colored circles + Clear Color + strict-hex Custom… — and
rendered as a LEFT RAIL on the row (`box-shadow: inset 4px`,
`.cmux-wsrail-N` classes generated per color on one regenerated
provider; `SidebarColorStyle.sync` walks the sidebar rows by projection
index in the AttentionStyle widget-writes-only idiom, skipped while the
notifications page holds the slot). Headers get "Group Color…" with the
same palette — a picker macOS itself lacks (its group colors are
socket/config-only). `TerminalTab.customColor` persists in session v3;
debug.sidebar_rows exposes color_hex on workspace rows. Suite → 58:
menu projections, a full right-click → palette → swatch click-through
asserting the rendered color, and a save/restart round-trip. One
coordinate lesson absorbed in the same commit: inserting a menu item
shifted the existing Remove-from-Group click-through by one slot — the
suite's measured y moved with it, a reminder that click-through
coordinates are part of the menu's contract.
