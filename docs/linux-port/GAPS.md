# Gaps — the work-down list

**What this file is:** the actionable backlog of known gaps, in priority
order. [PARITY.md](PARITY.md) tracks *state* (✅/❌ per method),
[CATCHUP.md](CATCHUP.md) is the session briefing; this file owns *what to
fix next and how big it is*. A gap lives here from discovery to fix.

**Rules (the approved way):**

1. **Same-commit updates.** Fixing a gap removes its row here and flips
   PARITY in the same commit. Discovering one adds a row citing the
   source (sweep, dogfood, skill-walk, user report).
2. **Every fix follows the loop:** implement → verify on a scratch/dev
   instance → suite assertion (regression policy: red first where
   feasible) → PROGRESS entry → commit → push. No gap closes without a
   test that would notice it reopening.
3. **After every upstream merge:** run BOTH tripwires and fold new
   findings in here — `linux/scripts/capabilities-sweep.py` (CLI verbs,
   both protocol generations) and `linux/scripts/macos-surface-survey.py`
   (macOS commands / panel types / settings sections, vs
   `macos-surface-ledger.json`). Quiet renames of claimed features are
   always **Now**; genuinely new macOS items get a ledger disposition.
   [PARITY-DASHBOARD.md](PARITY-DASHBOARD.md) rolls both up.
4. **Honest errors are a valid state.** A macOS-only feature returning
   `unknown_method` is not a bug; it graduates to a row here only when
   we decide to build it.

Effort: **S** ≤ half a session · **M** one session · **L** multi-session.

## Now — broken or missing pieces of claimed workflows

| Gap | Symptom / value | Source | Effort |
|---|---|---|---|
| codex-teams leaks its `codex app-server` child on teardown | `codexTeamsTerminateProcess` (shared `CLI/cmux.swift`) sends only SIGTERM to the immediate child; the `codex app-server` escapes the process group and ignores SIGTERM, so an abnormal codex-teams exit orphans an app-server bound to a loopback port. Wants SIGKILL-escalation + process-group signaling. **Affects macOS too** (shared CLI) — UPSTREAM.md §4f | teams-siblings dogfood 2026-07-24 | S |
| `browser screenshot` fails on background-workspace surfaces (and the CLI may silently shoot a DIFFERENT pane instead of surfacing that error — observed 2026-08-21 with `browser screenshot --workspace <background-ws>` returning a plausible PNG of another surface; mechanism not yet isolated) | `invalid_state: Browser surface is not visible (background workspace)` — yet backgrounded WebKit pages keep *running* (`browser eval` works; the ADR-0010 watch pane holds a live VNC session while never visible). Breaks "agent screenshots a pane it opened `--focus false`"; `watch-status` works around via `eval`. Probe WebKit's offscreen-snapshot path before accepting the select-once workaround as final | ADR-0010 watch-harness build 2026-07-24 | S |
| Sidebar ListBox render desyncs from the projection under long churn | After workspace-groups-smoke's full history (restore + hover/popover/palette clicks + reorders) the rendered list showed 2 of 4 projection rows — rows missing, model/debug.sidebar_rows correct. Minimal repros (reorder alone, join/leave, menu+reorder, restore+reorder) all render CORRECTLY; the corruption needs the accumulated history. Repro: `workspace-groups-smoke.sh --keep`, compare sidebar vs debug.sidebar_rows. Suspect: adwaita-swift ListBox differ vs row-parented popovers/controllers. The suite's pointer-drag assertion is parked as this bug's canary (see suite NOTE) | mirror-⑥ build 2026-07-24 | M |
| Ghostty shim exports bundled libpng — kills WebKit favicons | `libghostty-gtk.so` exports 377 `png_*` symbols; WebKit's IconDatabase decodes favicons in the UI process, resolves `png_read_destroy` into the shim's incompatible copy, SEGV (coredump 2026-07-24; page images safe — web process never loads the shim). Favicon DB is guarded off in shim builds (`ghosttyShimLoaded`, BrowserSurfaces.swift). Fix on the shim build: localize bundled static-lib symbols (`--exclude-libs=ALL` / version script exporting only `ghostty_*`) — fork branch `linux-gtk-embed`, then drop the guard | mirror-⑤ build 2026-07-24 | S |
| `--help` advertises phantom verbs | `search`, `text`, `to`, `toggle`, `zoom-pane` extracted from top-level help all answer "Unknown command"; help-derived allowlists inherit phantoms. `zoom-pane` may be a real macOS verb needing platform-aware help or an honest "not on this platform" reply | roadmap/08 item 3 (lfm-dl, 2026-08-18) | S |
| `markdown.open` unimplemented | live-reload markdown viewer verb; second viewer-verb vote after feed. The wiring-atlas viewer already proved the pattern (browser pane + local renderer + live reload) | roadmap/08 item 6 (lfm-dl, 2026-08-18) | M |
| Live-socket capability sweep mode | `capabilities-sweep.py` only parses sources statically; a `--socket` mode probing every v2 method against a RUNNING instance (served vs `unknown_method`) would make the features board's `mac` column empirical — the headless VM instance (POC-0003, driveable since 2026-07-24) is the measurement target it lacks | POC-0003 live drive 2026-07-24 | S |
| Ghostty shim increment 4: runtime-validate the merged-tree shim, push the fork, move the pointer | COMPILES since 2026-07-24 evening (`6ae46bc59` on trial branch `trial-merge-probe`): the 19 lib-gtk errors were upstream equating artifact==.lib / apprt.embedded type refs with "embedded runtime" — fixed with build-enum guards (main_c assert, OpenGL is_embedded + 4 switches→if-chains, Surface.zig comparisons, shim Surface.new/.working-directory API drift). ghostty_embed_* exports verified intact. REMAINING: boot a scratch cmux-adw against the new .so (worktree zig-out), then push fork + move parent submodule pointer. Payoff: the 15 new embedded APIs for Linux; unblocks the null renderer on a settled fork | POC-0003 increment 1, 2026-07-24 | S |
| Bare Ghostty pane relocation respawns the shell | break/join (and move) of a never-tabbed Ghostty pane restarts its shell — cwd survives, scrollback and processes do not. Forensics 2026-07-22 (PROGRESS): container refcount reaches the parent's-last-ref state despite the registry's ref; one extra ref keeps the shell but leaks the io thread. Tabbed panes relocate safely (reconciliation path). Belongs to roadmap/05 lifecycle hardening; `debug.surfaces` is the probe | GAPS batch 5 | M |
| Workspace-group removal semantics are old-macOS — **data-loss divergence** | Upstream #8542/#8925 ([DRIFT-2026-08.md](DRIFT-2026-08.md) A1–A3): bare `workspace.group.delete` now DISSOLVES (only `close_workspaces:true` closes; result gains `operation` + `kept_workspace_count`); closing an anchor PROMOTES the earliest remaining member instead of dissolving (batch closes drain non-anchors first); `group.create` no longer derives children from ambient selection (absent = anchor-only). We still implement all three old contracts — our bare `delete` destroys workspaces upstream now preserves | drift audit 2026-08-19 | M |
| Destructive verbs fall back to focused surface on stale explicit ids | Upstream #9422 (DRIFT A4): `surface.close`/`surface.respawn`/`pane.break`/`pane.join`/`tab.action` must return `not_found` for an unresolvable explicit `surface_id`/`tab_id` (respawn also rejects explicit `null`); we keep the old focused-surface fallback — automation with a stale id closes the WRONG surface. The next CLI merge also validates handles against `surface.list` echo fidelity client-side | drift audit 2026-08-19 | S–M |
| `feed.push` contract drift | DRIFT A5: id-less notification form must produce NO response bytes (we always reply); `events[]` batch (≤64, pi/postToolUse); new `not_found`/`unavailable` delivery-target errors agents' retry logic depends on; ack shape `{status:"acknowledged", item_id\|item_ids[]}` | drift audit 2026-08-19 | S–M |
| `system.capabilities` envelope + `reply_shape` acceptance | DRIFT A6/A7: add top-level `capabilities` feature-token array (clients feature-detect off it); accept `reply_shape` on notification create verbs (unknown → `none`), note upstream may echo a re-homed `surface_id` | drift audit 2026-08-19 | S |

**Watch list** (observed twice, minimal repro still missing):
`list-panes` with no `--workspace` returns nothing after a restore
(2026-07-22, old binary; resurfaced same day on the current binary
during the JS-console work — scratch instance restarted onto a restored
session, `list-panes` empty until a `select-workspace` ran). Next
sighting: capture `workspace.list` + selection state before touching
anything, then promote to Now.

## Next — real features, planned

| Gap | Notes | Effort |
|---|---|---|
| Workspace groups: comfort remainder | Stages 1–3 landed 2026-07-24 (verbs, sidebar sections, colors/icons rendering, menu management; `workspace-groups-smoke` 47 assertions; adversarially QA'd — one hex-grammar defect found and fixed red-first). Context menus landed too (mirror ③, 2026-07-24). Color palette (mirror ④) and sidebar DnD membership/reorder (mirror ⑥, 2026-07-24) landed. Remaining beyond sidebar: tab-onto-pane drags, file drops (MACOS-UX §3) | M |
| Dock remainder | Minimal Dock landed 2026-07-24 (mirror ⑦: global dock.json terminal controls, toggle, lazy populate, dock-smoke 8). Remaining vs macOS: browser controls, in-dock tiling (splits/tabs/zoom), drag in/out of the Dock, `--placement dock` on pane/surface.create + `right_sidebar` verb family, project `.cmux/dock.json` with the content-fingerprint trust gate, `height` seeding. **2026-08 drift:** macOS now persists Dock panes across restore (#8690) and folds Dock nodes into `surface.list`/`pane.list`/`system.tree` with `dock_scope` (#8782) — the old "macOS reseeds too" note is stale (DRIFT A9) | M–L |
| Upstream catch-up merge #2 (2026-08 drift) | Fold the 4,067-commit upstream delta ([DRIFT-2026-08.md](DRIFT-2026-08.md)) — merge checklist §B: `CLISocketPathResolver` API break + `SSHPTYAttachExitCode` relocation, fail-closed CLI surface resolution, live-probing socket discovery (verify we unlink on exit + our path is a candidate), route/reject new verbs (`restore` needs `restore_record` from `surface.resume.get`, `mosh`, `comments`, `simulator`/`ios` want a clean platform error), fail-open params (profile/reply_shape/zoom/caller/launch_command), kimi `.kimi-code/`→`.kimi/`, `--fork-session` sniffing removed. Then re-run both tripwires + re-baseline PARITY and retire the DRIFT doc | L |
| `system.tree` `layout` + `surface.resume` restore_record | DRIFT A8/A10: workspaces gain a `layout` split-tree field (`null` fail-closed; feeds `--layout` round-tripping); `resume_binding` gains structured `launch_command`/`permission_mode`/`execution_location` and `.get` gains `restore_record` — prerequisite for the new shell-free `cmux restore` verb; pairs with AgentResume | M |
| Keyboard drift batch (2026-08) | DRIFT §C: decide `equalizeSplits` chord generation (upstream silently rebound ⌘⌃= → ⌘⇧⌃=; old chord now = workspace font zoom), font-zoom trio, move-surface-to-pane six-pack, `reopenClosedWorkspace`, rebindable pane cycling, group-scoped workspace traversal. Fold into the shortcut-rebinding work so ids round-trip in cmux.json | S–M |
| `notifications.paneFlashColor` round-trip | Attention blue is now themable upstream (schema + Workspace Colors row). Our GNOME-accent deviation stays, but accept/honor the key when set so configs round-trip (DRIFT §C) | S |
| Test-harness roadmap (remainder) | the four S-items landed 2026-07-22 (`run.sh` front door, freshness preflight, flake-hunter, assertion ledger); remaining: timing trend, interactive picker (deferred), `cmux doctor`, dual-backend ghostty gate, CI — inventory + invest-when rules in `linux/tests/README.md` §Harness roadmap | S–M each |
| UX-parity ❌ cluster | from [UX-PARITY.md](UX-PARITY.md) 2026-07-22, no decision needed (missing, not deviations): ~~unfocused-split dimming~~ (done 2026-07-23), ~~sidebar hover-close~~ (done 2026-07-24, mirror ②), GtkShortcutsWindow (Ctrl+?), notification card rows, surface-tab type icons, tab-bar end-action buttons, ~~sidebar context menu~~ (done 2026-07-24, mirror ③). The comfort work now follows MACOS-UX.md's mirror order | S each, batchable |
| OSC 777 / OSC 99 notification ingestion | docs promise both terminal notify protocols (docs/notifications); verify what the ghostty shim / VTE already surface, then wire to the notification store. Verify-first | docs crawl 2026-07-22 → CONCEPTS.md | S |
| Ephemeral browser pane — URL-bar affordance | server side done (batch 1); the profile popover excludes the reserved ephemeral profile, so ephemeral is CLI/agent-only. Add a "New ephemeral pane" popover row (calls onProfileChosen with ephemeralID) | teammate finding 2026-07-23 | S |
| codex-teams / omc / omo / omx — real teammate splits (authed) | launcher+shim setup verified (teams-siblings-smoke, batch 1) — but the 6 honest skips are the *actual feature* (teammate-becomes-a-split), unverifiable here because the agent binaries are absent. **To close the skips, provision:** `codex` (Codex CLI — note codex-teams is app-server/watcher, NOT shim-based), `omc`/`omx` (`npm i -g oh-my-claude-sisyphus`), and the opencode oh-my-openagent plugin for `omo`. Then re-run teams-siblings-smoke with the split legs un-skipped. NB each launcher differs (wiring/02, kb/tmux-compat) | teams-siblings 2026-07-23 | S |
| Agent-native session resume on restore | macOS captures the agent's session id and restore relaunches `claude --resume <id>` (17 agents documented). The port restores shells only — this very session was resumed by hand-carrying ids in text files. NOTE (kb/claude-with-cmux.md): Claude specifically is **wrapper-based** (`automation.claudeCodeIntegration` wrapper writes `~/.cmuxterm/claude-hook-sessions.json`), not `hooks setup`; a Linux impl must replicate the wrapper. Bonus: Fork Conversation + reopen-closed-agent-session ride the same captured data (kb/fork-and-history.md) | docs crawl 2026-07-22 → CONCEPTS.md + kb/ | M |
| Shortcut rebinding (`shortcuts.bindings`) | macOS: every cmux-owned shortcut rebindable via Settings/cmux.json incl. two-step chords and explicit unbind; ours are hardcoded. Settings file exists — wire bindings through it | docs crawl 2026-07-22 | M |
| Keyboard muscle-memory batch | equalize splits (⌃⌘=), reopen last closed surface (⌘⇧T), focus history (⌘[/⌘]) — small, documented, daily-use | docs crawl 2026-07-22 | S–M |
| TextBox composer (beta upstream) | prompt-compose surface above the terminal, per-surface visibility/focus persisted; agent-first workflow piece | docs crawl 2026-07-22 → CONCEPTS.md | M–L |
| `surface.health` / `surface.action` / `drag_to_split` | health pairs well with the dogfood harness | M |
| `workspace.action` | workspace.reorder landed 2026-07-24 (mirror ⑥, macOS wire: index/before/after + dry_run); action still open | M |
| Download handling | decide-destination handler; `browser.download.wait` no-path branch | M |
| `browser.viewport.set` / `geolocation.set` / `offline.set` | device emulation for agents | M |
| Command palette | macOS headline UI | L |
| Sidebar metadata pills + `report_*` verbs | git branch/PR/ports/status/progress | L |
| Tab drag-and-drop | reorder, tear-off | L |
| Multi-window (`window.create/close`, v1 `new_window`/`close_window`) | a phase of its own | L |
| Flatpak packaging | CATCHUP milestone | L |
| Ghostty-embed hardening | roadmap/05 — fast-churn resource leak | L |

## Later / only if needed — honest macOS-only feature families

The sweep's remaining ~130 methods. `unknown_method` is the correct
answer until a Linux user actually needs one. Since the 2026-07-22 docs
crawl these are no longer bare method names — [CONCEPTS.md](CONCEPTS.md)
records what each family is *for* (canvas = freeform 2D pane layout;
vault = transcript search; dock = right-sidebar terminal controls;
`system.top` = task manager; `markdown.open`/diff = read surfaces;
feed = agent approval stream; groups = anchor-owned sidebar sections):

`vm.*` (13) · `workspace.remote.*` + `remotes.*` (14) · SSH/PTY attach
family · `canvas.*` (12) · `feed.*` (5) ·
`auth.*` (4) · `layout.*` (5) · `events.stream` · `browser.trace/
screencast/network-route` · `browser.import.*` · `browser.react_grab` ·
`browser.focus_mode` · `file.open` / `project.open` / `markdown.open` ·
`mobile.*` · `system.memory` / `system.top` · `settings` docs UIs beyond
`settings.open` · `agent.resolve_delivery_target`.

## Not planned

- `debug.*` (~30 UI-test hooks) — port alongside an e2e harness, not before.
- `input_keyboard/mouse/touch` — `not_supported` on macOS too; WebDriver
  covers trusted input.
- v1 internals: `__internal_flags`, `agent_hibernation`,
  `set_app_focus`, `simulate_app_active` — macOS test scaffolding.
