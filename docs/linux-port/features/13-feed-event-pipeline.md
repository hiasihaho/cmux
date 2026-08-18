---
title: Feed — agent-hook event pipeline
area: notifications
kind: inbuilt
mac: full
linux: full
verbs: feed.push, feed.list, feed.jump, feed.permission.reply, feed.question.reply, feed.exit_plan.reply
---

# Feed — agent-hook event pipeline

## Purpose

The structured record of agent activity: hooked agent sessions stream
events (prompts, tool use/results, turn ends, permission requests) into
per-session **workstreams**; any socket client queries them or answers
pending decisions. One reader covers every agent — the "universal
multi-agent tap" the lfm-dl field report asked for (roadmap/08 item 1).

## Shape

The engine IS the shared macOS one (`CMUXAgentLaunch`:
WorkstreamStore/Event/Item, ring buffer, JSONL persistence) — ingest
correlation and wire shapes are macOS semantics by construction, with
`FeedWireEncoding` mirroring `FeedSocketEncoding`. Linux-specific
composition (`linux/Sources/CmuxAdw/Feed.swift`):

- blocking `feed.push` waits on a **main-loop timeout** with a deferred
  respond (macOS parks a socket-worker thread; on GTK that would freeze
  the loop);
- per-instance JSONL beside the session file (`<stem>-feed.jsonl`) —
  scrollback's isolation lesson applied;
- verbs queue behind the history-load readiness gate (the load *assigns*
  the item array; an ingest racing it would be clobbered);
- required the app-wide MainActor pump (PROGRESS 2026-08-18 late): the
  feed was the first CmuxAdw code to use Swift Concurrency at all.

Deviations vs macOS: `feed.jump` answers known-workstream (macOS resolves
hook-session records); no codex `tool_input_capabilities` enrichment; no
agent-PID watcher (pending items expire via wait timeout). On-disk
payloads follow upstream redaction (tool inputs/results redacted, prompts
kept).

## Verified

`feed-smoke.sh` — 22 assertions: both push forms, pending filter,
reply→resolved with decision, blocking push resolved live by a second
connection, timeout→expired, jump, invalid_params contracts, the CLI
ingest path (`cmux hooks feed`), and persistence (JSONL exists, holds
the run's items, parses; cross-restart restore is exercised implicitly
by the hermetic-cleanup requirement). Usage patterns: `skills/cmux-feed`.
