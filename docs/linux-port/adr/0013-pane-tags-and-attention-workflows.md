# 0013 — Pane tags, and (maybe) attention-driven workflows over them

- **Status:** Proposed (open — deliberately paced)
- **Date:** 2026-07-24
- **Deciders:** hias + Claude (open for discussion)

## Context

ADR-0009 gave each agent a `name → surface` registry entry
(`.pkg/<id>/surface`). The idea: extend it to `name → {surface, tags,
state}`, so panes/agents can be **addressed, grouped, and given
attention state by tag** — and, further out, a **tag-based state machine**
where panes react to triggers by running specific tools / skills /
prompts: a flexible, attention-driven workflow engine over panes.

This spans three very different levels of cost and risk, and the point of
this ADR is to *separate* them rather than adopt the whole vision at once.
It also does not exist in a vacuum — several primitives already cover
parts of it:

- cmux's **attention pipeline** (`needsAttention`, notification store,
  desktop delivery) — pane attention already exists.
- macOS **workspace status lanes** (`markWorkspaceDone`,
  `cycleWorkspaceStatus`) — a status/state concept, at workspace grain.
- **notification hooks** (run a command per notification) and
  **custom-commands** — trigger→action already exists, config-driven.
- The **Workflow tool**, **claude-teams**, **oh-my-claudecode** —
  agent-orchestration engines already exist.
- macOS **workspace groups** — named collections in the sidebar (UI
  organization at the workspace level).

## Options considered

- **A — registry stays name-only** (nothing past 0009). No new surface;
  addressing stays 1:1 by name.
- **B — tags on the registry** (`name → {surface, tags}`). Address/group
  panes by tag (`review --tag blocked`, "all `browser` agents"). Small,
  composable, immediately useful to the harness.
- **C — tags + pane state** (a queryable state per pane:
  working/blocked/done/needs-input). Moderate — but overlaps the
  attention pipeline and macOS status lanes; best framed as the port's
  pane-grain expression of *those*, not a new concept.
- **D — trigger→action workflow engine**: pane state transitions fire
  actions (run a tool/skill/prompt). Large, powerful — and overlaps the
  Workflow tool, teams, hooks, and custom-commands. High reinvention risk.

## Decision

**OPEN, deliberately paced.** Current lean:

- **B: yes, when we next touch the registry** — tags are cheap, natural,
  and useful now (grouping/addressing agents in a batch).
- **C: only if pane-state proves useful**, and then built as *parity with
  status lanes* (reuse the attention pipeline), not a parallel concept.
- **D: do NOT build speculatively.** Set a trigger condition: build a
  workflow layer only when we hit a **concrete workflow we cannot express**
  with the existing primitives (Workflow tool for determinism, notification
  hooks for trigger→action, `send_text`/`send_key` for driving a pane,
  teams for spawning). If that day comes, prefer *composing* those over a
  new engine.

## Consequences

- Tags (B) compose cleanly with 0009's registry and 0008's lifecycle
  record (the same `.pkg/<id>/` entry can carry tags + scratch tags).
- A pane state machine (C) that ignores the existing attention pipeline
  and status lanes would fork the "what is this pane doing" concept —
  avoid; unify instead.
- A general engine (D) is a real maintenance + conceptual burden and
  risks a fourth agent-orchestration system alongside Workflow/teams/
  hooks. The trigger-condition discipline is the guard against building it
  because it's *cool* rather than *needed*.
- **Workspace-groups relationship:** a group is a coarse, UI-level tag;
  tags could eventually generalize group-membership — but keep them
  separable. Groups are a scoped macOS *parity* item (GAPS Later); this is
  a *novel* direction. Don't block or bloat one with the other.

## Links

- ADR-0009 (the registry this extends), ADR-0008 (shares the record),
  wiring/05 attention pipeline, CONCEPTS (status lanes, workspace groups),
  the Workflow tool / claude-teams (existing orchestration), GAPS
  `workspace.group.*` (Later).
