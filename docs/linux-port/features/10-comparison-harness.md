---
title: Comparison harness (drift sweeps)
area: dev-tooling
kind: meta
detects: CLI↔server verb drift + macOS app-surface drift (commands/panels/settings) vs the reviewed ledger
check: python3 linux/scripts/capabilities-sweep.py --check
adr: 0005
---

# Comparison harness (drift sweeps)

## Purpose

A **meta harness**: the tooling that measures the port against macOS so the
parity docs can't silently rot. `capslib.py` is the shared foundation
(`linux_served`, `mac_methods` = advertised∪dispatched, `cli_sent`); three
tools build on it — `capabilities-sweep.py` (verb drift, both protocol
generations, + a self-check of the advertised list), `macos-surface-survey.py`
(macOS command/panel/settings drift vs the ledger), and this features board.

## Usage

```sh
python3 linux/scripts/capabilities-sweep.py          # verb drift
python3 linux/scripts/macos-surface-survey.py        # macOS app-surface drift
```

Run both after every upstream merge (the discovery cadence, ADR-0005).

## Implementation

Since the catch-up merge the macOS `Sources/` live in the tree, so the tools
diff Linux dispatch against the macOS server set directly. `--check` gates
staleness so CI can enforce it.

## Kind

**meta** — dev tooling we built to develop/verify the port; measured by
`--check`, not by shipping verbs. Some of it is port-specific (the drift
sweeps have no macOS equivalent); it is not a user feature.
