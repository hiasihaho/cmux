# 0008 — Agent runtime lifecycle: what dismissal/death does to an agent's surfaces

- **Status:** Proposed (open — decision deferred)
- **Date:** 2026-07-24
- **Deciders:** hias + Claude (open for discussion)

## Context

The harness isolates an agent's **git worktree**, **build**, and
**browser-profile data dir** — and `release <id>` reaps those (ADR-0001's
lifecycle fix). But an agent's **runtime surfaces** — the scratch cmux
instances it starts, the browser panes/tabs it opens — have **no defined
cleanup** when the agent is dismissed or dies. Today they're cleaned only
by *convention* (the agent stops its own scratch instances). If an agent
dies unexpectedly, those orphan — the same class as the codex-teams
app-server leak (UPSTREAM §4f), one layer up. Surfaced by the question
"does releasing an agent take down its browsers?" (answer: no — but
*nothing* does, which is the gap).

## Options considered

- **A — convention only** (agent cleans its own). Current. Zero
  machinery, but fragile: an agent that dies or forgets leaks instances,
  displays, and profile dirs.
- **B — harness tracks and reaps an agent's runtime on release.** The
  harness records what each agent spawned (scratch tags, profiles) and
  `release`/dismissal reaps them. Needs an agent↔runtime registry (ties
  to 0009's name↔pane mapping).
- **C — cmux-level ownership**: a surface/instance spawned *by* an agent
  dies *with* its owner. The cleanest model, but requires cmux to model
  "owned-by-agent" lifetime — a real feature.
- **D — a reaper that GCs orphans by liveness** (no owning agent alive →
  reap after a grace period). Catches the death case A/B miss.

## Decision

**OPEN.** Current lean: **B + D** — `release`/dismissal reaps an agent's
*known* runtime (needs the tracking registry), plus a periodic reaper for
orphans whose owner is gone. **C is the cleanest end-state** but depends
on cmux modeling agent-ownership of surfaces, which is a larger change to
land first.

## Consequences

- B needs an agent↔runtime registry — build it once, shared with 0009's
  name↔pane mapping.
- A reaper (D) can kill something still wanted; it must key on a real
  liveness signal (owning agent process gone) and a grace period, never a
  guess.
- Doing nothing (A) is a slow leak of Xvfb displays, sockets, and profile
  dirs across many batches — the same "orphaned child" smell we just
  filed against codex-teams.
- Whatever we choose should generalize: the leak pattern (codex-teams
  app-server, agent scratch instances) is one problem — *no owner reaps
  the child* — worth solving uniformly.

## Links

- ADR-0001 (lifecycle fix), ADR-0009 (name↔pane mapping enables B),
  UPSTREAM §4f (the sibling leak of the same shape).
