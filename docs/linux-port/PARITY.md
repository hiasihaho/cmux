# macOS feature parity tracker

Running checklist of everything the macOS cmux exposes vs. what the Linux
port implements. **Update this in the same commit as any change that adds,
stubs, or intentionally skips a feature.** Evidence and dates live in
[PROGRESS.md](PROGRESS.md); this file is only the current state.

Legend: ✅ done · 🟡 partial (note says what's missing) · ❌ missing ·
— not planned / not applicable on Linux.

Parity runs both ways: the **Linux-only additions** section near the end
lists what this port has that macOS does not, and
[FEATURES.md](FEATURES.md) describes them. Method-level gaps below were
measured by diffing the two capability lists, not estimated.

## Control socket — v2 methods

### system / window / workspace

| Method | Status | Notes |
|---|---|---|
| system.ping / capabilities / identify | ✅ | capabilities reflects real method list since phase 5b |
| system.tree | ❌ | |
| window.list | ✅ | single window; stable app-lifetime id |
| window.create / close / current / focus | ❌ | multi-window is a later phase |
| workspace.list / create / select / current / close | ✅ | create honors `focus:false` (background) |
| workspace.rename / next / previous / last | ✅ | rename pins a custom title (OSC updates stop overwriting; persisted in session); next/previous wrap; last uses the selection-history stack |
| workspace.reorder / move_to_window / action | ❌ | |

### surface / pane

| Method | Status | Notes |
|---|---|---|
| surface.list / create / close / split | ✅ | |
| surface.send_text / send_key / read_text | ✅ | dispatch by surface kind (VTE + ghostty). Ghostty panes: raw PTY writes; read_text with full scrollback (`--scrollback`) on BOTH backends since 2026-07-22 (VTE reads the retained buffer via get_text_range_format); exited shells error `unavailable` |
| surface.focus / current | ❌ | focus-intent verbs; need focus policy port |
| surface.move / reorder / refresh / clear_history | ❌ | |
| surface.health / action / drag_to_split / trigger_flash | ❌ | |
| pane.create / list / focus / surfaces | ✅ | panes hold several surfaces behind an AdwTabView strip since 2026-07-21; `surface_count`/`surface_refs`/`selected_surface_ref` report the real list |
| pane.zoom | ✅ | Linux-only socket verb for macOS's Toggle Pane Zoom command |
| pane.break / join / last / resize / swap | ❌ | pane.resize would pair well with divider persistence |

### browser — navigation & automation

| Method | Status | Notes |
|---|---|---|
| browser.open_split / navigate / back / forward / reload | ✅ | |
| browser.url.get / get.title | ✅ | |
| browser.identify | ✅ | Linux extension (not on macOS) |
| browser.eval | ✅ | async via WebKitGTK `call_async_javascript_function`; promises awaited, undefined sentinel. All automation verbs share the envelope: main world first, isolated-world (`cmuxAutomation`) retry on CSP eval-refusal — strict-CSP sites (GitHub) work since 2026-07-21. Deviation: on such sites eval runs in the isolated world, so page JS globals are invisible (WKWebView is CSP-exempt and sees them everywhere) |
| browser.snapshot | ✅ | role/name tree + `@eN` element refs, same script as macOS |
| browser.wait | ✅ | selector / url_contains / text_contains / load_state / function; ⚠ socket transport caps effective timeout at ~14s |
| browser.click / dblclick / hover / focus | ✅ | 3× retry + not-found diagnostics like macOS |
| browser.fill / type / press / keydown / keyup | ✅ | |
| browser.check / uncheck / select | ✅ | |
| browser.scroll / scroll_into_view | ✅ | |
| browser.get.text / html / value / attr / count / box / styles | ✅ | |
| browser.is.visible / enabled / checked | ✅ | |
| snapshot_after (post-action snapshot merge) | ✅ | on all action verbs |
| browser.screenshot | ✅ | WebKitGTK `get_snapshot` (visible region) → GdkTexture → PNG base64; unmapped background-workspace webviews can't be snapshotted → stable `invalid_state` error (macOS captures offscreen views) |
| browser.find.role / text / label / placeholder / alt / title / testid / first / last / nth | ✅ | same finder scripts + cssPath ref allocation as macOS; frame-aware. Deviation: find.last/nth return the element's own CSS path — macOS returns `<query>:nth-of-type(n)`, which can point at a different element than the one matched |
| browser.frame.select / main | ✅ | eval envelope now has the macOS frame prelude (`document` shadowed with the same-origin iframe's contentDocument); all automation verbs are frame-aware. Deviation: select validates top-relative (macOS validates inside the currently selected frame, breaking direct sibling-frame switches) |
| browser.focus_webview / is_webview_focused | ❌ | focus-intent verbs |
| browser.dialog.accept / dismiss | ✅ | macOS JS-hook approach (alert/confirm/prompt overridden into a FIFO queue + defaults), armed lazily by the first dialog verb; native GTK dialogs are NOT deferred pre-arm (macOS defers via WKUIDelegate) |
| browser.cookies.get / set / clear | ✅ | WebKitNetworkSession cookie manager + SoupCookie, async chained add/delete; same wire shape (name/value/domain/path/secure/session_only/expires) |
| browser.storage.get / set / clear | ✅ | local/session; get without key returns the full map |
| browser.console.list / clear, browser.errors.list | ✅ | **Capture v2** (2026-07-21): document-start user script (CSP-exempt user-agent script, no eval) posts through a script message handler into a per-surface app-side ring buffer. Captures from page load on every site incl. strict-CSP — strictly better than macOS's lazily-armed wrap, which only sees entries after the first call. Note: entries logged by our own isolated-world automation aren't captured (we record what the PAGE logs) |
| browser.network.requests / route / unroute | ❌ | |
| browser.download.wait | 🟡 | path-based wait works (non-blocking poll); the no-path event branch times out — macOS's download-event queue is never populated either (no writer exists). Real downloads need a decide-destination handler (future) |
| browser.tab.list / new / switch / close | ❌ | |
| browser.viewport.set / geolocation.set / offline.set | ❌ | |
| browser.highlight / addscript / addstyle / addinitscript | ❌ | |
| browser.state.save / load, trace.*, screencast.*, input_* | ❌ / — | input_* is not_supported on macOS too |

### browser — not yet ported

Measured by diffing the two capability lists (2026-07-21): **92 v2 methods
are implemented on both**, 47 are macOS-only, and a further 29 macOS
`debug.*` methods are UI-test harness hooks rather than port targets.

| Group | Missing on Linux |
|---|---|
| script injection | `addinitscript` `addscript` `addstyle` |
| network control | `network.requests` `network.route` `network.unroute` `offline.set` |
| device emulation | `viewport.set` `geolocation.set` |
| trusted input | `input_keyboard` `input_mouse` `input_touch` (WebDriver covers the real-input case today) |
| capture / tracing | `screencast.start` `screencast.stop` `trace.start` `trace.stop` |
| state | `state.save` `state.load` |
| misc | `focus_webview` `is_webview_focused` `highlight` |

### notifications / app / auth / debug

| Method | Status | Notes |
|---|---|---|
| notification.create / list / clear | ✅ | + desktop delivery, withdraw on workspace close |
| notification.create_for_surface / create_for_target | ✅ | v2 verbs with macOS param/result shapes; for_surface defaults to the selected workspace, for_target requires workspace_id |
| app.focus_override.set / simulate_active | ❌ | |
| auth.login | — | socket is 0600 per-user; auth not required |
| debug.* (~30 verbs) | ❌ | port alongside an e2e test harness, not before |

## Control socket — v1 verbs

| Group | Status | Notes |
|---|---|---|
| ping / auth / help | ✅ | |
| list/new/select/current/close_workspace | ✅ | |
| send / new_split | ✅ | |
| notify / notify_surface / notify_target / list_notifications / clear_notifications | ✅ | |
| browser_back / browser_forward / browser_reload / navigate / get_url / open_browser | 🟡 | CLI maps these to v2 equivalents; bare-v1 aliases unimplemented |
| read_screen / read_terminal_text / send_key / focus_* / close_* / pin / rename / mark_read … | ❌ | long tail; add when the CLI or an agent actually hits them |
| report_* telemetry (git branch, pwd, PR, ports, status, progress, log, meta) | ❌ | needs sidebar metadata UI first; keep off-main when ported |
| input-simulation & drag-pasteboard verbs | — | macOS e2e-test plumbing |

## UI / app features

| Feature | Status | Notes |
|---|---|---|
| Workspace sidebar + attention badges | ✅ | GtkListBox; selection-echo guard for socket mutations |
| Notifications page + unread counts | ✅ | |
| Desktop notifications | ✅ | GNotification; suppressed when workspace selected; withdrawn on close |
| Split panes (GtkPaned tree) | ✅ | fresh splits balance 50/50 at first allocation (phase 5b fix) |
| Divider position persistence across restart | ✅ | stored per `split` as a **fraction** of the paned's extent, matching macOS (`SessionSplitLayoutSnapshot.dividerPosition`, clamped 0…1). Applied from a tick callback once the paned has a size, since a fresh paned reports 0. Optional field, so v3 files written before it still decode |
| Session persistence (layout, cwds, URLs, selection) | ✅ | XDG JSON, **schema v3** — normalized like macOS (flat `surfaces` array + layout referencing ids), so multi-tab panes round-trip. v2 files migrate on read. Browser panes additionally restore zoom and a *navigable* back/forward list (see Linux-only below) |
| Terminal working directory tracking (Ghostty) | ✅ | cmux passes the real `gethostname()` as `HOSTNAME` to spawned shells, so Ghostty's OSC 7 host validation accepts the report. A stale inherited `HOSTNAME` otherwise silences cwd tracking for the whole session |
| Terminal scrollback persistence | ✅ | full history is stored (ANSI-safe truncation to a budget, as macOS does) **out of band** — one file per surface next to the session, so the limit is configurable up to unlimited (`CMUX_SCROLLBACK_LIMIT=0`); macOS's budget exists because its scrollback rides inline in the session document. Replayed on restore through the fork's `inject_output` message, so the text is parsed as terminal *output* and never reaches the shell as input; macOS replays via a temp file + environment variable + shell integration. Replay is a restartable poll gated on readiness (Ghostty: mapped; VTE: exists), so a workspace first opened hours after the restart still gets its text. Both backends since 2026-07-22 — VTE captures via get_text_range_format and replays via vte_terminal_feed |
| Terminal surfaces | ✅ | **Ghostty is the default** in shim-linked builds (CMUX_GHOSTTY=1; CMUX_TERM=vte falls back to VTE): titles/pwd/bell/focus, send/read verbs incl. scrollback, shell integration, auto-close on exit, resize fixed (fork renderer patch Darwin-gated). Remaining gap: eager background spawn (panes in never-shown workspaces start on first selection) |
| Browser panes (WebKitGTK) | ✅ | |
| Browser profiles (isolated cookie/storage/cache spaces) | ✅ | one `WebKitNetworkSession` per profile (data beside the session file), same verbs/payloads/slug rules as macOS's BrowserProfileStore; persistent cookies via explicit sqlite storage; popups inherit the opener's container via related-view; v3 snapshots carry the assignment. Linux extension: `browser open --profile <slug|id|name>` (macOS selects via popover — flag is an upstreaming candidate). Deviations: `clear`/`delete` require the profile's panes closed (macOS clears live stores); no profile popover UI yet; per-profile history n/a (Linux has no history file) |
| Browser find-in-page | ✅ | WebKitFindController behind a GTK find bar (Ctrl+Shift+F), match counter, next/prev with wrap, case toggle; also socket-drivable (`browser find-in-page`) so an agent and the human share one controller |
| Terminal find overlay | ✅ | Ghostty panes: built-in search overlay via the shim (Ctrl+Shift+F / header magnifier) — needle entry, next/prev, highlight, Esc-to-close all native. VTE panes: no overlay (VTE search API unused) |
| Browser URL / address bar | ✅ | editable entry above each browser pane; follows navigations, and typed text uses macOS's own resolver rules (`resolveBrowserNavigableURL` — loopback before generic parsing, spaces mean search, bare domain → https), falling through to a search engine (`CMUX_SEARCH_URL`, default Google as on macOS) |
| Pane zoom ("focus mode") | ✅ | Ctrl+Shift+Z, toolbar button, and `cmux zoom-pane` / `pane.zoom` over the socket (macOS has the command but no socket verb). Zooming a *different* pane switches to it rather than un-zooming; deliberately not persisted |
| Browser screencast (capture mode) | ❌ | macOS exposes `browser.screencast.start` / `.stop` over the socket — continuous frame capture, distinct from the one-shot `browser.screenshot` we have |
| Browser tabs as a socket surface | ✅ | `browser.tab.list / new / switch / close` (2026-07-21), addressing the real per-pane tab model. `list` reports each tab's index **within its pane** plus `selected`/`focused`; `new` resolves its anchor the way macOS does (explicit pane → explicit surface → focused surface) |
| Command palette | ❌ | |
| Tab drag-and-drop (reorder, tear-off, cross-window) | ❌ | |
| Multi-window | ❌ | |
| Workspace pinning / rename UI | ❌ | |
| Sidebar metadata pills (git branch, PR, ports, status/progress) | ❌ | pairs with report_* verbs |
| Update pill / Sparkle auto-update | — | Flatpak packaging phase owns updates |
| Keyboard shortcuts | 🟡 | 12 of macOS's 28 commands bound: new workspace (Ctrl+Shift+T), split right/down (D/S), find (F), zoom (Z), close pane (W), **open browser pane (B)**, **browser devtools (I)**, **next/previous workspace (Ctrl+Shift+PageDown/Up)**, **next/previous pane (Ctrl+Tab / Ctrl+Shift+Tab)**. Still unbound though the verb exists: rename workspace (needs a text dialog). Not implemented at all: directional pane focus (`focusLeft/Right/Up/Down`), next/prev surface, jump-to-unread, open folder, JS console, flash, multi-window |
| CLI (shared `CLI/cmux.swift`) | ✅ | builds unmodified on Linux; global flags before subcommand |
| Claude hooks (Stop/Notification → cmux claude-hook) | ✅ | |

## Linux-only additions (no macOS counterpart)

Things this port has that macOS cmux does not. Full descriptions and the
✅/★/⚙ overview live in [FEATURES.md](FEATURES.md); this is the index, so
that a parity read never leaves the impression the port is only catching
up.

| Addition | Notes |
|---|---|
| `search.panes` (`cmux search`) | text search across **every** pane at once — terminal screen/scrollback and rendered browser `innerText` in one query, with per-hit surface/workspace/pane refs under `--json`. macOS has per-pane find only |
| Native browser history across restarts | v3 persists WebKitGTK's own session-state blob, so a restored pane has a *real* back/forward list. macOS stores history URLs but has to emulate navigation with shadow stacks (`restoredBackHistoryStack`), because WKWebView cannot rebuild a list from URLs |
| `browser.inspect` | Web Inspector hosted in a cmux pane via public WebKitGTK API. macOS has DevTools too (`BrowserPanel.toggleDeveloperTools`, private `_inspector` selectors) — the difference is presentation and API surface, so this is parity-with-a-twist rather than a pure addition |
| `browser.find_in_page` | the same find controller the UI bar uses, exposed over the socket, so an agent and the human highlight identically |
| `browser.identify` | surface/url/title for a browser pane in one call |
| Popup burst budget | popups become tabs, capped per opener per 10s. macOS routes popups (richer: middle-click intent, modifier flags, open-externally rules) but has no budget |
| `browser screenshot --full-page` | whole-document capture; both platforms default to the visible viewport, macOS exposes no full-page flag |
| Navigation barrier on `goto`/`back`/`forward`/`reload` | the verb holds its response until the new document commits. macOS has the same latent race (`v2BrowserNavigate` → `navigateSmart` → immediate `.ok`) — see [UPSTREAM.md](UPSTREAM.md) §4b |
| Quadratic CLI transfer fix | in the **shared** `CLI/cmux.swift`, so macOS benefits once merged — UPSTREAM.md §4a |

## Deliberate deviations from macOS (upstream candidates)

Dogfood cycle 4 found these behaviors broken in the inherited macOS
scripts; the Linux port fixes them and macOS should adopt the same:

- `browser.select` validates that an `<option>` matches before assigning
  (macOS silently clears the selection and reports OK).
- `browser.dblclick` fires `click, click, dblclick` (macOS fires only the
  dblclick event, so onclick handlers never run).
- `browser.press` emulates text insertion for single printable keys on
  editable targets (synthetic key events are untrusted; on macOS press is
  a dispatch-only no-op for text entry).
- `browser.snapshot` accessible-name computation honors `label[for]` and
  wrapping `<label>` elements (macOS names checkboxes "on").

## Known wire-level deviations

- ~~`browser.wait` with `timeout_ms` > ~14s is cut off by the 15s
  transport timeout~~ — **fixed 2026-07-21**: both the socket dispatcher
  and the CLI now derive their budget from the request's own `timeout_ms`.
  The old behavior was worse than a truncation, because the transport
  timeout was worded identically to a genuine condition-not-met.
- `--json new-workspace` prints `OK workspace:N`, not JSON — shared-CLI
  behavior, identical on macOS; upstream ergonomics, not a port gap.
- Timeout replies for v2 requests return `"id": null` (the transport
  doesn't parse the request id).
- Browser panes in never-selected background workspaces run at a 0×0
  viewport (GtkStack doesn't allocate unmapped children). Event-driven
  verbs work; layout-dependent reads (snapshot visibility filtering,
  `get.box`) see degenerate geometry until the workspace is first shown.
