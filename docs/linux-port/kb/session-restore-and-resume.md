# Session restore and agent resume — mechanism and matrix

> Sources: https://cmux.com/en/docs/session-restore, /en/blog/session-restore,
> /en/blog/cmux-history, /en/docs/configuration (terminal.*), /en/docs/changelog.
> Crawled 2026-07-22 via the port's own browser.

## The boundary (stated repeatedly, quote-level contract)

"cmux does not checkpoint arbitrary live process state." Restored: window/
workspace/pane layout, working directories, terminal scrollback (best effort),
browser URL + navigation history. tmux/vim/shells reopen as plain terminals
*unless* they have a cmux resume integration. This keeps restore predictable
and "avoids replaying stale prompts or secrets."

## Mechanism

1. Versioned JSON snapshot at
   `~/Library/Application Support/cmux/session-<bundle-id>.json` + a
   previous-session cache for manual reopen (History > Restore Previous App
   Launch, **⌘⇧O**, `cmux restore-session`). Since 0.64.0 restore also covers
   quitting by closing the last window with the red X.
2. Scrollback is stored as bounded text and **replayed through a temporary
   file** on restore (best effort; TUIs may redraw/clear). Cold scrollback is
   auto-compressed under memory pressure (0.64.18 #7758).
3. Agent hooks write `~/.cmuxterm/<agent>-hook-sessions.json` containing the
   agent session id, cmux workspace id, surface id, cwd, pid when available,
   and a **sanitized launch command**.
4. On restore: UI tree first; then, if `terminal.autoResumeAgentSessions`
   (default true), a one-shot shell command per surface runs the agent's
   native resume command with the saved session id. Setting false restores
   panes but leaves agents idle for manual resume.

## The 17-agent resume matrix (verbatim from the docs table)

| Agent | Binary | Resume command | Feed bridge |
|---|---|---|---|
| Claude Code | claude | `claude --resume <id>` | PermissionRequest |
| Codex | codex | `codex resume <id>` | PreToolUse, PermissionRequest |
| Grok / Grok Build CLI | grok | `grok -r <id>` | PreToolUse |
| OpenCode | opencode | `opencode --session <id>` | plugin event bus |
| Pi | pi | `pi --session <id>` | none |
| OMP | omp | `omp --session <id>` | none |
| Campfire | campfire | `campfire --session <id>` | none |
| Amp | amp | `amp threads continue <id>` | none |
| Cursor CLI | cursor-agent | `cursor-agent --resume <id>` | beforeShellExecution |
| Gemini | gemini | `gemini --resume <id>` | PreToolUse |
| Antigravity CLI | agy | `agy --conversation <id>` | PreToolUse, PostToolUse |
| Rovo Dev | acli | `acli rovodev run --restore <id>` | none |
| Hermes Agent | hermes | `hermes --resume <id>` | pre_tool_call, post_tool_call, pre_approval_request, post_approval_response |
| Copilot | copilot | `copilot --resume <id>` | PreToolUse |
| CodeBuddy | codebuddy | `codebuddy --resume <id>` | PreToolUse |
| Factory | droid | `droid --resume <id>` | PreToolUse |
| Qoder | qodercli | `qodercli --resume <id>` | PreToolUse |

Notes: Claude Code is wrapper-handled (not `hooks setup`); Antigravity accepts
`agy` as setup alias, Rovo Dev accepts `rovo`. Changelog additions beyond the
table: Ollama (detection, turn notifications, relaunch resume #7907), Kimi
Code (`cmux hooks setup` #7201), Kiro CLI (native hooks #4831), Campfire
(#5813). Install: `cmux hooks setup` (all findable agents) or per-agent.

## Custom surface resume commands (generic, non-agent)

```
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

- Bindings are stored for inspection/manual restore; **auto-run only when
  trusted**: live process-detected tmux bindings, or user-approved **signed
  command prefixes** (Settings > Terminal > Resume Commands;
  `terminal.resumeCommands`).
- Sensitive env keys (tokens/passwords/secrets/API keys) are dropped before a
  binding is stored; approved prefixes bind to cwd and exact env values.

## Resume-adjacent robustness facts (changelog)

Permission mode (auto-accept/plan/bypass) survives restore/resume/fork
(#8070); Codex YOLO mode survives restore (#8133); Codex resume preserves
CODEX_HOME and pane order; Claude resume keeps cmux hooks attached (0.64.14);
resume repairs stale executable paths (#6582); post-resume ⌘T inherits the
restored cwd (#6621); restored scrollback re-themes correctly (0.64.12).

## Recently-closed history (companion feature)

**⌘⇧T** reopens the last closed terminal tab / browser tab / workspace /
window, one at a time in close order, surfaces returning to their original
anchor — and closed *agent sessions resume* via the same hook data. Titlebar
back/forward + **⌘[ / ⌘]** navigate focus history across workspaces and
windows. A searchable, day-grouped History pane lists everything closed and
focused with timestamps and Clear Closed.

## Port relevance

The port has layout/scrollback/browser restore (own scheme, v3) but no agent
resume, no surface-resume bindings, no history pane, no ⌘⇧T. CONCEPTS.md
already flags agent-native resume as the top gap; this file adds the exact
mechanism (hook-sessions.json shape, one-shot resume launch, trust rules for
non-agent bindings) that a Linux implementation should mirror.
