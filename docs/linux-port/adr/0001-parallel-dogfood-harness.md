# 0001 — Parallel-dogfood harness (disjoint packages, worktree + scratch + profile)

- **Status:** Accepted (testbed-proven; not yet run on real GAPS packages)
- **Date:** 2026-07-23
- **Deciders:** hias + Claude

## Context

The port now has a clear backlog ([GAPS.md](../GAPS.md),
[PARITY-DASHBOARD.md](../PARITY-DASHBOARD.md)) and a verified parallel-agent
primitive (claude-teams teammates as native splits). We want to work
several packages at once — but N agents in one repo risks git chaos
(concurrent index/branch races), runtime collisions (each needs a cmux to
test in), and research collisions (shared cookies). How do we parallelize
without any of that?

## Options considered

- **A — teammates share one checkout, coordinate by convention:** simplest
  to start, but concurrent edits to one working tree/index is exactly the
  chaos we want to avoid; "be careful" does not scale to N agents.
- **B — one branch per agent in the same checkout:** still one shared index
  and working tree; branch-switching under parallel agents is a race.
- **C — a worktree + isolated runtime per agent, integrated via a local
  bare repo, gated by static scope-disjointness:** more machinery, but
  each agent is fully isolated and merges are conflict-free by
  construction.

## Decision

**Option C.** Each work *package* declares a **file scope**; the harness
refuses to dispatch if two scopes overlap (a static check at dispatch
time, not a merge-time surprise). Each package gets its own `git worktree`
(own branch off base), its own `scratch.sh` cmux instance, and its own
browser profile. Branches integrate through a **local bare repo**, so the
human's checkout and origin are untouched until a deliberate promote.
Tooling: `linux/scripts/pkg-harness.sh`; protocol + report frame in
[PARALLEL-DOGFOOD.md](../PARALLEL-DOGFOOD.md).

## Consequences

- **Buys:** conflict-free parallel branches by construction; per-agent
  runtime + research isolation (proven: distinct sockets/displays/
  profiles); a reviewable convergence point (the bare repo + report
  template); nothing reaches origin without human promotion.
- **Costs:** packages must be carved to be file-disjoint, which limits how
  finely we can parallelize — the real hotspot is `CmuxApp.swift` (several
  concerns share it), so a batch keeps it to one package or we split its
  concerns first.
- **Forecloses:** nothing permanently; a package that *needs* to touch
  another's files simply isn't parallel-eligible in the same batch.
- **Unproven:** the mechanics passed on a synthetic testbed; the first real
  run (claude-teams teammates on real code) may surface build/test-timing
  or supervision needs a no-op rehearsal can't.

## Links

- Tooling: `linux/scripts/pkg-harness.sh`, `pkg-report-template.md`
- Design + rehearsal result: [PARALLEL-DOGFOOD.md](../PARALLEL-DOGFOOD.md)
- Isolation primitives: `scratch.sh` (ADR-adjacent), browser profiles
  ([0007-ish]—see roadmap/07), PROGRESS 2026-07-23.
