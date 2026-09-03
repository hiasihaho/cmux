# macOS feature parity tracker

Running checklist of everything the macOS cmux exposes vs. what the Linux
port implements. **Update this in the same commit as any change that adds,
stubs, or intentionally skips a feature.** Evidence and dates live in
[PROGRESS.md](PROGRESS.md); this file is only the current state.

Legend: ✅ done · 🟡 partial (note says what's missing) · ❌ missing ·
— not planned / not applicable on Linux.

The prioritized work-down list of these gaps lives in [GAPS.md](GAPS.md).
Parity runs both ways: the **Linux-only additions** section near the end
lists what this port has that macOS does not, and
[FEATURES.md](FEATURES.md) describes them. Method-level gaps below were
measured by diffing the two capability lists, not estimated.

Scope: this file tracks **two-way wire parity with the macOS app** only.
The three-way *concept* comparison against upstream's Rust core
(cmux-tui) — the stamped strategy snapshot behind any future
frontend-over-the-core decision — lives in [COMPARISON.md](COMPARISON.md).

Baseline: ✅ marks are measured against upstream at our merge-base
`25dc913922` (2026-07-16). Upstream drift since then (4,067 commits,
audited 2026-08-19) is tracked in [DRIFT-2026-08.md](DRIFT-2026-08.md)
until the next upstream merge re-baselines this file.

## Control socket — v2 methods

### system / window / workspace

| Method | Status | Notes |
|---|---|---|
| system.ping / capabilities / identify | ✅ | capabilities matches the dispatcher — guarded since 2026-07-24 by `capabilities-sweep.py`'s self-check (exits 1 on drift), after the hand-maintained list was found 16 methods stale |
| system.tree | ✅ | one-call topology with active/caller markers (2026-07-22); the CLI's tree renderer works unchanged |
| window.list | ✅ | single window; stable app-lifetime id |
| window.create / close / current / focus | ❌ | multi-window is a later phase |
| workspace.list / create / select / current / close | ✅ | create honors `focus:false` (background) |
| workspace.rename / next / previous / last | ✅ | rename pins a custom title (OSC updates stop overwriting; persisted in session); next/previous wrap; last uses the selection-history stack |
| workspace.group.* (17 verbs) | 🟡 | full wire parity **with 2026-07-16 macOS**; upstream then changed the removal semantics (#8542: bare `delete` dissolves, `close_workspaces:true` closes, result gains `operation`/`kept_workspace_count`; #8925: anchor close promotes the next member instead of dissolving; `create` dropped ambient child derivation) — see [DRIFT-2026-08.md](DRIFT-2026-08.md) A1–A3 and the GAPS Now row. Otherwise: anchor-owned groups, membership as a relation, contiguity + pin-tier ordering, session persistence; `workspace.create` honors `group_id`/`group_placement`/`group_reference_workspace_id`. Sidebar renders sections (chevron headers, indented members, collapsed counts, attention aggregation; `debug.sidebar_rows` mirrors the render). ✅ comfort slice complete 2026-07-24 (mirrors ③④⑥): colors/icons rendered, context menus, palette pickers, drag membership (features/04) |
| workspace.reorder | ✅ | macOS wire (workspace_id + exactly one of index/before/after + dry_run); before/after adopt the neighbor's group membership, before-a-header stays top-level, anchors move their whole group slot; shared core with sidebar drag-and-drop |
| workspace.move_to_window / action | ❌ | |

### surface / pane

| Method | Status | Notes |
|---|---|---|
| surface.list / create / close / split | ✅ | list enumerates ALL surfaces incl. background tabs since 2026-07-22 — it fed the shared CLI's surface resolution, which failed for non-selected tabs while it listed only each pane's leaf |
| surface.send_text / send_key / read_text | ✅ | dispatch by surface kind (VTE + ghostty). Ghostty panes: raw PTY writes; read_text with full scrollback (`--scrollback`) on BOTH backends since 2026-07-22 (VTE reads the retained buffer via get_text_range_format); exited shells error `unavailable` |
| surface.focus | ✅ | selects workspace, raises pane tab, moves focus (2026-07-22); `current` still ❌ |
| surface.clear_history | ✅ | ED 3 fed as output — one escape, both backends (2026-07-22) |
| surface.move / reorder | ✅ | tab moves across panes AND workspaces as pure model mutations — the pane-tab reconciliation reparents the live widget, so terminals keep running across the move (2026-07-22). refresh still ❌ |
| surface.respawn | ✅ | `respawn-pane` (tmux `-k` semantics), both backends 2026-07-22. VTE: in place — old child killed via the spawn-callback pid, same VteTerminal, buffer intact. Ghostty: macOS's replace-and-replay — same surface id, `new_with_command` (shim increment 3), captured buffer replayed, cwd via OSC 7 |
| surface.trigger_flash | ✅ | double opacity dip on the pane container (2026-07-22) |
| surface.health / action / drag_to_split | ❌ | |
| pane.create / list / focus / surfaces | ✅ | panes hold several surfaces behind an AdwTabView strip since 2026-07-21; `surface_count`/`surface_refs`/`selected_surface_ref` report the real list |
| pane.zoom | ✅ | Linux-only socket verb for macOS's Toggle Pane Zoom command |
| pane.last | ✅ | tmux last-pane toggle; history fed by the GTK focus funnel (2026-07-22) |
| tab.action / surface.action | 🟡 | rename/clear_name (pinned per-surface titles, persisted), close_left/right/others, new_terminal_right/new_browser_right, reload (2026-07-22). Not yet: duplicate, pin/unpin, mark_read/unread, move/detach-to-workspace, toggle_full_width — macOS's remaining action keys |
| pane.break / join / resize / swap | 🟡 | all four verbs work (2026-07-22): swap exchanges pane contents in place, resize walks to the owning divider (cells ≈ 10/18px), break→new workspace, join delegates to surface.move. Limitation: relocating a never-tabbed Ghostty pane respawns its shell (GAPS row; roadmap/05) |

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
| browser.tab.list / new / switch / close | ✅ | per-pane AdwTabView tabs (2026-07-21) |
| browser.viewport.set / geolocation.set / offline.set | ❌ | |
| browser.highlight | ✅ | 2s element outline via the selector-verb envelope (2026-07-22). addscript/addstyle/addinitscript: the merged CLI no longer sends them — dropped from tracking |
| browser.state.save / load, trace.*, screencast.*, input_* | ❌ / — | input_* is not_supported on macOS too |
| Passkeys / WebAuthn in browser panes | 🟡 | macOS: native (WKWebView + ASAuthorization, iCloud Keychain, v0.64). Linux: WebKitGTK ships no WebAuthn (PASSKEYS.md), so cmux provides the client layer itself — document-start polyfill + reply-capable `cmuxWebAuthn` handler + software authenticator (ES256/swift-crypto, attestation `none`, resident keys, vault 0600). Behind `CMUX_WEBAUTHN=1`; consent dialog per ceremony (`CMUX_WEBAUTHN_AUTOAPPROVE=1` for suites/dev). Verified live: webauthn.io register + authenticate 2026-09-01. Suite `webauthn-smoke.sh` (18, incl. RP-grade signature verification). Vault encrypted at rest 2026-09-02 (P1b: AES-GCM, key from gnome-keyring on host / Secret portal under flatpak, v1 migration with 0600 `.v1.bak`, honest plaintext fallback). Missing vs macOS: hardware keys/hybrid (planned via credentialsd backend), conditional mediation/autofill, cross-origin iframes |

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
| **Claude Code agent teams** (`cmux claude-teams` + tmux shim) | ✅ | end-to-end verified 2026-07-22: a real Claude teammate spawned as a native split, ran its command, was captured and shut down. The launchers and `__tmux-compat` are shared-CLI code; the server side needed exactly two additions — `surface.current` and the `focused` block in `system.identify` (the launcher builds the shim's TMUX identity from it; without it spawns die with "Could not determine current tmux pane/window"). Guarded by `tmux-compat-smoke.sh`. codex-teams / omc / omo / omx ride the same surface, unverified individually |
| surface.current | ✅ | macOS wire shape (window/workspace/pane/surface ids + refs + surface_type); the tmux shim resolves every list/target/send through it |
| system.identify `focused` block | ✅ | macOS's exact envelope, additive next to the port's flat fields |
| notification.create_for_caller / jump_to_unread / mark_read / dismiss / open | 🟡 | the 2026-07-22 capabilities sweep: upstream's CLI sends these for notify/jump-to-unread/mark-notification-read/dismiss-notification/open-notification. **Deviation (found 2026-09-01):** macOS resolves the caller target through `TerminalNotificationCallerResolver` — if `preferred_surface_id` is not a panel of `preferred_workspace_id`, the SURFACE wins and the notification follows it to the workspace that owns it now (issue #7939, moved panes). The port takes the preferred workspace and stores the surface id unchecked, so a cross-workspace notify lands where it was addressed but carries a foreign surface id. Harmless downstream (open/jump guard with `contains(surfaceId:)`), but the two ports disagree about where a `cmux notify --workspace <other>` from inside a pane is delivered. GAPS row |
| settings.open / browser.zoom.set / browser.devtools.toggle / window.current | ✅ | sweep fixes — devtools.toggle aliases browser.inspect |
| Ephemeral browser panes | ✅ | `browser open --profile ephemeral` — a reserved virtual profile that mints a fresh `webkit_network_session_new_ephemeral()` per pane: no cookies/cache/storage on disk, dies with the pane. Never stored, never listed, reserved-name guards on create/rename/delete/clear. macOS has no equivalent reserved-name flag — Linux-port extension, upstreaming candidate. Parallel-dogfood batch 1 |
| Sibling team launchers (codex-teams / omc / omx / omo) | 🟡 | launcher+shim setup verified (teams-siblings-smoke, 15 assertions). With `codex` installed, codex-teams is verified to launch its real mechanism — `codex app-server --listen ws://127.0.0.1` binds (2026-07-24). Still skipped: an authenticated teammate *split* (needs interactive-authed codex) and omc/omx/omo (binaries absent). Findings: omc/omx resolve their binary before the shim; codex-teams uses app-server+watcher, not a tmux shim; and codex-teams **leaks its app-server child on teardown** (GAPS/UPSTREAM). claude-teams itself ✅ end-to-end |
| browser.console.show | ✅ | `browser devtools console` + Ctrl+Shift+J (2026-07-22). macOS flips WebKit's inspector to its Console tab via private selectors; WebKitGTK has no public tab flip (the inspector widget is not a WebKitWebView), so the Linux contract is "DevTools pane exists and is focused" — creates the split once, focuses on repeat calls (unlike browser.inspect, which always splits). Esc inside the inspector toggles the quick console on any tab |
| notification.create_for_surface / create_for_target | ✅ | v2 verbs with macOS param/result shapes; for_surface defaults to the selected workspace, for_target requires workspace_id |
| feed.push / feed.list / feed.jump / feed.permission.reply / feed.question.reply / feed.exit_plan.reply | ✅ | 2026-08-18, unblocks the agent-hook event pipeline (roadmap/08 item 1). The engine IS the shared macOS one (`CMUXAgentLaunch` WorkstreamStore/Event/Item; JSONL per instance at `<session-stem>-feed.jsonl`); wire shapes mirror `FeedSocketEncoding`. Blocking `feed.push` waits on a main-loop timeout (macOS parks a worker thread) — resolved by reply verbs, `expired` on timeout, same payloads. Source registry: unknown `_source` lands as `unknown` (never `claude` — authority inversion, olmo desk ask 2; DELIBERATE divergence from upstream's `?? .claude`, upstream candidate) and `cmux` is a registered source for desk-authored events. Socket-typed pane input (send verbs + auto-resume) emits a metadata-only tag under workstream `cmux-socket-input` (surface id + byte count, never content — desk ask 3, Linux-side). History load + JSONL persistence work (2026-08-18 late: needed the app-wide MainActor pump + a readiness gate on the verbs — PROGRESS); on-disk payloads follow upstream redaction (tool inputs/results redacted, prompts kept). Deviations: `feed.jump` = known-workstream check (macOS resolves hook-session records); no `tool_input_capabilities` codex enrichment; no agent-PID watcher. `feed-smoke.sh` (22) |
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
| Session persistence (layout, cwds, URLs, selection) | ✅ | XDG JSON, **schema v3** — normalized like macOS (flat `surfaces` array + layout referencing ids), so multi-tab panes round-trip. v2 files migrate on read. Browser panes additionally restore zoom and a *navigable* back/forward list (see Linux-only below). **Linux-side hardening 2026-09-02:** a surface's last non-empty cwd is remembered, so a terminal that cannot answer right now (an unrealized Ghostty GLArea reports an empty `pwd`) persists its last real directory instead of an empty one, and a substitution at restore is announced on stderr rather than made silently — the wedge that motivated it cost ~10 agent sessions whose transcripts are addressed by cwd |
| Terminal working directory tracking (Ghostty) | ✅ | cmux passes the real `gethostname()` as `HOSTNAME` to spawned shells, so Ghostty's OSC 7 host validation accepts the report. A stale inherited `HOSTNAME` otherwise silences cwd tracking for the whole session |
| Terminal scrollback persistence | ✅ | full history is stored (ANSI-safe truncation to a budget, as macOS does) **out of band** — one file per surface in a per-session directory (`<session-stem>-scrollback/`, 2026-07-22: the shared dirname/scrollback let co-located instances cross-prune), so the limit is configurable up to unlimited (`CMUX_SCROLLBACK_LIMIT=0`); macOS's budget exists because its scrollback rides inline in the session document. Replayed on restore through the fork's `inject_output` message, so the text is parsed as terminal *output* and never reaches the shell as input; macOS replays via a temp file + environment variable + shell integration. Replay is a restartable poll gated on readiness (Ghostty: mapped; VTE: exists), so a workspace first opened hours after the restart still gets its text. Both backends since 2026-07-22 — VTE captures via get_text_range_format and replays via vte_terminal_feed |
| Terminal surfaces | ✅ | **Ghostty is the default** in shim-linked builds (CMUX_GHOSTTY=1; CMUX_TERM=vte falls back to VTE): titles/pwd/bell/focus, send/read verbs incl. scrollback, shell integration, auto-close on exit, resize fixed (fork renderer patch Darwin-gated). Eager background spawn landed 2026-07-22 (shim ensure_started + host realize walk): never-shown workspaces have live shells. **Live-lock latch 2026-09-02**: the realize walk is now latched per started surface (`startedGhosttys`) — re-realizing a started GLArea every sync live-locked the daily on 2026-09-01 (INCIDENT-20260901-main-loop-livelock); ghostty-eager-spawn-latch 2/2 |
| Settings file + preferences window | ✅ | same file as macOS (`~/.config/cmux/cmux.json`) under a `linux` object; env > file > default; prefs window (Ctrl+comma) with backend ComboRow, scrollback slider (preset marks incl. unlimited), search-URL row. macOS has a far larger settings surface — this is the Linux-relevant subset |
| Browser panes (WebKitGTK) | ✅ | |
| Browser profiles (isolated cookie/storage/cache spaces) | ✅ | one `WebKitNetworkSession` per profile (data beside the session file), same verbs/payloads/slug rules as macOS's BrowserProfileStore; persistent cookies via explicit sqlite storage; popups inherit the opener's container via related-view; v3 snapshots carry the assignment. Linux extension: `browser open --profile <slug|id|name>`. **2026-08 drift:** upstream added its own CLI profile targeting (#8874) but wired it to `pane.create` (`profile`/`profile_id`/`profile_name` params, rich candidate errors) — not `browser.open_split` as we did; convergence decision at the next merge (DRIFT A13). Deviations: `clear`/`delete` require the profile's panes closed (macOS clears live stores); no profile popover UI yet; per-profile history n/a (Linux has no history file) |
| Browser find-in-page | ✅ | WebKitFindController behind a GTK find bar (Ctrl+Shift+F), match counter, next/prev with wrap, case toggle; also socket-drivable (`browser find-in-page`) so an agent and the human share one controller |
| Terminal find overlay | ✅ | Ghostty panes: built-in search overlay via the shim (Ctrl+Shift+F / header magnifier) — needle entry, next/prev, highlight, Esc-to-close all native. VTE panes: no overlay (VTE search API unused) |
| Browser URL / address bar | ✅ | editable entry above each browser pane; follows navigations, and typed text uses macOS's own resolver rules (`resolveBrowserNavigableURL` — loopback before generic parsing, spaces mean search, bare domain → https), falling through to a search engine (`CMUX_SEARCH_URL`, default Google as on macOS) |
| Pane zoom ("focus mode") | ✅ | Ctrl+Shift+Z, toolbar button, and `cmux zoom-pane` / `pane.zoom` over the socket (macOS has the command but no socket verb). Zooming a *different* pane switches to it rather than un-zooming; deliberately not persisted |
| Browser screencast (capture mode) | ❌ | macOS exposes `browser.screencast.start` / `.stop` over the socket — continuous frame capture, distinct from the one-shot `browser.screenshot` we have |
| Browser tabs as a socket surface | ✅ | `browser.tab.list / new / switch / close` (2026-07-21), addressing the real per-pane tab model. `list` reports each tab's index **within its pane** plus `selected`/`focused`; `new` resolves its anchor the way macOS does (explicit pane → explicit surface → focused surface) |
| Command palette | ❌ | |
| Tab drag-and-drop (reorder, tear-off, cross-window) | ❌ | |
| Multi-window | ❌ | |
| Workspace pinning / rename UI | 🟡 | rename dialog done (Ctrl+Shift+E, 2026-07-22); pinning UI still missing |
| Sidebar metadata pills (git branch, PR, ports, status/progress) | ❌ | pairs with report_* verbs |
| Update pill / Sparkle auto-update | — | Flatpak packaging phase owns updates |
| Keyboard shortcuts | 🟡 | 19 of macOS's 28 commands bound (2026-07-22): workspace/split/find/zoom/close/browser/devtools/workspace-nav/pane-nav as before, plus preferences (Ctrl+comma), directional pane focus (Ctrl+Shift+arrows), rename workspace dialog (Ctrl+Shift+E), jump-to-unread (Ctrl+Shift+U), open folder (Ctrl+Shift+O). Also JS console (Ctrl+Shift+J, 2026-07-22 — deliberately not macOS's Alt+Cmd+C: Ctrl+Shift+C is terminal copy, and Ctrl+Shift+J is Chrome/Firefox muscle memory on Linux). Missing: multi-window family — see GAPS.md |
| CLI (shared `CLI/cmux.swift`) | ✅ | builds unmodified on Linux; global flags before subcommand |
| Claude hooks (Stop/Notification → cmux claude-hook) | ✅ | |
| Agent auto-resume: Pi | ✅ | `cmux hooks pi install` writes a 572-line lifecycle extension; auto-resume verified END TO END in a pane on the dev instance (restart → `pi --session <id>` typed → context recalled). Deviation: the extension's `surface resume set` binding fails (`surface.resume.*` unimplemented, GAPS row); the older hook-store path carries it. An empty Pi session is never persisted, so a pane whose agent was started but unused resumes into "No session found" |
| Agent auto-resume: hermes profile scoping | ✅ | **Linux-side recovery of a macOS-only mechanism** (2026-09-03). Hermes keeps one session store PER PROFILE, so `hermes --resume <id>` under the default profile cannot see a session created under `hermes -p <name>`; macOS never hits it because its CLI rebuilds the resume command from the running process's argv, where `-p` survives. This port's table is fixed, so it recovers the profile by scanning `~/.hermes/profiles/*/sessions/` for the file that CLAIMS the id (content, not filename — the name carries a different timestamp) and emits `hermes -p <profile> --resume <id>`. Unknown id or unsafe profile name falls back to the plain command. `agent-resume-smoke` 13 |

| Agent session auto-resume on restore | ✅ | 2026-08-18: restored terminal surfaces whose agent session the shared-CLI hooks recorded get the agent's native resume command typed into the fresh shell (`AgentResume.swift`; per-surface exact matching — surface UUIDs persist in SessionStore v3; readiness-gated delivery mirroring the scrollback replay poll; resumed surfaces skip stale scrollback replay, macOS parity). Setting: `linux.autoResumeAgentSessions` / `CMUX_AUTO_RESUME` (default on; no preferences row yet). Deviations: fixed 14-agent command table only (record's launch command never executed, session ids charset-validated; no approval store/launcher scripts/custom bindings; no agentWasRunning gate). kimi verified live 2026-08-18 (`kimi --session <id>`, both ses_/session_ id shapes). Claude records additionally require UUID session ids — claude-compatible wrappers write ses_… shapes through the claude hooks and would misfire under `claude --resume`. `agent-resume-smoke.sh` (8) |

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
| `browser.webauthn.status / list / rm` (`cmux browser webauthn …`) | inspect and manage the P1a/P1b passkey vault: status (flag, count, encrypted/backend), list (metadata only — never private-key material), rm by credential id. Vault-level, no surface handle. macOS passkeys live in iCloud Keychain, so it has no counterpart; suite `webauthn-verbs-smoke` (12) |
| Popup burst budget | popups become tabs, capped per opener per 10s. macOS routes popups (richer: middle-click intent, modifier flags, open-externally rules) but has no budget |
| `browser screenshot --full-page` | whole-document capture; both platforms default to the visible viewport, macOS exposes no full-page flag |
| Navigation barrier on `goto`/`back`/`forward`/`reload` | the verb holds its response until the new document commits. macOS has the same latent race (`v2BrowserNavigate` → `navigateSmart` → immediate `.ok`) — see [UPSTREAM.md](UPSTREAM.md) §4b |
| Quadratic CLI transfer fix | in the **shared** `CLI/cmux.swift`, so macOS benefits once merged — UPSTREAM.md §4a |

| debug.resume_plan + `linux/scripts/resume-audit.sh` | ★ | 2026-08-18: "who would auto-resume at the next restore" answered by the app's REAL resolver (AgentResume.resumeCommand) per terminal surface — drift-proof by construction; the script is a thin formatter. Suite-asserted (agent-resume-smoke). No macOS counterpart |

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
