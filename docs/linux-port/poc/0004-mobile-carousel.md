---
title: Mobile pane carousel (phone-sized RDP viewport)
area: shell
kind: spike
status: wip   # v2 = workflow shell, awaiting phone verdict
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
| **variant B: `MOBILE_VARIANT=tabview`** | same panes in an `AdwTabView` wrapped by `AdwTabOverview`: GNOME's own thumbnail grid (live thumbnails, titles from the VTE title, per-pane close, its own "new tab" button wired to `create-tab`). Overview toggle = `adw_tab_overview_set_open`; `notify::open` mirrors a thumbnail tap or Escape back into state; `notify::selected-page` drives the header. No swipe between pages in focus mode — `‹ ›` and the overview navigate. The carousel variant is untouched: both live in one binary, one env var apart |
| header | `WindowTitle`: VTE title + `n / count`, or `swipe · tap to pick` in overview |
| **extra keys** | Termux-style row: Esc, Tab, **sticky Ctrl**, arrows, `/ \| - ~ : ' "`, `⇔80` (re-fit), `A− A+`, `‹ ›` (prev/next). Buttons are `focus-on-click=false` so the terminal keeps focus. Sticky Ctrl is a capture-phase key controller on each terminal: next printable key → control byte, toggle disarms. Verified: `sleep 30`, Ctrl, `c` → `^C` |
| key row scrolling | `GtkScrolledWindow` pans only for touch sequences, and over RDP a finger is a mouse — so a capture-phase `GtkGestureDrag` pans the row by hand and claims the sequence past 8 px, which keeps the button underneath from clicking. Verified headless with a mouse drag (hias had noticed the row did not scroll) |
| column fit | `MOBILE_FIT_COLS` (default 80): after first map, estimate the font scale, then step down every third 120 ms tick until the measured column count reaches the target (VTE cells are whole pixels and the pty resize lags the font change) |
| env | `MOBILE_VARIANT` (carousel\|tabview), `MOBILE_W`/`MOBILE_H` (default 392×844), `MOBILE_PANES` (3), `MOBILE_FONT_SCALE` (0.8), `MOBILE_FIT_COLS`, `MOBILE_APP_ID`, `MOBILE_DEBUG_SIZES` (logs the box children's measured heights) |

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
# variant B (thumbnail overview) on the same geometry
CMUX_SCRATCH_APP=linux/poc/mobile-carousel/.build/debug/MobileCarousel \
CMUX_SCRATCH_GEOMETRY=1080x2340 linux/scripts/scratch.sh start mobile3 \
    GDK_SCALE=2 MOBILE_W=540 MOBILE_H=1170 MOBILE_VARIANT=tabview
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
5. **Variant B works out of the box** (2026-11-04, second pass): three
   live thumbnails in a row at 540 logical px, titles, close buttons,
   GNOME's "Neuer Reiter"; tapping a thumbnail selects the pane, closes
   the overview and the header reads `1 / 3` with focus in the terminal.
   The key row stays visible under the overview (it sits outside the
   `AdwTabOverview` child). Cost: no swipe in focus mode. This is the
   trade to feel on the phone: carousel = swipe but no thumbnails,
   tabview = thumbnails but no swipe.
6. **The header is tight at 392 px**: title + 4 buttons already truncate
   the VTE title. The product version wants the sidebar hamburger too;
   budget for a title-only header with actions in a bottom bar.

## Spike v2 — the web-app workflow shell (2026-11-04, same day)

hias's target (ruling after the v1 review): mobile cmux first serves the
web-app dev environment. One cmux workspace per git worktree, created by
the feature workflow; in each workspace a shell pane and a preview pane
the Claude session drives. On the phone the sidebar is replaced by the
workspace overview, and the panes are swiped. v1's "carousel or tabview"
trade dissolves into two levels:

| level | widget | navigation |
|---|---|---|
| workspaces (worktrees) | `AdwTabView` + `AdwTabOverview` | header grid button → thumbnail grid, tap picks; overview "+" = new workspace |
| panes in a workspace | `AdwCarousel` of Shell + Vorschau (WebKit) | bottom `AdwToggleGroup` (always works), **edge-strip swipe** (22 px strips on both sides, a drag past 40 px flips the pane; the middle stays the terminal's / page's own drag), key row only on Shell |

Second binary in the same package: `MobileWorkflow`
(`Sources/MobileWorkflow`), v1 untouched. Carousel is never interactive
itself — the edge strips carry the gesture, which sidesteps the
one-pointer conflict for both VTE and WebKit without a mode switch.

**The handshake the spike pretends** (what `feature-start` will do over
the socket in step 2): `MOBILE_WORKSPACE_NAMES=theme-dark,login-form`
(one workspace per name), `MOBILE_WORKTREE_ROOT` (shell cwd =
`<root>/<name>` when it exists), `MOBILE_PREVIEW_URL` (dev server;
unset → a placeholder page showing the workspace, viewport, DPR and
"touch: nein (RDP = Maus)"). Shells get `MOBILE_WORKSPACE=<name>`.

```sh
cd ~/cmux-mobile/linux/poc/mobile-carousel && swift build --product MobileWorkflow
cd ~/cmux-mobile
CMUX_SCRATCH_APP=linux/poc/mobile-carousel/.build/debug/MobileWorkflow \
CMUX_SCRATCH_GEOMETRY=1080x2340 linux/scripts/scratch.sh start wf \
    GDK_SCALE=2 MOBILE_W=540 MOBILE_H=1170 MOBILE_WORKSPACE_NAMES=theme-dark,login-form
linux/scripts/scratch.sh watch wf
```

Verified headless (xdotool + screenshots): toggle Shell→Vorschau renders
the placeholder at 530×1072 CSS px, DPR 2; the workspace overview shows
both worktrees as live thumbnails, each of its *current* pane (shell for
one, preview for the other) — that is the "what is this feature doing"
glance for free; tapping a thumbnail returns to it; left-strip swipe
goes back to Shell, right-strip swipe forward to Vorschau, the toggle
follows; `tput cols` = 88 in each workspace's shell.

Known gaps of v2: no live finger-tracking on the edge swipe (it flips
on release, animated); the strips are faintly tinted so they are
discoverable — the product may want them invisible plus a first-run
hint; closing a workspace does not touch the worktree (by design,
`feature-end` owns that).

## What hias judges on the phone

- Does swipe-in-overview feel like GNOME, or like a mode you forget
  you are in? (If the latter: auto-exit overview on page settle.)
- Tap targets in the key row at the device's DPR; is Ctrl discoverable?
- Column count / legibility on the real Guacamole negotiation (finding 2).
- Whether the "no peeking neighbours" limitation is felt (finding 3).
- **v2:** is the toggle + edge-swipe pair enough, or must the whole
  pane follow the finger? Is the 22 px strip hittable on glass?
- Does the overview-of-current-pane thumbnail read as "what each feature
  is doing", or should the thumbnail always show the preview?

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
