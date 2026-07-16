# You are (probably) running inside the app you are developing

This briefing is for Claude Code sessions working on the **cmux Linux port**.
Since 2026-07-16, all Linux-port development happens **inside cmux-adw
itself** — the GTK4/libadwaita port this repo builds. Confirm your situation:
if `$CMUX_SURFACE_ID` is set, your terminal is a VTE pane of the running
port, the `cmux` CLI targets *your own pane* by default, and the process
hosting you is `linux/.build/debug/cmux-adw`.

## Prime directive: don't kill your host

- **Never** `pkill`/`kill`/restart `cmux-adw` while running inside it — you
  die with it. (Also: `pkill -f <pattern>` matches your own shell's command
  line; this has bitten twice. If a kill is ever externally justified, use
  `pkill -x`, and expect to not survive it.)
- `swift build` is always safe: it replaces the binary **on disk**; the
  running app is unaffected.
- **Binary promotion protocol**: new binaries are verified on an isolated
  dev instance (below). Promoting to the daily instance requires a restart —
  that is a *user-approved checkpoint*: announce it, let the human close and
  relaunch (session persistence restores the layout; `claude --continue` in
  the pane resumes you), never force it.

## The isolated dev instance

Anything that needs a fresh binary or risky runtime experiments runs here,
never on the instance hosting you. Use the launcher (it encodes the
etiquette: refuses double-daily, kills dev strictly by app id):

```sh
linux/scripts/start.sh dev [--ghostty]   # isolated instance, log in ~/.local/state/cmux/
linux/scripts/start.sh stop-dev          # kills ONLY the dev instance
linux/scripts/start.sh status            # who is running, which terminal backend
# talk to it: CMUX_SOCKET_PATH=/tmp/cmux-dev.sock cmux ping
```

(`start.sh daily` starts the human's instance after a crash/close; it
refuses to start a second one while the daily socket responds.) The raw
env-var pattern behind it, if you ever need it manually:

```sh
CMUX_APP_ID=com.manaflow.cmux.dev \
CMUX_SOCKET_PATH=/tmp/cmux-dev.sock \
CMUX_SESSION_PATH=/tmp/cmux-dev-session.json \
nohup linux/.build/debug/cmux-adw >/tmp/cmux-dev.log 2>&1 &
# kill ONLY it: match CMUX_APP_ID in /proc/<pid>/environ, never by name
for pid in $(pgrep -x cmux-adw); do
  tr '\0' '\n' < /proc/$pid/environ | grep -q cmux.dev && kill $pid
done
```

## Socket etiquette (the human shares this app with you)

- Bare `cmux` commands target your own pane (via `CMUX_WORKSPACE_ID`/
  `CMUX_SURFACE_ID`). Trust those env vars for your identity — `cmux
  identify` confirms.
- **Never** `select-workspace`/`focus-pane` onto the human's view. Scratch
  workspaces: `cmux new-workspace --cwd <path> --background`. Clean up your
  scratch panes/workspaces (`close-surface`, `close-workspace`).
- `cmux notify` aimed at a non-selected workspace raises a **desktop popup**
  on the human's GNOME — word titles accordingly.
- Global CLI flags (`--id-format`, `--json`, `--socket`) go **before** the
  subcommand.
- Your Stop/Notification hooks are installed: finishing a turn or asking for
  input lights up your tab and can pop a desktop notification. That is the
  product working — no action needed.

## Closed-loop QA (standing user consent exists)

`linux/scripts/dogfood.sh "focus instructions" [timeout-min, default 20]`
spawns a headless Claude QA agent in a background workspace of the *daily*
instance, restricted to Bash/Read/Grep/Glob, guardrailed against touching
the human's panes. Report lands in `~/.local/share/cmux/dogfood/` and the
script blocks until then — run it as a background task and the report wakes
you. Triage pattern: root-cause before trusting findings (cycle 2's
"identify" bug manufactured two phantom bugs); fix; re-run a focused cycle.

## Project state and pointers (read before big moves)

- **Plan**: `docs/linux-port/PORTING.md` — subsystem disposition, phases.
- **Evidence log + gotchas**: `docs/linux-port/PROGRESS.md` — every phase,
  every dogfood cycle, every trap (GTK reparenting, Data/pkill/GtkListBox
  races). Append to it in the same commit as the change it documents.
- **Workflow**: `linux/README.md` "Development workflow" — branch
  `linux-port` (fork hiasihaho/cmux; `upstream` = manaflow-ai), one commit
  per feature *with docs*, conversation exports are gitignored, changes to
  shared sources (`CLI/cmux.swift`) must keep building on macOS
  (`#if canImport(Darwin)` / `#if os(Linux)`).
- **Parity tracker**: `docs/linux-port/PARITY.md` — per-verb/per-feature
  status vs macOS. Update it in the same commit as any feature change.
- **Done**: phases 0–5c (shell, control plane, VTE terminals, attention
  pipeline incl. notifications page + desktop delivery, splits + session
  persistence, browser panes, the full browser automation surface —
  eval/snapshot/actions/screenshot/find/frame/dialog/cookies/storage/
  console — plus workspace rename/next/previous/last and notification v2
  aliases) plus five dogfood cycles.
- **Next milestones**: Ghostty fidelity via a Zig C-shim around the
  fork's GTK apprt (libghostty builds on Linux — zig 0.15.2 at
  `~/.local/zig/`; its C API is Apple-only today), Flatpak packaging.
- **Environment**: Fedora 43 host (GNOME 49 → adwaita-swift pinned;
  `CMUX_GNOME=50` or `linux/scripts/build-gnome50.sh` for the Fedora 44
  container build). System Swift 6.2. Build from `linux/`, never the repo
  root (the root Package.swift is a macOS stub).

The macOS instructions below (xcodebuild, reload.sh, GhosttyKit) apply to
the original app, not to Linux-port work.
