# 0009 — Agent work visibility: structured reporting, pane-review, and name↔pane mapping

- **Status:** Proposed (open — decision deferred)
- **Date:** 2026-07-24
- **Deciders:** hias + Claude (open for discussion)

## Context

Batches 1–2 showed that **only part of an agent's important work reaches
the main session** through its final report. The highest-value outputs —
the teardown-lifecycle bug, the full context of the codex-teams
app-server leak — reached the integrator because the **human read the
agent's pane**, not from the report. Two frictions compound it:

1. The report is a one-shot summary; findings, product bugs, and honest
   friction can get compressed out.
2. Reviewing the pane is *manual and guessy*: teammate panes are labeled
   by agent **type** ("general-purpose"), not by the agent's **name** —
   yet the messaging layer *does* know the names (`browser-ephemeral`,
   `teams-siblings`). Finding the right pane meant reading both and
   inferring.

## Options considered

- **A — richer structured report template.** More required fields:
  findings, product bugs discovered, harness friction, honest
  limitations/skips, escalations. Cheap; already ad-hoc'd once (the
  "harness friction" field produced the `.build`-symlink fix).
- **B — main-session reviews panes systematically.** A norm ("read the
  agent's pane before acting on a surprising report") plus the
  infrastructure to do it: a **name→surface mapping** so the orchestrator
  can `read-screen` the right agent by name.
- **C — both.** A tightens the push channel; B adds a pull channel and the
  mapping that makes it systematic.

## Decision

**OPEN.** Current lean: **C (both)**. The **name↔pane mapping is the
load-bearing piece** — either a harness-maintained `name → surface_ref`
registry recorded at spawn, or making cmux teammate **pane titles = the
agent's name** (a cmux-level label change), or both. With the mapping,
pane-review becomes `read the pane named X`; without it, B stays manual.

## Consequences

- Richer reports risk being *ignored if too long* — keep the frame tight,
  add fields that carry decisions (bugs/escalations/friction), not prose.
- Pane-review needs the mapping **and** a norm; the mapping alone is inert
  without the habit of using it, and the habit is painful without the
  mapping.
- Pane-title = agent-name is a small cmux change with broad payoff (every
  human glance at the split tree becomes legible), and it doubles as part
  of 0008's agent↔runtime registry.
- This is self-reinforcing: better visibility is *how the harness keeps
  improving from its own users' friction* — the loop that produced the
  lifecycle fix and the `.build` symlink.

## Links

- ADR-0001, PROGRESS batch 1–2 (findings that came via the pane, not the
  report), ADR-0008 (shares the agent↔surface registry).
