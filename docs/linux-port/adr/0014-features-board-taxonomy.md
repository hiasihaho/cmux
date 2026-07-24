# 0014 — Features board taxonomy: product / inbuilt-harness / meta-harness

- **Status:** Accepted (2026-07-24)
- **Date:** 2026-07-24
- **Deciders:** hias + Claude

## Context

The features board (ADR-0011) began as a flat list of features measured
against macOS via socket verbs. But the port has grown three genuinely
different kinds of thing, and a flat board conflates them:

1. **leaf user features** — browser tabs, pane zoom, ephemeral panes;
2. **product subsystems that are themselves frameworks** — the control
   socket, browser automation, the tmux-compat shim / claude-teams, the
   attention pipeline. These are shipped, map to verbs, and are
   comparable to macOS — but they are *frameworks*, not leaf features;
3. **the dev tooling we built to develop/measure/verify the port** — the
   comparison harness (capslib + drift sweeps), the parallel-dogfood
   harness, the atlases, the test gate. These do NOT map to socket verbs
   and are not user features; comparing them to macOS's *product* is a
   category error.

## Options considered

- **A — product-only board.** Simplest; leaves the frameworks and the
  meta tooling uninventoried, so a big part of what we built is invisible.
- **B — product vs meta (two-way).** Separates dev tooling out, but lumps
  leaf features and framework subsystems together.
- **C — three-way: product / inbuilt-harness / meta-harness.** Names the
  framework subsystems distinctly and gives the meta tooling a treatment
  that fits (existence + `--check`, not verbs).

## Decision

**C.** A `kind:` front-matter field (`product` default | `inbuilt` |
`meta`) drives three board sections:

- **Product** — leaf features, measured vs macOS (mac / Unique / Linux /
  verbs), including the verified-uniqueness column.
- **Inbuilt harnesses** — framework subsystems, the *same* measured
  treatment (they ship and map to verbs), just grouped apart so the map
  distinguishes "a framework" from "a leaf feature".
- **Meta harnesses** — dev tooling, a different table (what it detects /
  does · a `check:` verify command · its ADR) and **no Unique-vs-macOS
  column**, because comparing our dev tooling to macOS's product is a
  category error. The board notes that some meta tooling mirrors macOS's
  own (the test gate) while some is port-specific (the drift sweeps).

## Consequences

- The board becomes a *complete map*: what the port does (product +
  inbuilt) **and** what we built to prove it (meta) — the meta half is
  arguably the more distinctive part and was previously invisible here.
- More classification judgment per page (leaf vs framework vs tooling);
  `kind` defaults to `product`, so existing pages are unaffected.
- The Unique column and "Unique to cmux-adw" summary apply to product +
  inbuilt only — uniqueness is a *product* comparison.
- The comparison harness (capslib + the three tools) is now itself a
  first-class, self-documented entry — the board describes the tooling
  that keeps the board honest.

## Links

- ADR-0011 (the board), ADR-0005 (the drift sweeps / discovery cadence),
  ADR-0001/0009/0013 (the parallel-dogfood harness it inventories),
  `linux/scripts/features-board.py`, `capslib.py`.
