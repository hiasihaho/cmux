# 0009 — Agent work visibility: structured reporting, pane-review, and name↔pane mapping

- **Status:** Accepted (2026-07-24)
- **Date:** 2026-07-24
- **Deciders:** hias + Claude

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

**Accepted: C (both), implemented 2026-07-24.**

1. **Richer report template** — `pkg-report-template.md` gains required
   decision-carrying fields: findings, product bugs discovered, harness
   friction, honest limitations/skips, escalations (in addition to the
   surface-identity line below).
2. **Agent-populated name↔surface registry** — the load-bearing piece,
   built the reliable way. *Not* a pane-title change: Claude Code
   continuously overwrites the pane title with its own activity, so an
   OSC/harness-set title won't stick. Instead, **each agent records its
   own `$CMUX_SURFACE_ID` from inside its pane** (authoritative — the
   pane knows its own id) into `.pkg/<id>/surface` as its first action.
   The harness reads it back: `pkg-harness pane <id>` → the surface ref,
   `panes` → all mappings, `review <id>` → reads that agent's screen.
3. **The norm** — "review the pane before acting on a *surprising*
   report" (`pkg-harness review <id>`), recorded in PARALLEL-DOGFOOD.md.

The agent-writes-its-own-id approach sidesteps the cross-layer title
problem and is dead simple (one `echo` in the task prompt + a file read
in the harness).

## Consequences

- Richer reports risk being *ignored if too long* — the template keeps a
  tight frame and adds only decision-carrying fields (bugs/escalations/
  friction), not prose.
- The registry is only as populated as agents are diligent about the
  `echo`; the task prompt makes it step 1, and a missing file degrades
  to the old manual tree-walk, never breaks.
- Reliable *because the pane reports its own identity* — no guessing by
  spawn order or reading screens to infer who's who (the batch-1 friction).
- Shares its shape with ADR-0008's agent↔runtime registry — the same
  `.pkg/<id>/` record can carry the agent's scratch tags for reaping.
- Self-reinforcing: better visibility is *how the harness keeps improving
  from its own users' friction* — this very ADR came from the human
  reading an agent's pane and finding the lifecycle bug.

## Links

- ADR-0001, PROGRESS batch 1–2 (findings that came via the pane, not the
  report), ADR-0008 (shares the agent↔surface registry).
