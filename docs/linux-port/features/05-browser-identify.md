---
title: Browser surface identify
area: browser
mac: none
linux: full
verbs: browser.identify
---

# Browser surface identify

## Purpose

`cmux browser identify` reports which browser surface an automation call
would act on — the surface ref, its URL, and title — so an agent driving
several browser panes can *confirm its target before acting* rather than
assuming. A Linux-port addition with no macOS counterpart: it grew out of
the browser-automation work, where "am I about to drive the right pane?"
is a real question when many panes are open.

## Usage

```sh
cmux browser identify                 # the focused browser surface
cmux browser identify --surface :3    # a specific one
```

Returns the surface ref plus current URL/title (JSON with `--json`).

## Implementation

Dispatched by the Linux server (`ControlProtocol` → `BrowserSurfaces`),
reading the live `WebKitWebView` for URL/title. It is a pure query — no
navigation, no side effects.

## Why this is unique to cmux-adw

macOS cmux does **not** serve `browser.identify` — verified against the
measured macOS method set (advertised ∪ dispatched), where it is absent.
The board's Unique column marks this **★ (verb-verified)**: the claim is
not just authored, it is cross-checked against what the macOS server
actually serves.
