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
| `browser screenshot` fails on background-workspace surfaces | `invalid_state: Browser surface is not visible (background workspace)` — yet backgrounded WebKit pages keep *running* (`browser eval` works; the ADR-0010 watch pane holds a live VNC session while never visible). Breaks "agent screenshots a pane it opened `--focus false`"; `watch-status` works around via `eval`. Probe WebKit's offscreen-snapshot path before accepting the select-once workaround as final | ADR-0010 watch-harness build 2026-07-24 | S |
| Ghostty shim exports bundled libpng — kills WebKit favicons | `libghostty-gtk.so` exports 377 `png_*` symbols; WebKit's IconDatabase decodes favicons in the UI process, resolves `png_read_destroy` into the shim's incompatible copy, SEGV (coredump 2026-07-24; page images safe — web process never loads the shim). Favicon DB is guarded off in shim builds (`ghosttyShimLoaded`, BrowserSurfaces.swift). Fix on the shim build: localize bundled static-lib symbols (`--exclude-libs=ALL` / version script exporting only `ghostty_*`) — fork branch `linux-gtk-embed`, then drop the guard | mirror-⑤ build 2026-07-24 | S |
| Bare Ghostty pane relocation respawns the shell | break/join (and move) of a never-tabbed Ghostty pane restarts its shell — cwd survives, scrollback and processes do not. Forensics 2026-07-22 (PROGRESS): container refcount reaches the parent's-last-ref state despite the registry's ref; one extra ref keeps the shell but leaks the io thread. Tabbed panes relocate safely (reconciliation path). Belongs to roadmap/05 lifecycle hardening; `debug.surfaces` is the probe | GAPS batch 5 | M |

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
| Workspace groups: comfort remainder | Stages 1–3 landed 2026-07-24 (verbs, sidebar sections, colors/icons rendering, menu management; `workspace-groups-smoke` 47 assertions; adversarially QA'd — one hex-grammar defect found and fixed red-first). Context menus landed too (mirror ③, 2026-07-24). Color palette landed (mirror ④, 2026-07-24). Remaining: drag-and-drop membership/reorder (mirror ⑥) | M |
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
| `workspace.reorder` / `workspace.action` | sidebar order is user-visible state | M |
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
