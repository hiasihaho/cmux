# 0010 — Visible isolated displays for agents (Xvfb → a cmux pane)

- **Status:** Accepted
- **Date:** 2026-07-24
- **Deciders:** hias + Claude

## Context

The port's e2e tests and the agents' scratch cmux instances run on
**headless Xvfb** framebuffers (displays `:90–:139` for suites, `:140–:159`
for scratch) — deliberately isolated, but **invisible to the human**.
That sits in tension with cmux's core ethos: *transparency about what
agents do*. The agent's *chat* is visible (a split), but its *test runs
and scratch UI* — where the real verification happens — are not.

Could an agent's isolated display connect **visibly** to a cmux pane, and
stay conflict-free across many agents?

## Options considered

- **A — screenshot-on-demand (already possible).** Agents can
  `scratch.sh shot`; formalize it so agents *proactively* post screenshots
  at key moments ("here's what I'm seeing"). Cheapest; visible-on-demand,
  not live.
- **B — x11vnc on the agent's Xvfb + a VNC-viewer cmux pane.** Live view
  of the agent's headless display in a pane. Each agent already owns a
  distinct display, so N agents scale naturally; the new parts are an
  x11vnc dependency and a VNC-client pane type.
- **C — nested compositor rendered into a pane.** The scratch cmux runs in
  a nested Wayland/X session whose output *is* a cmux pane. Most native,
  heaviest; likely overkill.

## Decision

**A + B, both** (2026-07-24). They are complements, not alternatives:
A (screenshots) stays the agent's proactive "here's what I see" channel,
and B's live pane doubles as a **pointing channel** — because VNC is
interactive, the human can click the element they mean *inside the
agent's display*, and the agent reads it back (`scratch.sh point`:
pointer coordinates + a crosshair-marked screenshot). That deixis — "this
one, here", which neither a screenshot stream nor prose can express — was
the deciding argument (hias).

Implemented as `scratch.sh watch` / `watch-status` / `point` / `unwatch`
over x11vnc + noVNC in an ordinary browser surface — B's stage-1 POC
(`poc/0002-vnc-live-agent-display.md`, now adopted as
`features/12-live-agent-display.md`) proved this needs zero app changes.
**C stays rejected as overkill.** A **native gtk-vnc2 pane type** remains
open as a possible stage 2, only if the browser-pane client shows its
limits.

## Consequences

- A is essentially free and buys most of the transparency benefit for
  discrete moments; it does not show live interaction.
- B is a real feature (dependency + pane type) but conflict-free scaling
  is already solved (per-agent displays); it would make the whole "agent
  verifies in an isolated cmux" story *watchable*, strongly serving the
  ethos.
- Live visibility changes the trust model: the human can *watch* an agent
  drive a real cmux, not just read that it did — the same jump
  claude-teams made from tmux-panes to native splits.
- Interacts with 0009: a visible display + a name↔pane mapping = "watch
  the agent named X work in its own cmux."
- The pointing channel inverts the direction of transparency: not only
  can the human watch the agent — the human can *gesture into the
  agent's world* and be understood (click → `point` → coordinates).
- `watch-status` verifies the whole pipeline (processes, noVNC serving,
  pane actually connected) and is the meta-feature's `check:` guard.

## Links

- `linux/scripts/scratch.sh` (the isolated-display wrapper), `lib.sh`
  Xvfb management, ADR-0009 (visibility), cmux's transparency ethos
  (MENTAL-MODEL, CONCEPTS).
- `poc/0002-vnc-live-agent-display.md` — stage-1 POC of option B
  (proven 2026-07-24: live scratch display in a browser pane).
