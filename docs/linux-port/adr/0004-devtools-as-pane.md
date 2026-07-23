# 0004 — DevTools is a real cmux pane, not a WebKit-owned dock

- **Status:** Accepted
- **Date:** 2026-07-21
- **Deciders:** hias + Claude

## Context

Browser panes need Web Inspector / DevTools. macOS lets WebKit own the
inspector's dock state (attached bottom/side, or a detached window) and
merely toggles it. WebKitGTK hands out the inspector's widget only inside
its `attach` signal, and that widget is a `WebKitWebViewBase`, not a
`WebKitWebView`.

## Options considered

- **A — let WebKitGTK own the inspector window/dock, like macOS:** least
  code, but the inspector floats outside cmux's pane model — not
  socket-drivable, not splittable, not a surface agents can target.
- **B — reparent the inspector widget into a real cmux pane:** more
  machinery (register-first, show-then-reparent, handle both `attach` and
  `open-window`), but DevTools becomes a first-class surface.

## Decision

**Option B.** DevTools opens as a real cmux pane: an empty container is
registered *before* the split lands, `show()`+`attach()` fire, and the
inspector widget is reparented in. The JS console
(`browser.console.show`) reveals the same pane and focuses it (no public
WebKitGTK tab-flip exists, so we don't fake one).

## Consequences

- **Buys:** DevTools is a surface — tabs, splits, socket-drivable, part of
  session topology; arguably better than macOS here.
- **Costs:** the embedding is delicate (several silent-failure points:
  signal never fires, NULL widget, zero-size allocation) — heavily traced
  and commented. The inspector is not persisted across restart (WebKit
  only yields the widget live).
- **Deviation from macOS:** deliberate; recorded 🎨 in
  [UX-PARITY.md](../UX-PARITY.md).

## Links

- `linux/Sources/CmuxAdw/InspectorSurfaces.swift`,
  [wiring/07-browser.md](../wiring/07-browser.md); PROGRESS 2026-07-21/22.
