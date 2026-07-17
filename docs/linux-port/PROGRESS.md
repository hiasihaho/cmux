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
