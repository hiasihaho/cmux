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
  line; this has bitten three times now — latest 2026-07-24, killing a
  compound cleanup command mid-run (exit 144). If a kill is ever externally
  justified, use `pkill -x`, and expect to not survive it. Kill helper
  processes strictly by recorded pid after a `/proc/<pid>/cmdline` check,
  the way `scratch.sh unwatch` does.)
- `swift build` is always safe: it replaces the binary **on disk**; the
  running app is unaffected.
- **Binary promotion protocol**: new binaries are verified on an isolated
  dev instance (below). Promoting to the daily instance requires a restart —
  that is a *user-approved checkpoint*: announce it, never force it. The
  wrapped flow is `linux/scripts/promote.sh` (run it from a dev pane or a
  plain terminal — it refuses to run from inside the instance it kills):
  forces a `session.save` (final-save semantics), stops the daily, starts
  it on the new binary; session restore brings the layout and scrollback
  back, `claude --continue` resumes the session. `--slot dev2` exercises
  the same code path against a disposable instance.
- **A WEDGED daily is recoverable with SIGTERM alone** (2026-09-02): the
  app installs no SIGTERM handler and neither does GLib — the only exit
  hook is `SessionExitSave` on GTK `close-request` — so SIGTERM takes the
  kernel-default disposition and terminates even a spinning process. No
  `kill -9`. The cost is skipping the close-request exit-save, which is
  why `promote.sh` forces `session.save` over the socket FIRST; that save
  may itself time out on the wedged loop, which promote tolerates. Do
  NOT combine a recovery restart with any other change — see PROGRESS
  2026-09-01/02 for what that discipline cost and bought.
- **Never rebuild the Ghostty shim over `ghostty/zig-out/lib/`** while an
  instance maps it — that SIGBUSes the daily. Build to a side prefix and
  install with `linux/scripts/swap-shim.sh` (rename-not-overwrite,
  verification, `--rollback`); `--dry-run` is safe from anywhere.

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

For HEADLESS probes and screenshots, never hand-roll Xvfb — use the
scratch wrapper (own display range :140-:159; the suites own :90-:139
via lib.sh, and a hand-rolled `:93` once false-redded a running gate):

```sh
linux/scripts/scratch.sh start <tag>          # free display, isolated ids
eval "$(linux/scripts/scratch.sh env <tag>)"  # point the CLI at it
linux/scripts/scratch.sh shot <tag> out.png   # screenshot
linux/scripts/scratch.sh watch <tag>          # ADR-0010: live view in a pane of the caller's cmux
linux/scripts/scratch.sh point <tag> out.png  # human clicked in the watch pane? coords + marked shot
linux/scripts/scratch.sh stop <tag>           # kills by env match only (implies unwatch)
```

(`start.sh daily` starts the human's instance after a crash/close; it
refuses to start a second one while the daily socket responds.) The raw
env-var pattern behind it, if you ever need it manually:

```sh
# SESSION goes in the state dir, NEVER /tmp: the scrollback store lives
# in dirname(session)/scrollback and is pruned on every save, so a
# /tmp-session instance deletes every test suite's capture files
# (2026-07-22: a leaked one caused a day of moving gate flakes).
CMUX_APP_ID=com.manaflow.cmux.dev \
CMUX_SOCKET_PATH=/tmp/cmux-dev.sock \
CMUX_SESSION_PATH=~/.local/state/cmux/dev-session.json \
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

## Working with the other desks (you are not alone in this repo)

Several agent sessions develop this port at once, in ONE checkout, inside
the same running app. The rules below are what that cost to learn.

- **`cmux notify` is for the HUMAN, never for another session.** It
  appends to the notification store, badges a workspace tab and raises a
  desktop notification — nothing delivers it to an agent and nothing
  polls it. A desk that "informed" a sibling by notify has informed
  hias only (2026-09-02). Cross-platform trap on top: with an explicit
  `--workspace` and no `--surface`, the shared CLI also sends the
  CALLER's surface id, and macOS's resolver (issue #7939) then lets the
  surface outrank the workspace — the same command notifies the sender
  there. Name the target surface, or use a letter.
- **Session-to-session is a feed letter plus a pane doorbell**:
  `feed.push` a `UserPromptSubmit` into a stable workstream
  (`announce-<target>`), then `cmux send` a one-liner and `send-key
  Enter` as SEPARATE sends. Text rides in `tool_input` as a JSON OBJECT.
  Check the recipient is alive AND idle first (`read-screen` twice — a
  nudge during an active turn becomes an unsubmitted draft). Full
  protocol: `skills/cmux-feed/SKILL.md`.
- **One writer per file, enforced by `git worktree add`, not etiquette.**
  Two desks in one checkout is how a half-feature ends up uncommitted in
  the tree a promote builds from (2026-09-01). A session doing
  exploratory or parallel work takes a sibling worktree; the shared
  checkout has one implementer at a time.
- **Ownership belongs in the docs, not in a conversation.** Every active
  track names its owning desk in its GAPS row, and hand-overs are
  written into the feature doc — a letter dies with whoever read it.
- **Review across desks, red-first.** A desk reading another's RED commit
  before the green exists is the cheapest review there is: on
  2026-09-02 that read caught an unpadded-base64 fixture whose strict
  Foundation decode silently disabled a migration, which the implementer
  had been chasing as a suite-timing bug.
- **A correction is a contribution.** Three theories were disproven the
  night the daily wedged, two of them by the desks that proposed them.
  Record what a probe RULED OUT with its evidence, in the same place as
  what it found.

## Closed-loop QA (standing user consent exists)

`linux/scripts/dogfood.sh "focus instructions" [timeout-min, default 20]`
spawns a headless Claude QA agent in a background workspace of the *daily*
instance, restricted to Bash/Read/Grep/Glob, guardrailed against touching
the human's panes. Report lands in `~/.local/share/cmux/dogfood/` and the
script blocks until then — run it as a background task and the report wakes
you. Triage pattern: root-cause before trusting findings (cycle 2's
"identify" bug manufactured two phantom bugs); fix; re-run a focused cycle.

## Project state and pointers (read before big moves)

- **Catch-up first**: `docs/linux-port/CATCHUP.md` — the living
  "what now" briefing (open questions, current bug hunt, next
  milestones). Update it at the end of every significant session.
- **Plan**: `docs/linux-port/PORTING.md` — subsystem disposition, phases.
- **Evidence log + gotchas**: `docs/linux-port/PROGRESS.md` — every phase,
  every dogfood cycle, every trap (GTK reparenting, Data/pkill/GtkListBox
  races). Append to it in the same commit as the change it documents.
- **Workflow**: `linux/README.md` "Development workflow" — branch
  `linux-port` (fork hiasihaho/cmux; `upstream` = manaflow-ai), one commit
  per feature *with docs*, conversation exports are gitignored, changes to
  shared sources (`CLI/cmux.swift`) must keep building on macOS
  (`#if canImport(Darwin)` / `#if os(Linux)`).
- **Gap backlog**: `docs/linux-port/GAPS.md` — the prioritized work-down
  list with per-gap effort and source; update it in the same commit as
  any gap fixed or found.
- **Parity tracker**: `docs/linux-port/PARITY.md` — per-verb/per-feature
  status vs macOS. Update it in the same commit as any feature change.
- **Done**: phases 0–5c (shell, control plane, VTE terminals, attention
  pipeline incl. notifications page + desktop delivery, splits + session
  persistence, browser panes, the full browser automation surface —
  eval/snapshot/actions/screenshot/find/frame/dialog/cookies/storage/
  console — plus workspace rename/next/previous/last and notification v2
  aliases) plus five dogfood cycles; **Ghostty shim increments 1–2**
  (embedded Ghostty surfaces run inside cmux-adw behind `CMUX_GHOSTTY=1`
  build + `CMUX_TERM=ghostty` runtime — GHOSTTY-SHIM.md; shim on ghostty
  branch `linux-gtk-embed`, fork hiasihaho/ghostty).
- **Next milestones**: Ghostty shim increment 3 (send/read verbs for
  ghostty panes so agents can drive them, eager background-workspace
  spawn, shell-integration resources dir, then a ghostty-mode dogfood
  cycle and the default flip), Flatpak packaging.
- **Environment**: Fedora 43 host (GNOME 49 → adwaita-swift pinned;
  `CMUX_GNOME=50` or `linux/scripts/build-gnome50.sh` for the Fedora 44
  container build). System Swift 6.2. Build from `linux/`, never the
  repo root. A macOS 15 VM (`ssh hias@ultmos`, CLT-only, no GPU)
  compile-checks shared sources: `cd macos-verify && swift build`.

The macOS instructions below (xcodebuild, reload.sh, GhosttyKit) apply to
the original app, not to Linux-port work.
