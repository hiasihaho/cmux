---
name: cmux-feed
description: "Observe and coordinate agents through the cmux feed: query what any agent session did (tools used, prompts, turn boundaries), push hook events, and run approve/reject decision flows over the socket. Use for agent activity questions ('what did that session do?'), wiring an agent's hooks into cmux, multi-agent event taps, or blocking permission/question/plan approvals."
---

# cmux Feed — the agent-hook event pipeline

The feed is cmux's structured record of agent activity. Every hooked agent
session streams events into it (prompts, tool use, results, turn ends,
permission requests), and any socket client can query it or answer pending
decisions. One reader covers every agent — no per-agent adapter needed.

Feed items are grouped by **workstream** (`claude-<sessionId>`,
`opencode-<sessionId>`, …): one workstream = one agent session.

## Observing: what did an agent do?

```bash
cmux rpc feed.list                          # all items, oldest first
cmux rpc feed.list '{"pending_only":true}'  # only unanswered decisions
cmux rpc feed.jump '{"workstream_id":"claude-<id>"}'   # is this id known?
```

Item fields: `workstream_id`, `source`, `kind` (userPrompt / toolUse /
toolResult / stop / permissionRequest / question / exitPlan / todos …),
`status` (telemetry / pending / resolved / expired), timestamps, and
kind-specific payload (`tool_name`, `tool_input`, `text`, `questions`…).
Text fields are capped at 8k chars on the wire (`*_truncated: true` marks
a cut). Typical filter: select items by `workstream_id`, order is
insertion order.

The feed is the *index*; per-pane scrollback is the *literal transcript*.
Pair them: find the moment in the feed, then `cmux read-screen --scrollback`
on the agent's pane for the full text.

## Ingesting: getting an agent's events in

**Generic tap (any agent with hooks):** pipe the agent's native hook JSON to

```bash
echo "$HOOK_JSON" | cmux hooks feed --source <claude|codex|opencode|...>
```

Fail-open by design: outside a cmux pane (no `CMUX_SURFACE_ID`) or on
unparseable input it prints `{}` and exits 0, so it is always safe in a
hook chain. Non-actionable events forward as telemetry and return `{}`.

**Claude Code sessions:** add alongside existing hooks in
`~/.claude/settings.json` (settings hot-reload; no restart needed):

```json
{ "hooks": { "PreToolUse": [ { "hooks": [ { "type": "command",
  "command": "[ -z \"$CMUX_SURFACE_ID\" ] || cmux hooks feed --source claude || true",
  "timeout": 10 } ] } ] } }
```

Same entry under `PostToolUse` and `UserPromptSubmit` gives tool-level +
prompt capture; `Stop`/`Notification` usually already route via
`cmux claude-hook`.

**opencode:** `cmux hooks opencode install` (bundled plugin; works from
the Linux debug build layout too).

**Raw push** (no agent, e.g. tests or custom emitters):

```bash
cmux rpc feed.push '{"event":{"session_id":"s1","hook_event_name":"PreToolUse","_source":"claude","tool_name":"Bash","tool_input":"{...}"}}'
```

`event` object or the same keys top-level; `session_id`,
`hook_event_name`, `_source` are required. **Text rides in `tool_input`**
(a raw string, or JSON with a `prompt`/`text`/`message` key) — a
top-level `prompt` key is silently ignored on raw pushes (only the
`cmux hooks feed` path maps agent hook JSON into the right fields).

## Messaging sessions: feed as mailbox, prompt as doorbell

To inform or task another agent session (proven pattern, 2026-08-18):

1. **Post durably**: `feed.push` a `UserPromptSubmit` event with the
   message in `tool_input` (`{"prompt": "..."}`), `session_id` set to a
   stable per-target workstream (`announce-<target>`). It survives
   restarts; the target reads it whenever it looks. Follow-ups go into
   the SAME workstream so the thread accumulates.
2. **Ring the doorbell**: type a short read-request into the target's
   pane — `cmux send --workspace <ws> '<one-liner: read announce-… via
   cmux rpc feed.list>'` then `cmux send-key --workspace <ws> Enter`.
   TEXT AND ENTER ARE SEPARATE SENDS: a trailing `\n` becomes a newline
   INSIDE modern TUI input boxes, leaving the prompt typed but never
   submitted.
3. **Check the recipient is alive first** (`read-screen` its pane): a
   nudge typed at a dead prompt goes nowhere. Agents that exited can be
   revived first (their resume command), then nudged.
4. The target reads with its own hands (`cmux rpc feed.list`, filter its
   workstream) and replies the same way — or through the human when it
   has no socket access.

This is the pull-channel + doorbell composition; for blocking
approvals use the decision flow above instead.

## Decision flows: approve/reject over the socket

Actionable events (`PermissionRequest`, `AskUserQuestion`, `ExitPlanMode`)
create **pending** items. Two patterns:

**Blocking** — pusher waits for the decision (max 120 s):

```bash
cmux rpc feed.push '{"event":{...,"_opencode_request_id":"req-1"},"wait_timeout_seconds":60}'
# → {"status":"resolved","decision":{...}} or {"status":"timed_out"} (item expires)
```

**Polling** — push without wait, watch `pending_only`, answer later.

Answering (from any socket client — humans via UI, or another agent):

```bash
cmux rpc feed.permission.reply '{"request_id":"req-1","mode":"once"}'   # once|always|all|bypass|deny
cmux rpc feed.question.reply   '{"request_id":"req-1","selections":["opt-a"]}'
cmux rpc feed.exit_plan.reply  '{"request_id":"req-1","mode":"manual","feedback":"..."}'
```

Replies resolve the stored item even when nothing is blocked on it. Pair
with `cmux notify` to raise a desktop popup when a decision is pending.

## Contracts and pitfalls

- **Persistence**: per-instance JSONL beside the session file
  (`<session-stem>-feed.jsonl`); history loads at startup, in-memory ring
  keeps 2000 items. Instances never share feeds — a suite or scratch
  instance has its own. Hermetic tests must delete their JSONL first, or
  the previous run's history restores into their counts.
- **Redaction on disk**: persisted `tool_input`/`tool_result` payloads are
  redacted (upstream privacy design); prompt text is kept. The in-memory
  feed served by `feed.list` is unredacted (8k caps only). Treat the JSONL
  as structure-grade, not capture-grade.
- **Startup**: feed verbs queue until the history load finishes — a query
  in the first moments after app start answers slightly late, never wrong.
- **Volume**: tool-level hooks on busy agents are real traffic. Trim with
  hook `matcher`s (e.g. only `Bash`) or drop `PreToolUse` and keep results.
- Requires a cmux build with the feed verbs (Linux: 2026-08-18 or later;
  `cmux rpc feed.list` answering `unknown_method` means the running
  instance predates them — restart/promote onto the current binary).
