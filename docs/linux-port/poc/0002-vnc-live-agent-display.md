---
title: Live agent display in a pane (VNC)
area: browser
kind: composition
status: adopted
linux: proven
mac: n-a
substrate: scratch.sh Xvfb harness + browser surface (08-browser-automation) + x11vnc/noVNC (system packages)
adopted: 12-live-agent-display
evolves_to: >
  native VNC pane type via gtk-vnc2 (ADR-0010 option B, stage 2); per-agent
  "watch me work" workspaces wired into dogfood.sh / the agent runtime;
  take-over mode (interactive VNC) with focus etiquette
---

# 0002 — Live agent display in a pane (VNC)

- **Status:** adopted (2026-07-24, same day as proven) — wired in as
  `scratch.sh watch`/`watch-status`/`point`/`unwatch`; feature page
  `features/12-live-agent-display.md`
- **Substrate:** `scratch.sh` isolated displays × browser surfaces × `x11vnc` + `noVNC`
- **Origin:** ADR-0010 (visible isolated displays for agents), option B, stage 1

## Purpose

ADR-0010 left open whether an agent's isolated Xvfb display can be made
**live-visible** in a cmux pane (option B) or whether screenshot-on-demand
(option A) is the right ceiling. This POC de-risks B *without building
anything*: no new pane type, no new dependency in the app — the VNC client is
noVNC running in an ordinary **browser surface**, composing with POC-0001's
"browser surface per agent" result.

## The pipeline (all existing parts)

```
scratch.sh start <tag>          # Xvfb :140-:159 + isolated cmux-adw
x11vnc -display :140 -localhost -rfbport 5920 -shared -forever -nopw -bg
websockify --web /usr/share/novnc 127.0.0.1:6081 localhost:5920
cmux new-workspace --name vnc-poc --focus false          # background, no focus theft
cmux new-surface --type browser --workspace workspace:N \
  --url "http://127.0.0.1:6081/vnc.html?autoconnect=true&resize=scale"
```

## What we proved

- The browser surface **connects and stays connected** — verified from the
  outside via `cmux browser --surface surface:N eval`: noVNC reports
  `noVNC_connected`, status "Verbunden mit … :140", canvas present.
- The scratch instance's UI (a full cmux-adw with a live ticking clock in a
  VTE pane) streams into the pane; `scratch.sh shot` of the raw display and
  the pane's noVNC state agree.
- **A backgrounded browser surface keeps its WebKit page running**: the VNC
  session was established and held while the workspace was never selected.
  Live-watching does not require the pane to be visible first.
- Per-agent scaling is structural: each agent already owns a distinct display
  (`:140+k`), so `rfbport 5920+k` / web `6081+k` gives N conflict-free live
  views for N agents.

## Caveats measured (the POC's real yield)

- **x11vnc refuses to start under Wayland env**: it sees `WAYLAND_DISPLAY`
  and exits before trying the X display. Launch with
  `env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE x11vnc …`. Any future wrapper
  (scratch.sh integration) must scrub these.
- **`cmux browser screenshot` needs a visible surface** (`invalid_state` on a
  background workspace) — but `browser eval` works backgrounded, which is how
  the connection was verified without stealing the human's focus.
- `-nopw` is acceptable only because both listeners are `-localhost`; anything
  beyond a localhost POC needs auth.

## Unique to cmux-adw, or also cmux-mac?

`mac: n-a` — the composition is built on Xvfb displays and the Linux scratch
harness; macOS has neither. The *idea* (watch an agent's isolated UI in a
pane) could exist there via different plumbing, but nothing is claimed.

## Stage 2, if adopted

`gtk-vnc2` 1.5 (GTK4 `VncDisplay` widget + GIR typelib) is already installed
on the dev host and `gtk-vnc2-devel` is in the Fedora repos — a **native VNC
pane type** would drop the noVNC/websockify middleman and gain real pane
semantics (focus, splits, session restore). That is the actual ADR-0010 B
decision; this POC shows the only remaining question is *whether the live
view earns a pane type*, not whether it can work.

## Teardown

```
scratch.sh stop <tag>                   # kills Xvfb + scratch instance
pkill -x x11vnc                         # (external shell only, not from inside)
kill <websockify-pid>; cmux close-workspace --workspace <ref>
```
