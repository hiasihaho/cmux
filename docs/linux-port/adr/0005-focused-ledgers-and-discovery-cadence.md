# 0005 — Keep focused ledgers; automate macOS-drift discovery

- **Status:** Accepted
- **Date:** 2026-07-23
- **Deciders:** hias + Claude

## Context

Parity is tracked across several docs (PARITY = state, GAPS = backlog,
UX-PARITY = look/feel, CONCEPTS/kb = intent, wiring = internals). The
temptation was to merge them into one "source of truth" board. Separately,
macOS cmux keeps shipping, so the port must keep *discovering* surface it
doesn't yet cover — and one-shot surveys don't scale to "over time".

## Options considered

- **A — one consolidated source-of-truth doc:** one place to look, but a
  doc that mixes state + backlog + intent + UI has four different update
  triggers and rots.
- **B — keep single-responsibility ledgers, add an index + a repeatable
  discovery cadence:** more files, but each has one job and one trigger,
  and drift discovery becomes automated rather than heroic.

## Decision

**Option B.** Keep the focused ledgers; add [PARITY-DASHBOARD.md](../PARITY-DASHBOARD.md)
as an *index/roll-up* (not a new backlog), and make discovery repeatable
with **two automated tripwires run after every merge**:
`capabilities-sweep.py` (CLI verbs) and `macos-surface-survey.py` (the
macOS Action command registry / panel types / settings sections, diffed
against a reviewed ledger). New macOS items surface as `NEW (triage)`.

## Consequences

- **Buys:** each doc stays legible and honestly-triggered; "what did macOS
  grow?" is answered by re-running two scripts, not a manual re-survey;
  the dashboard's numbers are generated, so they can't silently rot.
- **Costs:** more files to know about (mitigated by the dashboard index and
  the CATCHUP doc map); the survey's ledger dispositions are seeded and
  need refining as we touch each area.
- **Enabler:** only possible because the catch-up merge put the macOS
  `Sources/` in the same tree — a survey can diff them directly.

## Links

- [PARITY-DASHBOARD.md](../PARITY-DASHBOARD.md), `linux/scripts/macos-surface-survey.py`,
  `capabilities-sweep.py`, `macos-surface-ledger.json`; PROGRESS 2026-07-23.
