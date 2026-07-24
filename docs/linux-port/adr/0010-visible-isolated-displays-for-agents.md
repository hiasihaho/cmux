# 0010 — Visible isolated displays for agents (Xvfb → a cmux pane)

- **Status:** Proposed (open — decision deferred)
- **Date:** 2026-07-24
- **Deciders:** hias + Claude (open for discussion)

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

**OPEN.** Current lean: **A as the immediate step** (a proactive
screenshot stream — cheap, and it already works), **B as the
live-visible aspiration** if the transparency payoff justifies a new pane
type. **C is probably overkill** for the value.

*2026-07-24 update:* B's stage-1 POC is **proven** with zero app changes —
x11vnc + noVNC rendered in an ordinary browser surface (see
`poc/0002-vnc-live-agent-display.md`). The remaining B question is only
whether the live view earns a *native* pane type (gtk-vnc2 is already on
the host), not whether it can work.

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

## Links

- `linux/scripts/scratch.sh` (the isolated-display wrapper), `lib.sh`
  Xvfb management, ADR-0009 (visibility), cmux's transparency ethos
  (MENTAL-MODEL, CONCEPTS).
- `poc/0002-vnc-live-agent-display.md` — stage-1 POC of option B
  (proven 2026-07-24: live scratch display in a browser pane).
