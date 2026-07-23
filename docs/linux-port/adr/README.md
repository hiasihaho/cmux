# Architecture Decision Records — the Linux port

Numbered, reviewable records of *decisions* — the choices with real
architectural weight and a rationale worth preserving. An ADR answers
"why is it this way, what else did we consider, and what did the choice
cost?" so future-us (and an upstream reviewer) doesn't relitigate settled
questions or misread a deliberate deviation as an accident.

**ADRs vs the other docs.** ADRs are *decisions*, not backlog, evidence,
or design detail. Add a gap to [GAPS.md](../GAPS.md); log what happened in
[PROGRESS.md](../PROGRESS.md); write detailed design in [roadmap/](../../../roadmap/);
record a decision **here**. A decision that changes look/feel also gets a
one-line entry in UX-PARITY's decisions list; the ADR is the long form.

## Lifecycle (the "ADR-like workflow")

    Proposed  →  Accepted  →  (later) Superseded by NNNN
                    ↘  Rejected

Every ADR has a **Status**. A decision starts **Proposed** (an idea to
review — the log tracks open questions too), becomes **Accepted** when we
commit to it, and is **Superseded** (never deleted) when a later ADR
overturns it. History stays legible: you can read why we once chose the
thing we later abandoned.

## How to add one

1. Copy `_template.md` to `NNNN-kebab-title.md` (next free number).
2. Fill it; keep it short — context, options, decision, consequences.
3. Add the one-line index entry below.
4. Cross-link: the ADR links to the GAPS/roadmap/PROGRESS it touches, and
   they can link back.

## Index

| # | Title | Status |
|---|---|---|
| [0001](0001-parallel-dogfood-harness.md) | Parallel-dogfood harness (disjoint packages, worktree + scratch + profile) | Accepted (testbed-proven) |
| [0002](0002-interaction-parity-sacred.md) | Interaction parity sacred, presentation negotiable | Accepted |
| [0003](0003-out-of-band-scrollback.md) | Scrollback stored out of band, replayed via inject_output | Accepted |
| [0004](0004-devtools-as-pane.md) | DevTools is a real cmux pane, not a WebKit-owned dock | Accepted |
| [0005](0005-focused-ledgers-and-discovery-cadence.md) | Keep focused ledgers; automate macOS-drift discovery | Accepted |
| [0006](0006-ghostty-embed-strategy.md) | Ghostty embedded via a realize-gated GTK shim | Accepted (open review) |
