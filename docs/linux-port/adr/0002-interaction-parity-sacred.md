# 0002 — Interaction parity sacred, presentation negotiable

- **Status:** Accepted
- **Date:** 2026-07-22
- **Deciders:** hias + Claude

## Context

The port is a GTK4/libadwaita app mirroring a macOS/AppKit one. Every UI
choice raises the same question: match macOS pixel-for-pixel, or adopt the
GNOME idiom? A GTK app that cosplays macOS feels wrong on GNOME; but a
feature that lives somewhere unexpected is a real cost anywhere.

## Options considered

- **A — mirror macOS presentation closely:** familiar to macOS users, but
  alien on GNOME and fights libadwaita.
- **B — full GNOME redesign:** native-feeling, but risks moving *where
  things live*, breaking muscle memory and parity of capability.
- **C — split the concern:** treat *interaction* (what you can reach, where
  it logically lives) as near-sacred, and *presentation* (styling, chrome
  shape) as negotiable per platform.

## Decision

**Option C.** Interaction parity is near-sacred; presentation is
negotiable, and a muscle-memory-relevant *placement* change needs a
stronger justification than a styling change. Deviations are recorded, not
silent — every ❓ in [UX-PARITY.md](../UX-PARITY.md) resolves to ✅ (parity)
or 🎨 (deliberate, with rationale).

## Consequences

- **Buys:** a consistent rule for dozens of small UI calls; the port feels
  native on GNOME while staying capability-equivalent; deviations are
  auditable.
- **Costs:** requires judgment per case (styling vs placement), and a
  deviation still owes a written rationale.
- **In practice:** justified the header diet, GNOME primary menu, tab-bar
  autohide, DevTools-as-pane (see [0004](0004-devtools-as-pane.md)),
  Ctrl+Shift+J over ⌥⌘C, and accent-follows-GNOME attention rings.

## Links

- [UX-PARITY.md](../UX-PARITY.md) (Recorded decisions), PROGRESS 2026-07-22/23.
