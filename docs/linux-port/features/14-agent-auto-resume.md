---
title: Agent session auto-resume
area: session
kind: product
mac: full
linux: full
verbs:
---

# Agent session auto-resume

## Purpose

After a restart/promote, terminal surfaces whose agent sessions the
shared-CLI hooks recorded come back **mid-conversation**: the agent's
native resume command (`claude --resume <id>`, `codex resume <id>`, … —
the macOS 17-agent matrix, 13 ported) is typed into the freshly spawned
shell once it can take input. The promote workflow's manual
`claude --continue` step disappears.

## Shape

`linux/Sources/CmuxAdw/AgentResume.swift`: the hook stores
(`~/.cmuxterm/<agent>-hook-sessions.json`, written by the shared CLI on
Linux since the port began) map `activeSessionsBySurface[<uuid>]` →
session id; surface UUIDs persist across restore (SessionStore v3), so
matching is exact. Delivery reuses the scrollback-replay pattern
(readiness-gated main-loop poll) through the shared `surfacePTYWrite`
path; resumed surfaces skip stale scrollback replay (macOS parity —
"avoids replaying stale prompts"). Setting
`linux.autoResumeAgentSessions` / env `CMUX_AUTO_RESUME`, default on.

Deviations (PARITY.md): fixed command table only — the record's launch
command is never executed and session ids are charset-validated before
being typed; no approval store / launcher scripts / custom bindings;
no shell-activity gate at save. kimi's resume command is undocumented
upstream → skipped until verified.

## Verified

`agent-resume-smoke.sh` — 5 assertions: live surface uuid → fixture
record → save → restart → stub agent receives `--resume <id>`;
`CMUX_AUTO_RESUME=0` suppresses.
