# macOS feature parity tracker

Running checklist of everything the macOS cmux exposes vs. what the Linux
port implements. **Update this in the same commit as any change that adds,
stubs, or intentionally skips a feature.** Evidence and dates live in
[PROGRESS.md](PROGRESS.md); this file is only the current state.

Legend: ✅ done · 🟡 partial (note says what's missing) · ❌ missing ·
— not planned / not applicable on Linux.

## Control socket — v2 methods

### system / window / workspace

| Method | Status | Notes |
|---|---|---|
| system.ping / capabilities / identify | ✅ | capabilities reflects real method list since phase 5b |
| system.tree | ❌ | |
| window.list | ✅ | single window; stable app-lifetime id |
| window.create / close / current / focus | ❌ | multi-window is a later phase |
| workspace.list / create / select / current / close | ✅ | create honors `focus:false` (background) |
| workspace.rename / next / previous / last | ❌ | |
| workspace.reorder / move_to_window / action | ❌ | |

### surface / pane

| Method | Status | Notes |
|---|---|---|
| surface.list / create / close / split | ✅ | |
| surface.send_text / send_key / read_text | ✅ | read_text: screenful ending at cursor; no scrollback capture yet |
| surface.focus / current | ❌ | focus-intent verbs; need focus policy port |
| surface.move / reorder / refresh / clear_history | ❌ | |
| surface.health / action / drag_to_split / trigger_flash | ❌ | |
| pane.create / list / focus / surfaces | ✅ | one surface per pane (no stacked surfaces yet) |
| pane.break / join / last / resize / swap | ❌ | pane.resize would pair well with divider persistence |

### browser — navigation & automation

| Method | Status | Notes |
|---|---|---|
| browser.open_split / navigate / back / forward / reload | ✅ | |
| browser.url.get / get.title | ✅ | |
| browser.identify | ✅ | Linux extension (not on macOS) |
| browser.eval | ✅ | async via WebKitGTK `call_async_javascript_function`; promises awaited, undefined sentinel |
| browser.snapshot | ✅ | role/name tree + `@eN` element refs, same script as macOS |
| browser.wait | ✅ | selector / url_contains / text_contains / load_state / function; ⚠ socket transport caps effective timeout at ~14s |
| browser.click / dblclick / hover / focus | ✅ | 3× retry + not-found diagnostics like macOS |
| browser.fill / type / press / keydown / keyup | ✅ | |
| browser.check / uncheck / select | ✅ | |
| browser.scroll / scroll_into_view | ✅ | |
| browser.get.text / html / value / attr / count / box / styles | ✅ | |
| browser.is.visible / enabled / checked | ✅ | |
| snapshot_after (post-action snapshot merge) | ✅ | on all action verbs |
| browser.screenshot | ❌ | WebKitGTK `get_snapshot` → PNG is feasible; next candidate |
| browser.find.role / text / label / placeholder / alt / title / testid / first / last / nth | ❌ | |
| browser.frame.select / main | ❌ | eval envelope has no frame prelude yet |
| browser.focus_webview / is_webview_focused | ❌ | focus-intent verbs |
| browser.dialog.accept / dismiss | ❌ | needs WebKit script-dialog signal handler |
| browser.cookies.get / set / clear | ❌ | WebKitCookieManager |
| browser.storage.get / set / clear | ❌ | |
| browser.console.list / clear, browser.errors.list | ❌ | needs console-message capture |
| browser.network.requests / route / unroute | ❌ | |
| browser.download.wait | ❌ | |
| browser.tab.list / new / switch / close | ❌ | |
| browser.viewport.set / geolocation.set / offline.set | ❌ | |
| browser.highlight / addscript / addstyle / addinitscript | ❌ | |
| browser.state.save / load, trace.*, screencast.*, input_* | ❌ / — | input_* is not_supported on macOS too |

### notifications / app / auth / debug

| Method | Status | Notes |
|---|---|---|
| notification.create / list / clear | ✅ | + desktop delivery, withdraw on workspace close |
| notification.create_for_surface / create_for_target | 🟡 | v1 notify_surface / notify_target exist; v2 aliases missing |
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
| Divider position persistence across restart | ❌ | session schema v3 candidate; positions survive in-session rebuilds only |
| Session persistence (layout, cwds, URLs, selection) | ✅ | XDG JSON, schema v2 |
| Terminal surfaces | 🟡 | VTE stands in; Ghostty fidelity via Zig C-shim is the plan (keys, OSC 9/777, scrollback API) |
| Browser panes (WebKitGTK) | ✅ | |
| Terminal find overlay | ❌ | VTE has search API; UI missing |
| Command palette | ❌ | |
| Tab drag-and-drop (reorder, tear-off, cross-window) | ❌ | |
| Multi-window | ❌ | |
| Workspace pinning / rename UI | ❌ | |
| Sidebar metadata pills (git branch, PR, ports, status/progress) | ❌ | pairs with report_* verbs |
| Update pill / Sparkle auto-update | — | Flatpak packaging phase owns updates |
| Keyboard shortcuts | 🟡 | new tab, splits, close pane; no palette/full map |
| CLI (shared `CLI/cmux.swift`) | ✅ | builds unmodified on Linux; global flags before subcommand |
| Claude hooks (Stop/Notification → cmux claude-hook) | ✅ | |

## Known wire-level deviations

- `browser.wait` with `timeout_ms` > ~14s is cut off by the socket
  dispatcher's 15s transport timeout (macOS pumps the run loop instead).
  Raise the transport budget if long waits become a real workflow.
- `--json new-workspace` prints `OK workspace:N`, not JSON — shared-CLI
  behavior, identical on macOS; upstream ergonomics, not a port gap.
- Timeout replies for v2 requests return `"id": null` (the transport
  doesn't parse the request id).
