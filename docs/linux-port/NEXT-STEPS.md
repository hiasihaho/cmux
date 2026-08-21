# Next-step candidates — the decision queue

Written 2026-07-24 after POC-0003 increment 1 landed (the full macOS app
builds AND runs headless-driveable on the `ultmos` VM). This file is the
*shortlist to pick from*, with effort, payoff, and dependencies —
[GAPS.md](GAPS.md) stays the exhaustive backlog, this is the curated
"what should the next session do". Remove a row when it's done or when
it graduates into GAPS-only tracking.

## The browser-capture track (from the 2026-08-21 screenshot thread)

Design, measurements and the reasoning behind this ordering live in
[features/16-browser-capture-and-interaction.md](features/16-browser-capture-and-interaction.md).
Rows 1-3 are small and each removes a whole class of wrong answers;
row 4 is the actual capability.

| # | Candidate | Effort | Payoff | Depends on |
|---|---|---|---|---|
| 1 | **Capture pre-flight guard** — measure `scrollWidth x scrollHeight x dpr`, refuse over the renderer ceiling with `invalid_params` + the max, instead of the 20s timeout backstop | S | Turns a 120s silent hang into an instant, specific error — and the same comparison becomes the "native capture or tile?" branch tiling needs, so it is not throwaway | nothing |
| 2 | **CLI silent-fallback fix** — a screenshot request for a background-workspace surface returns a plausible PNG of a DIFFERENT visible pane instead of the server's `invalid_state` | S | Never answering a different question than the one asked; this trap produced a wrong measurement during the investigation itself | nothing |
| 3 | **CSS/DPR fields in the screenshot payload** (`width_css`, `height_css`, `dpr`) | S | Device-vs-CSS pixel confusion burned two sessions in one night | nothing |
| 4 | **Tiled full-page capture** — scroll + viewport captures + stitch | M | The only approach that works at any document length on any renderer; also fixes lazy-loaded images that a native single capture misses | 1 (its size check is the routing decision) |
| 5 | **`browser.viewport.set`** — unimplemented here though macOS has it and agents advise it | S | Deterministic capture sizes; gives tiling a clean tile-size normalizer | nothing |
| 6 | **Interaction recorder** (Part B of features/16) — DOM-level click/navigation/timing trace over the existing user-content-manager channel | M | The human<->AI collaboration case: "review the last 5 steps of this UX flow". Privacy posture is part of the design, not an afterthought | nothing technical; a product decision on opt-in UX |

## The macOS-VM track (from POC-0003)

| # | Candidate | Effort | Payoff | Depends on |
|---|---|---|---|---|
| 1 | **Live-socket capability sweep** — a `--socket` mode for `capabilities-sweep.py` that probes every v2 method against a running instance (served vs `unknown_method`) | S | The features board's `mac` column becomes *empirical*: every ★ uniqueness claim checked against a running macOS cmux instead of a source survey. The driveable VM instance is already waiting as a target | nothing — doable now |
| 2 | **Ghostty shim increment 4** — port the GTK embed layer to manaflow's expanded `embedded.zig` (their new verbs assume `.userdata` on surfaces and embedded-App pointer types; 20+ errors, all in one file family) | M | Unblocks pushing the fork catch-up merge (16,853 commits, done on trial branch `trial-merge-probe`) and moving the parent submodule pointer; gives the Linux port the 15 new embedded APIs (read_screen_tail_vt, render_grid_json_with_theme, pty_tee, …) | the trial branch from the 2026-07-24 session worktree |
| 3 | **Null renderer** (POC-0003 increment 2) — env-gated no-op renderer backend in the ghostty fork, macOS side | M | Real terminal *content* headless — for **agents**: `send`/`read-screen` against the VM instance; the full measurable parity reference. Panes stay visually blank: pixels are exactly what it nulls | ideally after 2 (one fork branch state to carry) |
| 5 | **Software renderer** (`renderer=software`) — CPU rasterization of the cell grid (CoreText → CoreGraphics layer) behind the same pluggable renderer API | L | Terminals **humans can see and use** in a GPU-less VM. Distinct from and beyond 3: null = agents, software = eyes. Real rendering work (glyph cache, cursor/selection, damage tracking) — several sessions | after 3 (shares the backend seam) |
| 4 | **Visual dogfood of the port build on the Mac** — `cmux-PORT.app` starter exists; look at sidebar, browser panes, settings, command palette with real eyes | S (human) | First visual comparison of our branch's macOS app vs what macOS users see; catches software-rendering artifacts and obvious UI regressions the socket can't | a human at the VM display |

## Housekeeping candidates (same track)

- **VM screen-lock freeze**: the display pipeline wedges when the lock
  screen/screensaver engages under software rendering (system stays
  healthy — ssh fine, no CPU burn; only the frame output stalls).
  Mitigation applied 2026-07-24: screensaver `idleTime 0`. If it
  recurs: a WindowServer bounce (`sudo pkill WindowServer`, logs the
  console session out) beats a full reboot. Consider `pmset -a
  displaysleep 0` and disabling the lock-on-sleep requirement if the
  VM is ever left unattended long.
- **`sync-to-vm` helper**: the rsync-to-ultmos flow (excludes, openrsync
  flag quirks, ghostty tree) is folklore in PROGRESS; a
  `macos-verify/sync.sh` would make it one command.
- **CATCHUP trim**: the 2026-07-24 sections in CATCHUP.md accumulated
  through four sessions in one day; fold into "Current state" at the
  next quiet moment.

## Recommended order

**1 → 4 → 2 → 3.** The sweep (1) is small and converts the VM from
trophy to instrument; visual dogfood (4) costs only human minutes now
that the starter exists; the shim port (2) unblocks the fork push that
everything ghostty-side queues behind; the null renderer (3) then lands
on a settled fork.

## Pointers

- [poc/0003-headless-macos-reference.md](poc/0003-headless-macos-reference.md) — the POC this queue serves
- PROGRESS.md 2026-07-24 entries — build recipe, auth recipe, measurements
- `macos-verify/` — compile checker, `build-app.sh`, starters
- [GAPS.md](GAPS.md) — rows for candidates 1 and 2
