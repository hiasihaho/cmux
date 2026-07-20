# Roadmap: Towel × cmux

Suggestions for integrating **Towel** (`~/dev/towel` — AI-session recording, attribution
and audit toolkit, Rust) into the **cmux Linux port** (`~/cmux/linux` — GTK4/libadwaita
agent-workspace terminal, Swift).

Created 2026-07-17 from a full analysis of both codebases. This folder is untracked;
commit it or keep it local as you prefer.

## Documents

| File | Content |
|------|---------|
| [01-towel-overview.md](01-towel-overview.md) | What towel provides today (CLI, MCP tools, DB, PTY wrapper) and its current limitations — the integration-relevant reference |
| [02-integration-phases.md](02-integration-phases.md) | The actual roadmap: phased suggestions T0–T4, with exact hook points in the cmux source |
| [03-towel-prework.md](03-towel-prework.md) | Fixes/hardening towel itself needs before (or alongside) integration |
| [04-ecosystem-yazi-opencode-vibe.md](04-ecosystem-yazi-opencode-vibe.md) | Ecosystem additions: yazi file-manager panes, OpenCode agent parity via plugins, vibe voice control |
| [05-ghostty-embed-hardening.md](05-ghostty-embed-hardening.md) | Deferred deep-dive: the fast-churn resource leak + its security angle (agent-drivable local DoS, ReleaseFast memory-unsafety smell) and an investigation plan |

## TL;DR

cmux and towel are complementary halves of the same idea:

- **cmux** owns the terminals. It spawns every pane's shell (VTE `spawn_async` or the
  embedded-Ghostty shim), injects per-pane identity env (`CMUX_WORKSPACE_ID`,
  `CMUX_SURFACE_ID`, `CMUX_SOCKET_PATH`), can read any pane's screen+scrollback, and
  has an attention/notification pipeline plus Claude Code hooks. What it *lacks* is
  memory: no record of what commands ran, what failed, what the agent actually did.

- **towel** owns the memory. Structured per-command history (SQLite, with source,
  context, exit code, duration, output, ratings), raw PTY session logs, and an audit
  layer that computes how cooperative an agent was. What it *lacks* is a UI and a host —
  its PTY wrapper re-implements exactly the terminal-owning layer cmux already is.

The core insight: **inside cmux, towel's `ai-session` wrapper becomes redundant —
cmux itself can be the Level-2 recorder**, writing towel-format session logs natively,
while agents keep using `towel-mcp` (`towel_run`, `towel_audit`, …) as the Level-1
structured channel. Towel's DB then becomes the data source for cmux features that are
already on the parity wishlist anyway: sidebar metadata pills (cooperation score,
last-command status), the command palette (history search), and richer agent-finished
notifications.

## Suggested first step

Phase T0 needs **zero code changes**: `towel init` in a project, register `towel-mcp`
in that project's `.mcp.json`, and launch the agent inside a cmux pane via
`towel ai-session --source claude-code claude`. Everything composes today (at the cost
of a nested PTY). Use that to validate the workflow before touching cmux code.
