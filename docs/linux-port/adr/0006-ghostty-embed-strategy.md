# 0006 — Ghostty embedded via a realize-gated GTK shim

- **Status:** Accepted (open review)
- **Date:** 2026-07-16 (decided) · review noted 2026-07-23
- **Deciders:** hias + Claude

## Context

The port embeds Ghostty terminals. macOS uses Ghostty's "embedded" apprt
where the host app supplies size and drives everything. On GTK we built a
shim (`ghostty_gtk_embed`) that mounts Ghostty surfaces as GTK widgets. A
recurring question (parked in the human's notes): does our approach — which
gates surface work on GTK realize/map — compare well to the macOS embedded
apprt, and what are the strengths/weaknesses of each?

## Options considered

- **A — mirror the macOS embedded apprt exactly:** maximal parity with the
  reference, but macOS drives sizing/lifecycle differently than GTK's
  realize/map model expects.
- **B — a GTK-native shim gated on realize/map:** fits GTK's widget
  lifecycle, but means the port's embed semantics diverge from macOS in
  ways we must keep proving safe (background panes, respawn, replay).

## Decision

**Option B** — the realize-gated GTK shim (branch `linux-gtk-embed`,
`Doptimize=ReleaseSafe`). It backs the daily driver and is human-confirmed
"supersmooth". Kept **open for review**: the strengths/weaknesses
comparison vs the macOS embedded apprt is a standing question, and the
bare-Ghostty-relocation respawn (GAPS Now) is a known rough edge of this
strategy.

## Consequences

- **Buys:** terminals that fit GTK's lifecycle; the shim is small and
  ownable; ReleaseSafe is snappy and correct.
- **Costs:** embed semantics diverge from macOS, so lifecycle edges
  (background spawn, respawn, mapped-gated replay) each needed their own
  proofs; ReleaseFast SEGVs (parked); relocating a never-tabbed Ghostty
  pane still respawns its shell.
- **Open:** if the comparison ever favors the macOS model for a class of
  bugs, this ADR gets superseded rather than quietly amended.

## Links

- [GHOSTTY-SHIM.md](../GHOSTTY-SHIM.md), roadmap/05-ghostty-embed-hardening,
  GAPS "bare Ghostty pane relocation" row; the human's parked comparison note.
