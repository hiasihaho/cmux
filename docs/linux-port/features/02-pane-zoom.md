---
title: Pane zoom (focus mode)
area: panes
mac: partial
linux: full
verbs: pane.zoom
---

# Pane zoom (focus mode)

## Purpose

Temporarily give one pane the whole workspace — read a long log, present
a browser page, focus on a single agent — without destroying the split
layout underneath. Zoom is a *view* state, not a layout mutation: un-zoom
returns the exact tree.

## Usage

- **Ctrl+Shift+Z** or the pane toolbar button toggles zoom on the
  focused pane.
- `cmux zoom-pane` / the `pane.zoom` socket verb do the same for agents.
- Zooming a *different* pane while zoomed switches the zoom to it rather
  than un-zooming first (deliberate: matches "show me this one now").
- Zoom is deliberately **not persisted** across restarts.

## Implementation

The zoomed pane's widget is presented full-workspace while the GtkPaned
split tree is retained; un-zoom reparents it back into place. The socket
verb goes through the same shared action path as the shortcut and the
toolbar button (the multi-entrypoint rule).

**macOS note:** macOS has the *command* (Toggle Pane Zoom) but no socket
verb — `pane.zoom` is a Linux extension and an upstreaming candidate, so
`mac` above is *partial*: the user feature exists there, the agent
surface doesn't.

## Links

- [PARITY.md](../PARITY.md) — "Pane zoom (focus mode)" row
- [UPSTREAM.md](../UPSTREAM.md) — upstreaming candidates
