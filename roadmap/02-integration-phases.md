# Towel × cmux — Integration Phases

Phases are ordered by effort and risk: T0 needs no code, T1 is a small patch, T2 changes
the recording architecture, T3–T4 build user-visible features on top. Each phase is
useful on its own; later phases don't require redoing earlier ones.

Hook points reference the Linux port sources under `linux/Sources/CmuxAdw/` and the
shared CLI `CLI/cmux.swift`.

---

## T0 — Use towel inside cmux today (no code changes)

Everything already composes, because a cmux pane is just a shell:

1. `towel init` in the project directory (creates `.towel/`).
2. Register towel-mcp in the project's `.mcp.json`:
   ```json
   { "mcpServers": { "towel": { "type": "stdio",
       "command": "/home/hias/.cargo/bin/towel-mcp" } } }
   ```
3. Launch agents in a pane via the wrapper:
   ```sh
   towel ai-session --source claude-code claude
   ```
4. Optionally add `eval "$(towel-hist init bash)"` to `.bashrc` so *human* commands in
   cmux panes are recorded too (it self-gates on `TOWEL_ENABLED` + `.towel/`).

**Trade-off:** nested PTY (cmux's Ghostty/VTE pty → towel's pty → claude). It works, but
resize propagation crosses two layers — given the resize-freeze history in the Ghostty
embed, test window/pane resizing early. This nesting is exactly what T2 removes.

**Goal of this phase:** validate the workflow and decide which parts feel valuable before
writing any Swift.

---

## T1 — Per-pane towel env injection (small cmux patch)

cmux already injects identity env into every pane at two spawn sites:

- VTE: `spawnShell(...)` — `linux/Sources/CmuxAdw/TerminalSurfaces.swift:461-490`
  (env at `:468-470`)
- Ghostty: `GhosttySurfaceFactory.create` — `linux/Sources/CmuxAdw/GhosttySurfaces.swift:54-58`

Extend both: if `leaf.workingDirectory` (or a parent) contains `.towel/`, additionally set

```
TOWEL_ENABLED=1
TOWEL_PROJECT_ROOT=<dir containing .towel>
TOWEL_SESSION=cmux-<workspaceId>-<surfaceId>-<unix_ts>
TOWEL_SOURCE=human            # agents overwrite via wrapper/hook, see below
```

Effects, with no towel-side changes:

- Shell hooks record every human command per pane, attributed to a **stable per-pane
  session ID** — towel history becomes navigable by cmux pane.
- towel-mcp picks up `TOWEL_SESSION`/`TOWEL_PROJECT_ROOT` automatically, so an agent
  started plainly (`claude`, no wrapper) still logs `towel_run` commands to the right
  pane session and correct cwd.
- The hooks' built-in warning fires when an agent is launched without towel wrapping.

Additions:

- **Persist the towel session ID** per leaf in `SessionStore.swift` (schema v3 candidate,
  alongside the divider-position gap noted in `docs/linux-port/PARITY.md`), so a pane
  keeps its history identity across app restarts.
- **Source switching:** when the Claude hook reports a session starting in a pane
  (`runClaudeHook` in `CLI/cmux.swift:5710+` already maps agent-session → workspace/surface
  in `~/.cmuxterm/claude-hook-sessions.json`), the pane's activity is agent-driven —
  useful later for attribution display, even though env of a running shell can't be
  changed retroactively.

Effort: ~a day including SessionStore schema bump. Pure additive.

---

## T2 — cmux as the Level-2 recorder (drop the nested PTY)

The architectural win. Towel's `ai-session` wrapper exists because towel had to *become*
the terminal to observe it. **cmux already is the terminal.** Since towel's session-log
format is a simple documented contract (header / `========================` delimiters /
footer — see [01-towel-overview.md](01-towel-overview.md)), cmux can write these logs
natively and the entire towel analysis stack (`towel_sessions`, `towel_session_read`,
`towel_audit`, `towel_stats`) consumes them unchanged.

Design sketch:

- New control verbs in `ControlProtocol.swift`: `surface.record start|stop|status`
  (+ auto-start option for panes in towel-enabled projects).
- On start: write the towel header to
  `<TOWEL_PROJECT_ROOT>/.towel/sessions/<TOWEL_SESSION>.log`, then append output;
  on stop/pane-close: write the footer (duration, exit code). Always writing the footer
  fixes towel's "crashed sessions stay active forever" quirk at the source.
- Capture sources:
  - **VTE path:** `contents-changed` + `vte_terminal_get_text*` diffing is lossy;
    better: VTE spawn already goes through a pty — investigate `vte_pty_*` and feeding a
    logger, or accept screen-diff fidelity for v1.
  - **Ghostty path:** the shim (`Sources/CGhosttyEmbed/`) sits on libghostty — an output
    callback there is the clean solution; fallback is periodic `read-screen` with
    scrollback diffing (`GhosttySurfaces.swift:180-235` already reads scrollback).
- Keep T0's wrapper as fallback for panes where native capture isn't wired yet.

Payoff:

- No nested PTY, no double resize handling.
- *Every* pane gets an audit log automatically — human panes included, which towel's
  wrapper never covered well.
- One recording pipeline for both backends, testable via `dogfood.sh`.

Prereq from towel's side: log-size discipline (rotation/`max_output_size` — see
[03-towel-prework.md](03-towel-prework.md)) becomes urgent once every pane records.

---

## T3 — Surface towel data in the cmux UI

Now the collected data starts paying rent. All three items align with features already
on the parity wishlist (`docs/linux-port/PARITY.md`: `report_*` verbs ❌, metadata
pills ❌).

1. **Sidebar metadata pills, powered by towel.** When implementing `report_*`/
   `set_status` (the Claude hook already *sends* `set_status claude_code Running/Needs
   input` — `CLI/cmux.swift:5848-5862` — Linux just drops it), add towel-derived pills
   per workspace: cooperation score, last-command exit status, command count. Data via
   `towel-hist` CLI calls or direct SQLite reads of `history.db` (plain schema, easy from
   Swift) — no need to speak MCP from the app.

2. **Failure attention.** A recorded command with `exit_code != 0` and
   `source=claude-code` in a background workspace → reuse the existing attention pipeline
   (`CmuxApp.swift:215-238`, `bellVerdict` in `TerminalSurfaces.swift:79-89`) to light the
   dot. Agents fail silently today unless they ring the bell themselves.

3. **Richer agent-finished notifications.** In the Claude-hook stop path (which already
   fires `notify_target`), shell out to `towel_audit`/`towel-hist stats` and enrich the
   desktop notification: *"Agent finished — 14 commands, 2 failed, cooperation 86%."*
   Small change in `runClaudeHook`, big glanceability win across many parallel agents.

---

## T4 — Development-memory features (the Warp-like endgame)

1. **Command palette backed by towel history.** The palette is a planned cmux feature
   anyway (`PARITY.md`); back its command-history mode with `towel-hist search`
   (fuzzy, per-project, cross-pane) instead of per-shell history. Towel's zsh/fish hooks
   already prove the Ctrl+T UX.

2. **Per-pane command blocks.** Warp's signature feature, buildable from towel records:
   a pane-attached view listing this pane-session's commands (command, exit code,
   duration, rating) with output on demand from `.towel/runs/<id>.log`. Start as a
   read-only GTK popover per pane; no terminal-content parsing needed since the data is
   structured.

3. **Dogfood QA × towel.** Point `linux/scripts/dogfood.sh` agents at towel: the QA agent
   runs its commands via `towel_run --context` and tags results (`towel_annotate
   --tags qa`). QA reports gain a structured command appendix, and cooperation score
   becomes a per-dogfood-run quality metric. Also the cheapest way to soak-test T1/T2
   under real load.

4. **Later — RAG/suggestions (towel Phase 5).** Once towel grows semantic search
   (`towel_similar`/`towel_patterns`, currently unimplemented), the palette can offer
   "similar past commands and their outcomes" — accumulated, project-scoped memory that
   generic agents don't have. Ambitious; only worth it after T1–T3 prove the data is used.

---

## Risks & open questions

- **Parser fidelity outside Claude Code** — towel's V2 parser targets Claude Code's TUI;
  cooperation scores in human/Codex/OpenCode panes will be noisy until patterns are added
  (towel-side work).
- **DB write concurrency** — many panes, one `history.db`. Verify WAL mode + busy
  timeout before T1 ships hooks in every pane.
- **Disk growth** — T2 multiplies session logs. Rotation/compression is a hard prereq.
- **Ghostty output callback** — T2's clean path needs a shim addition on the
  `linux-gtk-embed` branch; scope that before committing to T2's design.
- **Where does towel live?** Currently a non-git local project with hand-copied binaries.
  Before it becomes cmux infrastructure: put it in git, fix the version stamp, and decide
  whether cmux vendors it, depends on `~/.cargo/bin`, or absorbs the relevant parts.
