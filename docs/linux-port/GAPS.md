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
3. **After every upstream merge:** run
   `linux/scripts/capabilities-sweep.py` (both protocol generations) and
   fold new findings in here. Quiet renames of claimed features are
   always **Now**.
4. **Honest errors are a valid state.** A macOS-only feature returning
   `unknown_method` is not a bug; it graduates to a row here only when
   we decide to build it.

Effort: **S** ≤ half a session · **M** one session · **L** multi-session.

## Now — broken or missing pieces of claimed workflows

| Gap | Symptom / value | Source | Effort |
|---|---|---|---|
| `surface.move` / `surface.reorder` | `cmux move-surface` / `reorder-surface` error — the `/cmux` skill's fast-start uses both; agents moving tabs between panes hit it | sweep + skill-walk | M |
| `pane.resize` | `cmux resize-pane -L/-R/-U/-D` errors; PaneDividers already owns positions | sweep-v2 | M |
| `pane.swap` / `pane.break` / `pane.join` | tmux-compat commands in our own CLI help; break/join = move a surface out of / into a pane, swap = exchange two panes' content | sweep-v2 | M |
| `surface.respawn` | `cmux respawn-pane` errors; needs kill+restart of the shell in the same pane (both backends) | sweep-v2 | M |
| Live Ghostty config reload | `reload-config` honestly says "new terminals only"; macOS refreshes in place. Needs a shim call to re-read config on existing surfaces | skill-walk | M |
| Browser JS console pane | macOS `showBrowserJavaScriptConsole` opens a console directly (distinct from DevTools); `browser devtools console` sends `browser.console.show` | CATCHUP item 5 | M |
| Eager background spawn | panes in never-shown workspaces start their shell only on first selection; agents sending to them get `unavailable` | CATCHUP item 1 | M |

**Watch list** (observed once, not reproducible on the current binary):
`list-panes` with no `--workspace` said "Workspace not found" after a
restore (2026-07-22, old binary); four repro attempts on the current
binary all pass. Re-add to Now with a repro if it resurfaces.

## Next — real features, planned

| Gap | Notes | Effort |
|---|---|---|
| Ephemeral browser panes | `webkit_network_session_new_ephemeral`; roadmap/07 leftover | S |
| Browser profile popover UI | verbs are done; macOS has per-pane profile UI | M |
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
answer until a Linux user actually needs one; they are listed by family
so a future decision has the inventory ready:

`vm.*` (13) · `workspace.remote.*` + `remotes.*` (14) · SSH/PTY attach
family · `workspace.group.*` (13) · `canvas.*` (12) · `feed.*` (5) ·
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
