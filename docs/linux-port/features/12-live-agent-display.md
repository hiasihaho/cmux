---
title: Live agent display (watch harness)
area: dev-tooling
kind: meta
detects: dead watch-pipeline links (x11vnc / websockify / noVNC serving / pane actually connected)
check: scratch.sh watch-status <tag>
adr: 0010
---

# Live agent display (watch harness)

## Purpose

A **meta harness**: makes an agent's isolated Xvfb display (`scratch.sh`,
:140–:159) live-visible in a browser pane of the caller's cmux — and turns
that pane into a **pointing channel**: the human clicks the element they mean
*inside the agent's display* (VNC injects real X events), and the agent reads
back exact coordinates plus a crosshair-marked screenshot. Deixis — "this
one, here" — which neither a screenshot stream nor prose can express.

## Usage

```sh
scratch.sh watch <tag>          # x11vnc+noVNC -> pane in a background workspace
scratch.sh watch-status <tag>   # verify every link, incl. "pane connected"
scratch.sh point <tag> out.png  # pointer coords + crosshair-marked shot
scratch.sh unwatch <tag>        # stop; also implied by scratch.sh stop
```

## Implementation

Ports derive from the display (`:N` → rfb `5900+N`, web `6900+N`), both
localhost-only. x11vnc 0.9.17 exits on sight of `WAYLAND_DISPLAY`, so the
launcher scrubs the session vars. The client is an ordinary browser surface
in a background workspace — backgrounded WebKit pages keep running, so the
VNC session connects and holds without ever stealing focus. Interactive on
purpose (human clicks pass through to the agent's display); `point`
completes the loop with xdotool + ImageMagick. `unwatch` kills strictly by
recorded pid after `/proc` cmdline verification — never by name.

## Kind

**meta** — dev tooling for watching and steering agents' isolated instances;
measured by its `watch-status` guard, not by shipping verbs. No macOS
equivalent (built on Xvfb; ADR-0010's origin is the Linux dogfood harness).
