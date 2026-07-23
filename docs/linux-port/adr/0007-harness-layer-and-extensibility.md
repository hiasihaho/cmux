# 0007 — Where the parallel-agent harness lives: scripts, skill, command, or plugin

- **Status:** Proposed (open — decision deferred)
- **Date:** 2026-07-24
- **Deciders:** hias + Claude (open for discussion)

## Context

The parallel-dogfood harness (ADR-0001) is **dev-tooling shell scripts**
(`pkg-harness.sh`, `scratch.sh`) sitting *on top of* cmux runtime
primitives (teammates-as-splits, scratch instances, browser profiles).
It works and is proven across two real batches. The question: is
"scripts in `linux/scripts/`" the right home, or should this pattern be
packaged more durably — and if so, how?

Grounding facts: **cmux-mac has no equivalent harness.** Its
extensibility is entirely *config-driven* — `cmux.json` custom-commands
and actions, custom sidebars (interpreted), dock (JSON), and skills.
There is **no code-plugin API** in cmux today. So this is partly a
question about cmux's extensibility model, not just where our scripts go.

## Options considered

- **A — stay dev-tooling scripts (port-specific).** Simplest; correct for
  *developing the port*. But it's not reusable by cmux users, and the
  orchestration protocol lives only in docs + the main agent's head.
- **B — package the protocol as a skill; scripts stay the mechanism.** A
  `parallel-dogfood` skill encodes *how the orchestrator drives it*;
  `pkg-harness.sh` stays the mechanism. Cheap, reversible, matches cmux's
  skill grain. The flow is now proven (2 batches), so it's no longer
  premature.
- **C — promote to a first-class cmux command/feature** (`cmux batch`-ish)
  usable by any user on any repo. Commits cmux to supporting
  parallel-scoped-agent-work as a *product*, with its UI and maintenance.
- **D — invent a code-plugin system for cmux.** Most flexible, enables
  third-party extensions generally — but a major new surface (API,
  sandboxing, versioning, security) far beyond this one need.

## Decision

**OPEN.** Current lean: **B now** (a skill over the proven scripts),
with **C as the eventual target** *if* the pattern proves generally
useful beyond port development. **D is not justified by this need
alone** — cmux's config+skill extensibility is the established grain, and
inventing a plugin system to host one workflow inverts the cost/benefit.
Revisit D only if a *portfolio* of code-extensions wants a home.

## Consequences

- A skill is cheap, reversible, and immediately useful; it does not
  foreclose C or D.
- C would need a real UX and makes cmux responsible for the workflow;
  worth it only once demand is demonstrated outside the port.
- D is a strategic commitment (a plugin API is forever); pursuing it for
  this alone would be over-engineering.
- Interacts with 0009 (visibility) and 0008 (runtime lifecycle): whatever
  layer this lands in must carry the agent↔runtime mapping those need.

## Links

- ADR-0001, [PARALLEL-DOGFOOD.md](../PARALLEL-DOGFOOD.md); cmux
  extensibility: custom-commands / custom-sidebar / dock / skills docs.
