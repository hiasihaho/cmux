---
title: Ephemeral browser panes
area: browser
mac: none
linux: full
verbs:
---

# Ephemeral browser panes

## Purpose

`cmux browser open <url> --profile ephemeral` opens a **leave-no-trace**
browser pane: a fresh in-memory WebKit session that persists no cookies,
cache, or storage, shares nothing with any other pane, and is destroyed
when the pane closes. Built for agents visiting untrusted sites, or any
"look but leave nothing" browsing.

## Usage

```sh
cmux browser open https://example.com --profile ephemeral
```

`ephemeral` is a reserved profile name — it never appears in
`browser profiles list`, and create/rename/delete/clear reject it.

## Implementation

The reserved profile resolves to a fresh
`webkit_network_session_new_ephemeral()` **per pane** (never cached), so
each ephemeral pane gets its own in-memory jar; the construction ref is
dropped after the web view adopts the session, so it lives and dies with
the pane (`BrowserProfiles` + `BrowserSurfaces`, dogfood batch 1). It
rides the existing `browser.open_split` verb with a `profile` param — so
it has **no distinct socket verb**.

## Why this is unique to cmux-adw

macOS cmux ships `BrowserProfileStore` (persistent profiles) but shows no
sign of leave-no-trace panes: the only `ephemeral` in `Sources/` is an
unrelated `URLSessionConfiguration.ephemeral` (a one-off network request,
not a pane data store) and a remote-tmux mirror — no
`WKWebsiteDataStore.nonPersistent()` for a pane. The board marks this
**★ᵃ (authored)** because there is no distinct verb to measure: the
uniqueness rests on the Sources check above, not on a verb diff, and the
marker says so honestly. If a future macOS version adds incognito panes,
this page's `mac:` flips and the ★ disappears.
