# Fork Conversation and History — two concepts the port tracker misses

> Sources: https://cmux.com/en/blog/cmux-fork, /en/blog/cmux-history,
> /en/docs/configuration (app.forkConversationDefaultDestination),
> /en/docs/changelog (0.64.7, 0.64.11, 0.64.18, 0.64.19, 0.64.20).
> Crawled 2026-07-22 via the port's own browser.

Neither feature appears in docs/linux-port/CONCEPTS.md or PARITY.md; both are
core to the agent-supervision loop.

## Fork Conversation (v0.64.7 → GA in 0.64.18, July 2026)

"Fork Conversation creates a new agent session from the current thread,
preserving its conversation history and working directory."

- Entry points: right-click a terminal or tab → Fork Conversation; ⌘⇧P
  palette. Destination submenu: split on any side, new tab, new workspace;
  primary action's default via `app.forkConversationDefaultDestination`
  (right|left|top|bottom|newTab|newWorkspace).
- Supported agents: Codex, Claude Code, OpenCode (0.64.20 #8140), Pi, Hermes,
  OMP, "and other agents with forkable sessions".
- Use cases named: keep one approach intact while a second agent tries a
  different implementation, investigates a tangent, or reviews the same
  problem fresh; fork repeatedly to compare implementations or divide a
  problem with the same starting context. Docs warn: forks can share a
  directory — separate tasks/files when concurrent edits could overlap.
- Robustness contracts from the changelog: forked Claude sessions must not
  restore the parent session after restart (#5910); fork works after the
  session changed directories (#5154); permission mode survives forking
  (#8070); live claude/codex processes are detected so **hook-less sessions
  stay forkable** (#6133); "keep forkable sessions with stale pids" (#6803).
- Mechanically this rides the same per-agent session-id capture as resume
  (`~/.cmuxterm/*-hook-sessions.json`, `omp --fork <id>`, etc.).

## History: reopen-closed + focus history (0.64.11, June 2026)

Three connected mechanisms:

1. **Reopen closed** — ⌘⇧T reopens the last closed thing: terminal tabs,
   browser tabs, workspaces, windows; one at a time, in close order; each
   surface returns "where it was, with its panes intact" (original anchor).
   **Closed agent sessions resume where they left off** (needs
   `cmux hooks setup` once).
2. **Focus history** — titlebar back/forward buttons + ⌘[ / ⌘] retrace
   previously focused workspaces/windows "the same way back and forward work
   in a browser". Note the deliberate conflict: ⌘[/⌘] default to focus
   history; users must unbind Focus Back/Forward to give browser-back or
   terminal shortcuts those keys.
3. **History pane** — searchable, day-grouped view of everything closed *and*
   focused, with timestamps and a Clear Closed action. "Reopen previous
   session" ⌘⇧O is adjacent (restores the previous app-launch snapshot).

## Port relevance

- The port has `workspace.last` and `pane.last` (tmux-style toggles) but no
  cross-workspace focus *stack* UI, no closed-item history, no reopen verb.
- Fork requires the same agent-session capture the port lacks for resume —
  implementing resume (GAPS) gets fork's data layer for free.
- `reopenClosedBrowserPanel` (⌘⇧T) is a bound action id in the shortcut
  schema — the shared CLI/schema already knows the name.
