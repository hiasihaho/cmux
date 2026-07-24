# Next-step candidates — the decision queue

Written 2026-07-24 after POC-0003 increment 1 landed (the full macOS app
builds AND runs headless-driveable on the `ultmos` VM). This file is the
*shortlist to pick from*, with effort, payoff, and dependencies —
[GAPS.md](GAPS.md) stays the exhaustive backlog, this is the curated
"what should the next session do". Remove a row when it's done or when
it graduates into GAPS-only tracking.

## The macOS-VM track (from POC-0003)

| # | Candidate | Effort | Payoff | Depends on |
|---|---|---|---|---|
| 1 | **Live-socket capability sweep** — a `--socket` mode for `capabilities-sweep.py` that probes every v2 method against a running instance (served vs `unknown_method`) | S | The features board's `mac` column becomes *empirical*: every ★ uniqueness claim checked against a running macOS cmux instead of a source survey. The driveable VM instance is already waiting as a target | nothing — doable now |
| 2 | **Ghostty shim increment 4** — port the GTK embed layer to manaflow's expanded `embedded.zig` (their new verbs assume `.userdata` on surfaces and embedded-App pointer types; 20+ errors, all in one file family) | M | Unblocks pushing the fork catch-up merge (16,853 commits, done on trial branch `trial-merge-probe`) and moving the parent submodule pointer; gives the Linux port the 15 new embedded APIs (read_screen_tail_vt, render_grid_json_with_theme, pty_tee, …) | the trial branch from the 2026-07-24 session worktree |
| 3 | **Null renderer** (POC-0003 increment 2) — env-gated no-op renderer backend in the ghostty fork, macOS side | M | Real terminal *content* headless: `send`/`read-screen` against the VM instance; the full parity reference. UI already renders (software); only terminal panes are blank without this | ideally after 2 (one fork branch state to carry) |
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
