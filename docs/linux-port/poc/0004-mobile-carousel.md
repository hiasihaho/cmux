---
title: Mobile pane carousel (phone-sized RDP viewport)
area: shell
kind: spike
status: wip
linux: proven-headless
mac: n-a
substrate: standalone adwaita-swift package (linux/poc/mobile-carousel) × VTE × scratch.sh phone geometry
adopted: —
evolves_to: >
  breakpoint-driven mobile mode in cmux-adw (sidebar/dock → overlays,
  GtkPaned chain → carousel below ~600 px), extra-keys row as a product
  surface, Flatpak on the adminvm Debian 13 golden image
---

# 0004 — Mobile pane carousel

- **Status:** wip (2026-11-04) — standalone spike builds and runs headless;
  every interaction below was driven by xdotool on a scratch Xvfb and
  checked by screenshot. **Not yet felt on a phone** — that verdict is
  hias's, over the real Guacamole → gnome-remote-desktop path
  (`~/adminvm`, `KB-GUACAMOLE-USAGE.md`).
- **Owner:** this desk (branch `mobile-carousel-spike`, worktree
  `~/cmux-mobile`). Nothing here touches `cmux-adw` or the daily.
- **Question it answers:** on a phone-sized RDP window where a finger is
  ONE mouse pointer, can full-width terminal panes in an `AdwCarousel`
  with a GNOME-style overview feel right — before the product shell is
  changed for it?

## Why a raw spike first

The product shell hangs sidebar, dock, session store and socket verbs off
every pane (`CmuxApp.swift`, `TerminalSurfaces.swift`); iterating the
carousel there costs a full build plus suite etiquette per step. The spike
is ~450 lines in its own SwiftPM package with the same adwaita-swift pin,
builds in seconds, and reuses the VTE module shape (`Sources/CVte`). What
feels right migrates; what does not is deleted with the directory.

## What is built

`linux/poc/mobile-carousel/` — `swift build`, binary `MobileCarousel`.

| piece | how |
|---|---|
| panes | one VTE per `AdwCarousel` page, full width, shell spawned per pane; `+` appends and scrolls to it, `×` closes the current one |
| **focus mode** | carousel `interactive=false`, `allow-mouse-drag=false`: the terminal owns every drag (selection) — the swipe/selection conflict is resolved by never arming both |
| **overview mode** | header toggle (grid icon). Carousel `interactive` + `allow-mouse-drag`, 24 px spacing, pages `can-target=false` + margins + dimmed card style; **swipe** moves pages (long swipes allowed), **tap** picks the page under the pointer and returns to focus. Tap vs swipe is discriminated by press/release distance (>12 px = swipe), because `GtkGestureClick` still emits `released` after a drag the swipe tracker handled |
| indicator | `AdwCarouselIndicatorDots` under the panes |
| header | `WindowTitle`: VTE title + `n / count`, or `swipe · tap to pick` in overview |
| **extra keys** | Termux-style row: Esc, Tab, **sticky Ctrl**, arrows, `/ \| - ~ : ' "`, `⇔80` (re-fit), `A− A+`, `‹ ›` (prev/next). Buttons are `focus-on-click=false` so the terminal keeps focus. Sticky Ctrl is a capture-phase key controller on each terminal: next printable key → control byte, toggle disarms. Verified: `sleep 30`, Ctrl, `c` → `^C` |
| column fit | `MOBILE_FIT_COLS` (default 80): after first map, estimate the font scale, then step down every third 120 ms tick until the measured column count reaches the target (VTE cells are whole pixels and the pty resize lags the font change) |
| env | `MOBILE_W`/`MOBILE_H` (default 392×844), `MOBILE_PANES` (3), `MOBILE_FONT_SCALE` (0.8), `MOBILE_FIT_COLS`, `MOBILE_APP_ID` |

## Running it headless (phone geometry)

`scratch.sh` learned two overrides in this branch: `CMUX_SCRATCH_APP`
(another GTK binary; readiness = process alive, no socket) and
`CMUX_SCRATCH_GEOMETRY` (Xvfb screen; multiples of 4 — gnome-remote-desktop
wants that too).

```sh
cd ~/cmux-mobile/linux/poc/mobile-carousel && swift build
cd ~/cmux-mobile
# CSS-pixel phone (what a naive viewport gives)
CMUX_SCRATCH_APP=linux/poc/mobile-carousel/.build/debug/MobileCarousel \
CMUX_SCRATCH_GEOMETRY=392x844 linux/scripts/scratch.sh start mobile
# physical-pixel phone at GNOME 200% (the adminvm image locks 200%)
CMUX_SCRATCH_APP=linux/poc/mobile-carousel/.build/debug/MobileCarousel \
CMUX_SCRATCH_GEOMETRY=1080x2340 linux/scripts/scratch.sh start mobile2 \
    GDK_SCALE=2 MOBILE_W=540 MOBILE_H=1170
linux/scripts/scratch.sh watch mobile2      # live in a pane of your cmux (ADR-0010)
linux/scripts/scratch.sh shot mobile2 out.png
```

Drive it with `DISPLAY=:14x xdotool` (click, type, mousedown/mousemove/
mouseup for a swipe). Use THIS branch's `scratch.sh` for `stop`: the
`linux-port` copy kills by `cmux-adw` name and leaves the spike running.

## Findings (headless, 2026-11-04)

1. **The two-mode model works mechanically.** Focus: drags select text,
   nothing swipes. Overview: a rightward drag from page 3 lands on page 2
   and stays in overview; a stationary tap exits to focus on the tapped
   page. First attempt had every swipe also exit overview (`released`
   after a drag) — fixed by the press-distance check.
2. **Columns are decided by pixels, not by the carousel.** At 392 px
   logical width VTE cells go 5 px → 76 cols, 4 px → 95 cols; 80 does
   not exist and both are illegible on a phone. At 1080 px physical /
   GDK_SCALE=2 (540 logical) the fit lands at **88 cols at 6 px cells**,
   legible. So the product question "does Guacamole hand the session
   physical pixels?" matters more than any widget choice. Guacamole's
   client multiplies the viewport by `devicePixelRatio` for the RDP size;
   with the adminvm's locked 200 % GNOME scale that should yield the
   second case — **to be confirmed on the real path**.
3. **No peeking neighbours.** `AdwCarousel` allocates every page the full
   carousel width, so the GNOME-overview feel of seeing the next pane's
   edge is not available from it. Spacing + margins + dimming give the
   mode change; if hias wants thumbnails, the next candidate is
   `AdwTabOverview` (raw C like `gtk_paned` today), which would also
   bring GNOME's own touch/tap semantics.
4. **Sticky Ctrl via capture-phase key controller is enough** for Ctrl+C/
   D/Z/L/R; it needs no VTE patch and no modifier injection.
5. **The header is tight at 392 px**: title + 4 buttons already truncate
   the VTE title. The product version wants the sidebar hamburger too;
   budget for a title-only header with actions in a bottom bar.

## What hias judges on the phone

- Does swipe-in-overview feel like GNOME, or like a mode you forget
  you are in? (If the latter: auto-exit overview on page settle.)
- Tap targets in the key row at the device's DPR; is Ctrl discoverable?
- Column count / legibility on the real Guacamole negotiation (finding 2).
- Whether the "no peeking neighbours" limitation is felt (finding 3).

## Path into cmux (only after the verdict)

1. `BreakpointBin` around the main window; below ~600 px: sidebar and dock
   `OverlaySplitView` collapsed (already the primitive in `CmuxApp.swift`),
   hamburger in the header.
2. `TerminalStackWidget`: below the breakpoint render a tab's leaves into
   an `AdwCarousel` instead of the `GtkPaned` chain (reparent, never
   recreate — terminals stay alive like today's tab switches). Overview
   mode state lives in the model so the socket can drive it.
3. Extra-keys row as a product surface (localized, in `cmux.json`).
4. Flatpak on the adminvm Debian 13 image (GNOME 48 host, runtime 49
   from Flathub) — that is the deployment the Guacamole path needs.
