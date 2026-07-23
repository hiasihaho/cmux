---
title: Terminal backend chooser (Ghostty / VTE)
area: terminal
mac: none
linux: full
verbs:
---

# Terminal backend chooser (Ghostty / VTE)

## Purpose

The port runs terminal surfaces on **either** embedded Ghostty (the
default, via the GTK shim) **or** GTK **VTE** (the fallback) — selectable
in Preferences or with `CMUX_TERM`. macOS cmux is **Ghostty-only**; it has
no VTE backend and therefore no chooser. What began as a Linux-port
necessity — VTE is the safety net for environments where the Ghostty shim
can't run (Debug-mode sluggishness, ReleaseFast SEGVs, headless probes) —
became a genuine capability macOS lacks: two independent terminal engines,
switchable.

## Usage

- Preferences → **Terminal backend** (Ghostty ⇄ VTE); applies at the next
  launch (the Ghostty runtime initializes once per process).
- Or per-launch: `CMUX_TERM=vte` / `CMUX_TERM=ghostty`.

## Implementation

`LinuxSettings` stores the choice under the `linux` object in
`~/.config/cmux/cmux.json`; the surface factory swaps `VteTerminal` for
the Ghostty shim (`CMUX_GHOSTTY`-linked builds only). No socket verb — it
is a settings/launch-time choice, not a runtime command. VTE parity is
tracked separately (e.g. scrollback landed on VTE too; find-overlay has
not).

## Why this is unique to cmux-adw

macOS has no VTE — verified: `Sources/` contains no VTE usage (only
`xterm-ghostty` TERM handling). The board marks this **★ᵃ (authored)**:
there is no verb to measure, so the uniqueness rests on this page's
judgment, honestly flagged — but the judgment is backed by the Sources
check above.
