# 0011 — Features board: measured status, authored descriptions

- **Status:** Accepted (2026-07-24)
- **Date:** 2026-07-24
- **Deciders:** hias + Claude

## Context

We want a comprehensive **feature overview board**: what the port has,
what's in the running **daily** instance vs the built **dev** binary,
what cmux-mac has that we don't — and, over time, per-feature pages with
the *why*, usage, and technical implementation. The atlas viewer already
renders any `index.json` + md directory, so the rendering layer is free.

The constraint comes from the same day this was proposed: feature status
already lives in five places (PARITY.md, FEATURES.md, GAPS.md,
`macos-surface-ledger.json`, the sweep scripts), and the port's own
`system.capabilities` list had silently gone **16 methods stale** before
`capabilities-sweep.py` grew a self-check. Every hand-maintained status
list drifts. A hand-curated features board would be the sixth copy of
truth and would rot the same way.

There's also a category difference the design must respect: **"what's in
daily" is runtime state, not repo state** — the daily instance runs
whatever binary it was last promoted onto, which the repo alone cannot
know.

## Options considered

- **A — hand-curated board:** one more md table. Cheapest today; joins
  the drift graveyard tomorrow.
- **B — fully generated board:** derive everything from ledgers/sweeps.
  No drift, but no home for purpose/usage/implementation prose — the
  content the board exists to grow toward — because that prose is not
  derivable.
- **C — hybrid (status measured, descriptions authored):** each feature
  is an authored md page whose front matter declares what it *maps to*
  (socket verbs, ledger command keys); a generator computes the status
  columns from those mappings and emits the board + atlas index. Daily
  state comes from a **promote-time manifest**: `promote.sh` stamps the
  git SHA and a live `system.capabilities` snapshot when it restarts the
  daily.

## Decision

**C.** Concretely:

1. **Authored pages** in `docs/linux-port/features/NN-<slug>.md`: front
   matter (`title`, `area`, `mac`/`linux` feature-level judgment,
   `verbs`, `commands`, cross-links) + body sections *Purpose / Usage /
   Implementation*. Prose ages slowly; mappings are validated.
2. **Generator** `linux/scripts/features-board.py` emits `_board.md`
   (the overview table) and `index.json`, computing per-verb reality:
   Linux-dispatched (same parsing as `capabilities-sweep.py`), macOS
   presence (advertised ∪ CLI-sent), and daily presence (manifest
   snapshot). `--check` exits 1 when the generated board is stale or a
   front-matter verb name matches nothing (typo guard).
3. **Measured over asserted:** where an authored claim contradicts
   measurement (`linux: full` but a mapped verb isn't dispatched), the
   board shows a ⚠ on the row — surfacing the contradiction *is* the
   board's job, so it warns loudly but only staleness/typos hard-fail.
4. **Promote stamps a manifest** (`promote-<slot>.json` in the cmux
   state dir): date, git SHA, and the freshly started instance's
   capabilities. The board's *daily* column reads it; absent manifest
   degrades to "unknown", never breaks.
5. **FEATURES.md folds in later.** Once enough pages exist, FEATURES.md
   becomes a pointer (or a generated view) — the goal is to *collapse* a
   copy of truth, not add one.

## Consequences

- **Uniqueness is verified, not asserted (2026-07-24).** A `mac: none`
  page (a port-unique feature) is cross-checked against the measured
  macOS-served set: ★ when its mapped verbs are genuinely absent,
  ★ᵃ when it has no verb to measure (authored judgment, flagged as
  such), and **⚠ false** when macOS actually serves the verbs — the
  same measured-over-asserted discipline applied to the 'unique to
  cmux-adw' claim, with a dedicated summary section on the board.


- Authored pages can still rot — but the rot surface shrinks to prose
  and feature-level judgments; every mapping is machine-checked, and the
  ⚠ mechanism turns contradictions into board content instead of silent
  lies.
- The manifest records promote-time provenance (repo SHA at promotion,
  not the binary's build SHA) — an approximation, honest enough because
  the capabilities snapshot is measured from the live instance.
- Per-feature granularity is a judgment call the generator can't make;
  the seed pages set the calibration (a feature ≈ one FEATURES.md
  bullet, not one verb).
- One more atlas to serve — at zero viewer cost (ADR's atlas viewer is
  generic by design), one registry line in `atlas-serve.sh`.
- The sixth-copy risk is real and accepted *in bounded form*: the board
  duplicates PARITY.md's headline per-feature status, but generated —
  when they disagree, trust the board and fix PARITY.

## Links

- ADR-0005 (focused ledgers + discovery cadence — this extends the same
  philosophy from verbs/commands to features), the 2026-07-24
  capabilities-drift PROGRESS entry (the cautionary tale), PARITY.md,
  FEATURES.md, `linux/scripts/capabilities-sweep.py`, ADR-0012 (pinning
  boards like this one to the sidebar).
