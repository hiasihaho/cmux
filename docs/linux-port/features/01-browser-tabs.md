---
title: Browser tabs per pane
area: browser
mac: full
linux: full
verbs: browser.tab.list, browser.tab.new, browser.tab.switch, browser.tab.close
---

# Browser tabs per pane

## Purpose

A browser *pane* holds several *tabs*, like a real browser — so an agent
(or human) researching across many pages doesn't burn one pane per page.
The pane stays a single unit in the split tree; tabs multiply inside it.
This mirrors macOS's per-pane tab model exactly, which is what makes the
shared CLI's tab verbs work unchanged on both platforms.

## Usage

Over the socket / CLI (the agent surface):

- `browser.tab.list` — each tab's index **within its pane**, plus
  `selected`/`focused` markers.
- `browser.tab.new` — resolves its anchor the way macOS does: explicit
  pane → explicit surface → focused surface.
- `browser.tab.switch` / `browser.tab.close` — by pane-relative index.

In the UI, tabs render as an AdwTabView strip on the pane (since
2026-07-21); popups opened by a page join the opener's pane as new tabs
and inherit its browser profile.

## Implementation

The pane owns an `AdwTabView`; each tab is a full browser surface
(WebKitGTK webview + its automation state). `surface.list` enumerates
ALL surfaces including background tabs — this fed the shared CLI's
surface resolution, which used to fail for non-selected tabs while only
each pane's visible leaf was listed. Tab identity is stable across
switches, so automation verbs targeting a background tab work without
raising it.

## Links

- [PARITY.md](../PARITY.md) — "Browser tabs as a socket surface" row
- [Wiring ⑧ Browser stack](../wiring/07-browser.md)
