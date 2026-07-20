# Towel: What It Provides Today

Reference for the integration docs. Source: `~/dev/towel` (Rust workspace, three crates,
~6,600 LoC, not a git repo). Binaries built and installed in `~/.cargo/bin`
(`towel`, `towel-hist`, `towel-mcp`). CHANGELOG says v0.4.6; binaries report 0.1.0
(never bumped — see [03-towel-prework.md](03-towel-prework.md)).

## Philosophy

Towel is **not** an interception or permission layer. It records and attributes; it never
blocks. The design is **two-level capture**:

- **Level 1 — cooperative (MCP):** the AI explicitly routes commands through the
  `towel_run` MCP tool → structured rows in SQLite `.towel/history.db`, full output in
  `.towel/runs/<id>.log`.
- **Level 2 — audit (PTY):** `towel ai-session -- <cmd>` wraps the AI tool in a PTY and
  records *all* terminal I/O to `.towel/sessions/<session-id>.log`. Works even if the AI
  ignores MCP.
- **Cooperation score:** `towel_audit` = commands in DB ÷ commands detected in the PTY
  log. Lets an agent (or you) see how much it bypassed structured logging.

## The three binaries

### `towel` (orchestrator CLI)
`init` (creates `.towel/` + config in cwd) · `run --source --context --session -- <cmd>`
(PTY-captured single command → DB + runs log) · `exec` (legacy, no output capture) ·
`ai-session --source --description -- <cmd>` (the session wrapper) · `session start/current` ·
`hist search/recent/show/export` (incomplete delegation to towel-hist) · `start` (spawns
ghostty; layouts not implemented).

### `towel-hist` (history CLI + core lib)
`record`, `search`, `show --output --chain`, `annotate --rating --tags --notes --outcome`,
`recent/successful/failed/unreviewed`, `export`, `stats`, `retries`, `errors`, plus
`init bash|zsh|fish` which prints shell hooks (preexec/precmd capture of *human* commands,
gated on `TOWEL_ENABLED=1` + `.towel/` existing; Ctrl+T history search; warns when
`claude`/`opencode`/`aider` are launched outside a towel session).

### `towel-mcp` (MCP server, stdio, rmcp)
11 tools:

| Tool | Purpose |
|------|---------|
| `towel_run` | Execute a command via `towel run`, structured logging (params: command, source, context, timeout_ms, cwd) |
| `towel_context` | Recent commands for the project |
| `towel_search` | Fuzzy search history |
| `towel_show` | One command incl. output/chain |
| `towel_annotate` | Rate/tag/note a command |
| `towel_errors` / `towel_retries` | Query failures/retry chains (currently mostly empty — see prework) |
| `towel_audit` | Cooperation score for a session |
| `towel_sessions` / `towel_session_read` | List / read PTY session logs (raw, ANSI-stripped, metadata; ranges, tail) |
| `towel_stats` | Aggregate cooperation score + trend across sessions |

Registered per-project via `.mcp.json` pointing at the binary.

## Environment-variable contract

Set by `towel ai-session` on the child; read by shell hooks, `towel run`, and towel-mcp:

| Var | Meaning |
|-----|---------|
| `TOWEL_SESSION` | Session ID, format `ai-session-<source>-<unix_ts>` |
| `TOWEL_SOURCE` | `claude-code`, `human`, … (attribution) |
| `TOWEL_ENABLED` | `1` = hooks active |
| `TOWEL_PROJECT_ROOT` | Where `.towel/` lives; towel-mcp uses it as cwd for `towel_run` |

**This contract is the natural integration surface for cmux** — anything that sets these
four vars correctly gets the whole towel toolchain for free.

## Session log format (the Level-2 contract)

```
=== Towel AI Session ===
Session ID: ai-session-claude-code-1767975971
Source: claude-code
Command: claude
Started: 2026-01-09 17:26:11
Terminal: 179x44
[Description: optional]
========================
<raw terminal bytes, ANSI included>
========================
Session ended: 2026-01-09 18:30:00
Duration: 3829000ms
Exit code: 0
=========================
```

The `========================` delimiter is load-bearing: the V2 parser takes content
between first and last delimiter (completed) or after the last one (active), which also
makes prefilled old logs parse correctly. A crashed session (no footer) counts as
"active" forever. Any process that writes this format to `.towel/sessions/` gets
`towel_sessions` / `towel_session_read` / `towel_audit` / `towel_stats` for free —
towel does not care who wrote the file.

The V2 parser knows Claude Code's TUI: `● Bash(cmd)` (0.95 confidence),
`● towel - towel_run (MCP)` (0.99), shell prompts (0.90), `❯` user input (0.80);
filters `⎿` results, `✻` spinners, box drawing, keystroke echo.

## DB schema (`.towel/history.db`, table `commands`)

`id, project_id, command, output, exit_code, cwd, timestamp, duration_ms` +
attribution (`source, context, session_id, output_file, output_size`) +
annotations (`expected_outcome, actual_outcome, rating, tags, notes, reviewed_by, reviewed_at`) +
relationships (`parent_id, retry_of_id, error_type, error_message`).
Indexed on project, timestamp, command, source, session, rating, error_type, retry_of.
Plain SQLite — trivially readable from Swift if cmux ever wants direct access.

## Limitations that matter for cmux

(Details and fixes in [03-towel-prework.md](03-towel-prework.md).)

1. **Log size:** raw ANSI session logs reach 17–34 MB per long Claude session. cmux runs
   *many* panes in parallel — unbounded logs multiply.
2. **Parser is Claude-Code-shaped:** the V2 patterns target Claude Code's TUI. Other
   agents (Codex, OpenCode) or plain human shells inside cmux need pattern additions.
3. **Error/retry pipeline is dead in practice:** `error_type`/`retry_of_id` are almost
   never populated (extraction isn't wired into the main capture paths), so
   `towel_errors`/`towel_retries` return empty.
4. **`towel run` hardcodes a 24×80 PTY** — size-aware programs render wrong.
5. **`towel_run` ID lookup is race-prone** (`recent(1)` after insert) — a problem once
   multiple panes log concurrently.
6. **Concurrency untested:** many panes writing one `history.db` — WAL mode should be
   verified.
7. Not started: semantic search / RAG (Phase 5), session grep tools (Phase 6),
   `towel_similar`, `towel_patterns`, layouts.
