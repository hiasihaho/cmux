---
title: Session persistence & restore
area: session
mac: full
linux: full
verbs: session.save
---

# Session persistence & restore

## Purpose

Closing or restarting cmux must cost nothing: every workspace, pane
tree, working directory, browser URL, scrollback buffer, and the
selection come back exactly. This is also what makes binary promotion
(`promote.sh`) a non-event — the daily instance restarts on a new binary
and the session restores around the running Claude conversations
(`claude --continue` resumes them).

## Usage

Invisible by design: periodic saves plus a final save on exit. For
agents and the promote flow, the `session.save` verb forces a save with
**final-save semantics** — scrollback captured unthrottled — before a
deliberate stop. State lives under `$XDG_DATA_HOME/cmux/` (session JSON
+ a `scrollback/` store beside it).

## Implementation

Scrollback is stored **out of band** (ADR-0003) — capture files beside
the session JSON, pruned on every save, replayed into terminals on
restore via output injection. That pruning is why a stray instance
pointed at a `/tmp` session path once deleted the test suites' capture
files (the 2026-07-22 gate-flake day): the session path decides the
prune root. Restore rebuilds the workspace/pane tree first, then
respawns shells in their saved cwds and replays scrollback.

**macOS note:** macOS persists sessions through its own restore path and
exposes `session.restore_previous` (not yet ported); `session.save` is
the Linux extension that promotion depends on. Same user feature, partly
different agent surface on each side.

## Links

- [ADR-0003](../adr/0003-out-of-band-scrollback.md) — out-of-band scrollback
- [Wiring ⑦ Session & scrollback](../wiring/06-persistence.md)
- [Wiring ⑨ Build → scratch → promote](../wiring/08-build-promote.md)
