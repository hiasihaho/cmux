# Claude Code with cmux — the intended workflow

> Sources: https://cmux.com/en/docs/session-restore, /en/docs/notifications,
> /en/docs/agent-integrations/claude-code-teams, /en/docs/agent-integrations/oh-my-claudecode,
> /en/docs/skills, /en/docs/configuration, /en/docs/vault, /en/agents/claude-code,
> /en/compare/multiple-claude-code-agents-parallel, /en/blog/cmux-fork, /en/blog/cmux-history,
> /en/blog/session-restore, /en/blog/cmux-claude-teams, /en/blog/cmd-shift-u, /en/docs/changelog.
> Crawled 2026-07-22 via the port's own browser (surface:11, workspace:7 of the daily instance).

This is the coherent narrative of how upstream intends Claude Code to be run
inside cmux, assembled from every page that touches it. It is the single most
load-bearing workflow for the product ("cmux is a terminal for coding agents,
and Claude Code is a first-class fit").

## 0. Detection: how Claude knows it is inside cmux

Every cmux terminal exports `CMUX_WORKSPACE_ID` and `CMUX_SURFACE_ID`, sets
`TERM_PROGRAM=ghostty` / `TERM=xterm-ghostty`, and puts the `cmux` CLI on PATH.
The documented detection idiom:

```bash
[ -n "${CMUX_WORKSPACE_ID:-}" ] && [ -n "${CMUX_SURFACE_ID:-}" ]  # inside a cmux surface
[ -S "${CMUX_SOCKET_PATH:-/tmp/cmux.sock}" ]                      # socket reachable
```

## 1. Integration is wrapper-based for Claude, hooks-based for everyone else

**Critical asymmetry the docs state repeatedly:** most agents get their cmux
integration via `cmux hooks setup <agent>`, but *"Claude Code is handled by the
cmux Claude wrapper when Claude integration is enabled in Settings"*
(`automation.claudeCodeIntegration`, default true; `automation.claudeBinaryPath`
overrides the binary). Running `claude` in a cmux terminal transparently runs
the wrapper, which:

- injects cmux's hook settings (merging with user `--settings`, changelog #5388);
- records the native session id, cwd, workspace id, surface id, pid, and a
  sanitized launch command into `~/.cmuxterm/claude-hook-sessions.json`
  (per-agent files: `~/.cmuxterm/<agent>-hook-sessions.json`);
- suppresses Claude's own OSC notifications so cmux's pipeline is the single
  source (gated on the integration setting);
- keeps Claude running after `/clear`;
- **preserves the interactively chosen permission mode** (auto-accept / plan /
  bypass) across restore, resume, and fork (changelog 0.64.19 #8070);
- passes Claude subcommands through, preserves Vertex/Bedrock auth env;
- bridges Claude Code's `PushNotification` tool into cmux notifications (#7385).

For all other agents: `cmux hooks setup` installs every integration whose
binary is on PATH and prints a summary of skipped ones; `cmux hooks setup
codex|grok|antigravity|omp|--agent opencode` installs one.

## 2. Notice: the notification loop while Claude runs

When Claude finishes a turn or blocks on permission, cmux fires the attention
pipeline (see kb/notifications-contract.md). The Claude-specific policy knobs:

- `notifications.agentPermissionPrompt` (default **true**) — "the alert you
  must act on to unblock the agent".
- `notifications.agentTurnComplete` = `whenIdle` (default) — suppressed while
  the agent still has a running background task or pending scheduled wakeup,
  "so you are pinged once work truly drains". Also `always` / `never`.
- `notifications.agentIdleReminder` (default true) — ~60 s after turn end,
  suppressed while background work is pending.
- `automation.suppressSubagentNotifications` (default true) — nested
  Claude/Codex child agents don't spam banners; their events stay in Feed.
- Blocked `AskUserQuestion` / `ExitPlanMode` prompts are flagged "Needs input"
  even under `--dangerously-skip-permissions` (#6608).

Supervision shortcuts (the product's whole point): **⌘⇧U** jumps to the newest
unread — switches workspace, focuses the exact pane, flashes it, marks read,
brings the right window forward. **⌃⌘U** marks the current item oldest-unread
and jumps to the next latest unread ("send it to the back of the cycle" when
several agents finish at once). **⌥⌘U** toggles read state. The Cmd+Shift+U
blog: "I have 17 workspaces open right now, each running an agent."

Agent scripts can additionally push sidebar state: `cmux set-status`,
`set-progress`, `log` (see kb/cli-reference.md).

## 3. Resume: session restore relaunches `claude --resume <id>`

On relaunch cmux first rebuilds windows/panes/cwd/scrollback/browser state,
then — if `terminal.autoResumeAgentSessions` (default true) — launches a
one-shot shell command running each agent's **native resume command** with the
saved session id. For Claude that is `claude --resume <id>`. 17 agents are in
the resume matrix (kb/session-restore-and-resume.md has the full table).
Manual reapply: History > Restore Previous App Launch, ⌘⇧O, or
`cmux restore-session`.

Non-agent surfaces can get the same treatment via **custom surface resume
commands** (`cmux surface resume set --kind tmux --checkpoint work --shell
"tmux attach -t work"`) with signed command-prefix approvals; secrets-looking
env keys are dropped before a binding is stored.

## 4. Reopen and fork: history and Fork Conversation

- **⌘⇧T** reopens the last closed thing (terminal tab, browser tab, workspace,
  window) — and *closed agent sessions resume where they left off* if hooks
  captured them. A searchable, day-grouped History pane holds everything
  closed and focused.
- **Fork Conversation** (right-click a tab / ⌘⇧P): creates a new agent session
  from the current thread, preserving conversation history and cwd; send the
  fork to a split on any side, a new tab, or a new workspace
  (`app.forkConversationDefaultDestination`). Supported: Codex, Claude Code,
  OpenCode, Pi, Hermes, "and other agents with forkable sessions". Forks can
  share a directory — docs warn to split tasks/files when edits could overlap.
  cmux detects live claude/codex processes so hook-less sessions stay forkable
  (#6133).

## 5. Old sessions: Vault

Vault (right sidebar) full-text-indexes local Claude Code / Codex / OpenCode /
Pi transcripts. Search by filename, branch, issue title, error message, or a
phrase the agent said; **drag the hit into the current workspace** to reopen
that session beside what you're doing now. "Shell history tells you what
command started an agent. Vault searches what the agent actually discussed."

## 6. Teams: `cmux claude-teams` (tmux shim → native splits)

`cmux claude-teams [args…]` launches Claude Code with agent teams enabled:

1. writes a tmux shim script at `~/.cmuxterm/claude-teams-bin/tmux` that
   redirects to `cmux __tmux-compat`;
2. sets fake `TMUX` + `TMUX_PANE` (encoding the current cmux workspace/pane);
3. prepends the shim dir to PATH (so Claude finds it before real tmux);
4. sets `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, defaults teammate mode to
   auto, and execs `claude --teammate-mode auto`.

When Claude issues tmux commands to manage teammate panes, the shim translates
them into cmux socket calls (`split-window`→`surface.split`,
`send-keys`→`surface.send_text`, `capture-pane`→`surface.read_text` — full
table in kb/tmux-compat.md). Teammates stack vertically in a right column,
auto-equalizing as agents spawn and exit, each with sidebar metadata and
notifications. Shim state (buffers, hooks) persists in
`~/.cmuxterm/tmux-compat-store.json`. Works over SSH via the Go relay daemon
(`cmuxd-remote` does the same translation remotely). `cmux codex-teams` maps
Codex subagent sessions the same way (0.64.5).

## 7. Orchestrators: the oh-my family

Same shim pattern, different launchers; all forward remaining args:

| Command | Wraps | Shim dir | Notes |
|---|---|---|---|
| `cmux omc` | Oh My Claude Code (npm `oh-my-claude-sisyphus`) — 19 specialized agents, model routing, HUD | `~/.cmuxterm/omc-bin/` | injects a NODE_OPTIONS restore module for Claude Code compatibility |
| `cmux omo` | OpenCode + oh-my-openagent plugin (multi-model: Claude, GPT, Gemini, Grok) | `~/.cmuxterm/omo-bin/` | builds a **shadow config** at `~/.cmuxterm/omo-config/` (plugin registered, `tmux.enabled` on, `OPENCODE_CONFIG_DIR` pointed at it) — the user's `~/.config/opencode/` is never modified; idle agents reaped after 3 idle polls; queued spawn retries every 2 s when the window is full |
| `cmux omx` | Oh My Codex (30+ agent roles, HUD with model/branch/context/token usage) | `~/.cmuxterm/omx-bin/` | prereq `npm i -g @openai/codex oh-my-codex; omx setup; omx doctor` |
| (omp) | oh-my-pi (`omp`) is **not** a shim — it's a hooks extension: `cmux hooks setup omp` writes `~/.omp/agent/extensions/cmux-omp-session.ts` (cmux upgrades it in place) | — | gives busy/idle status, turn-end notifications, resume (`omp --session <id>`) and fork (`omp --fork <id>`), auto-naming with omp as summarizer model, Task Manager attribution. Env: `CMUX_OMP_HOOKS_DISABLED=1`, `CMUX_OMP_CMUX_BIN`. Session data in `~/.omp/agent/sessions` (`PI_CODING_AGENT_DIR`/`PI_CONFIG_DIR` override) |

All use `main-vertical` auto-layout: main session in the primary pane, agents
in a grid beside it.

## 8. Skills: teaching agents to drive cmux

cmux ships agent skills so a Claude session can drive the app itself:

- Install: `npx skills add manaflow-ai/cmux -g -y` (all) or `--skill
  cmux-diagnostics`; alternatively `curl -fsSL
  https://raw.githubusercontent.com/manaflow-ai/cmux/main/skills.sh | bash`
  (defaults to `~/.codex/skills` or `$CODEX_HOME/skills`; `--dest`, `--ref`,
  `--dry-run`, from-checkout mode).
- Inventory: `cmux` (topology control), `cmux-workspace` (stay scoped to the
  caller workspace), `cmux-settings` (cmux.json edits by JSON path),
  `cmux-customization` (actions, layouts, Dock, Feed hooks, palette entries),
  `cmux-diagnostics` (read-only health checks), `cmux-browser` (webview
  automation), `cmux-markdown` (formatted panels). Layout convention:
  `skills/<name>/SKILL.md` + `agents/openai.yaml` + references/scripts/templates.
- A customization **examples library** (worktree-agents, full-stack-dev,
  ssh-devbox, review-pr, docs-workspace, ci-watch, quick-agent-buttons) is
  meant to be *applied by an agent*: "Use $cmux-customization to set up the
  worktree-agents example."
- `cmux docs <topic>` is the agent-facing offline manual; upstream's own
  agent prompts start with "Run `cmux docs dock`".

## 9. Compose: TextBox, and hand-offs into the agent

TextBox (beta) is a rich input surface above the terminal for composing
prompts before sending: per-surface, persisted across restore, `⌘⇧A` to flip
focus terminal↔TextBox, `⇧Tab` cycles configurable **submit actions**
(`terminal.textBoxSubmitActions`; default `text-entry`), `⌥⌘⇧A` attaches a
file, skill suggestions autocomplete in it. The Diff Viewer's review comments
(per-repo persisted line comments) can be **attached to a TextBox** "to hand
structured review feedback straight to an agent" (0.64.15).

## 10. The rest of the loop

- **AI auto-naming** (`automation.workspaceAutoNaming`, opt-in): workspaces and
  tabs named from the agent conversation *by the agent's own binary*
  (`automation.autoNamingAgent`: `auto` or a slug like `claude`); manual
  renames always win.
- **Agent Hibernation** (`terminal.agentHibernation`, opt-in): kills idle
  *background* agent processes to free RAM/CPU, resumes them with their saved
  session when the tab is visited; only when restorable + idle + off-screen +
  over the live-terminal limit + output unchanged. Placeholder Resume button
  as fallback.
- **Task Manager** (`cmux top`): per-workspace/surface CPU+RAM attribution of
  known agent processes.
- **Browser beside the agent**: agents verify changes in embedded browser
  panes via `cmux browser …` (kb/browser-and-automation.md); passkeys and
  `cmux browser import` cover authenticated local apps.
- **Fork the workflow itself**: the "worktree manager" blog's pattern is to let
  Claude create worktrees/branches/PRs using cmux primitives (custom commands,
  plus-button actions, CLI) rather than a built-in worktree feature.
