# 0012 — Pinned dashboards in the workspace sidebar

- **Status:** Proposed
- **Date:** 2026-07-24
- **Deciders:** hias + Claude

## Context

The port is growing overview boards: the wiring atlas, the ADR atlas
(decision graph), the parity dashboard, and now the features board
(ADR-0011). All render as URLs (the generic atlas viewer via
`atlas-serve.sh`). Today reaching one means remembering the serve
command and the URL; the boards a user cares about should be **one click
away, persistently** — pinned to the left sidebar.

macOS prior art matters: cmux-mac has a **custom sidebar** surface
(`~/.config/cmux/sidebars/`, `sidebar.custom.open`, interpreted
SwiftUI-style files behind a beta flag). Anything we add to the Linux
sidebar is either a step *toward* that surface or a deliberate,
tracked divergence.

Two practical constraints:

1. **Server lifecycle** — a pin is only as good as its URL; today
   `atlas-serve.sh` is a manually started `http.server`. A pin click
   must not land on connection-refused.
2. **Config policy** — user-visible, persistent UI configuration belongs
   in `~/.config/cmux/cmux.json` (the shortcut/settings rule).

## Options considered

- **A — pinned-links section in the workspace sidebar:** a small
  "Dashboards" section below the workspace list; a pin is
  `{title, url, icon?}` from `cmux.json` (plus `cmux dashboard pin/…`
  verbs); clicking opens/focuses a browser pane on that URL (reusing an
  existing one rather than spawning duplicates). Small model, clear
  scope, Linux extension to track in FEATURES ★ / UPSTREAM.md.
- **B — implement macOS's custom-sidebar surface:** full parity path;
  pins become one custom sidebar among many. Much larger scope
  (interpreted view files, hot reload, beta flag) for the immediate need.
- **C — convention only, no code:** keep a "dashboards" workspace whose
  browser panes point at the boards; session restore already persists
  it. Zero code, works today, but it's a convention (nothing ensures the
  server, no affordance in the sidebar).

## Decision

Proposed: **A**, with **C as the zero-code interim** until it lands.
B is not rejected — A should be built so its data model (a named,
ordered list of pinned entries) could later be *expressed* by a custom
sidebar rather than fight it.

Open questions to settle before Accepted:

1. **Server ownership** — pin click ensures the atlas server
   (spawn-on-demand from the app vs teaching the viewer to work over
   `file://`, since the md/mermaid/marked assets are all local). Leaning
   spawn-on-demand of `atlas-serve.sh` guarded by the existing
   already-serving check.
2. **Open semantics** — dedicated pinned-dashboards workspace vs a
   browser pane in the current workspace vs remember-last-placement.
3. **Scope of "pin"** — dashboards only, or arbitrary URLs (which drifts
   toward bookmarks — probably out of scope).

## Consequences

- A adds a Linux-only sidebar affordance: a divergence to track and an
  upstreaming candidate, same as `pane.zoom`'s socket verb.
- Pins depend on a local HTTP server; until server ownership is decided,
  a stale pin can 404/refuse — the interim convention (C) has the same
  weakness, which is part of why A is worth building.
- The sidebar stays a snapshot-boundary-sensitive area (the macOS
  100%-CPU ListBox lesson); the pins section must follow the same
  immutable-snapshot row pattern as the workspace list.
- Deliberately *not* building B now risks a second migration later; the
  mitigation is keeping A's model minimal and declarative.

## Links

- ADR-0011 (the boards this pins), `linux/scripts/atlas-serve.sh`,
  macOS custom sidebars (`sidebar.custom.open`,
  `~/.config/cmux/sidebars/`), FEATURES.md ★ section, UPSTREAM.md,
  GAPS.md (sidebar family), PARITY.md "Keyboard shortcuts / sidebar"
  rows.
