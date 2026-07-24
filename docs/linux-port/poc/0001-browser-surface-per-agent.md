---
title: Browser surface per agent
area: browser
kind: composition
status: proven
linux: proven
mac: untested
substrate: 08-browser-automation + claude-teams harness
adopted: none
evolves_to: >
  shared-surface handoff between agents; per-agent browser state save/load;
  a team-lead browser dashboard aggregating every agent's pane
---

# 0001 — Browser surface per agent

- **Status:** proven (cmux-adw, 2026-07-23)
- **Substrate:** `08-browser-automation` (the verbs) × `claude-teams` (the harness)
- **Adopted as a feature:** not yet — this is a *composition*, not a leaf verb

## Purpose

Prove that in a `cmux claude-teams` session, **each named teammate can spawn and
drive its own browser surface on its own** — no pre-opening or hand-holding from
the team lead. The interesting claim isn't "the browser verbs work" (that's
`08-browser-automation`, already measured mac-parity); it's that the verbs
*compose* with the agent-teams harness so N agents each run an independent
`open → verify → wait → extract` loop in parallel, and the lead can read any of
their surfaces afterwards.

## What we proved

Three teammates, three tasks, three independent surfaces, run concurrently:

| Agent | Surface | Task | Result |
|---|---|---|---|
| HaikuJester | `surface:16` | example.com | H1 "Example Domain" extracted |
| HaikuGoose  | `surface:18` | Wikipedia: Raccoon | first sentence + a fact off the page |
| HaikuSnack  | `surface:17` | Wikipedia: Toast | recovered from a disambiguation page on its own, reached the real article |

- Each agent got its **own** `surface:N` from `cmux browser open` inside its pane.
- One agent hit an unexpected **disambiguation page** and self-navigated to the
  correct article — the judgement that makes agent-driven browsing worth more
  than a fixed script.
- From the **lead** session afterwards, `cmux browser surface:16/17/18 get url`
  read all three — surfaces are addressed globally, not owned by the opener.

## Isolation model (measured)

Surfaces are **globally addressable** (any session can drive any `surface:N`)
but **state-isolated** (independent cookies / localStorage / history per
surface). Cross-surface state transfer is explicit: `state save` → `state load`.
So agents can't trample each other's sessions, but the lead can inspect
everything. (Ref: the `cmux-browser` skill, `references/session-management.md`.)

## Unique to cmux-adw, or also cmux-mac?

The **substrate is parity** — `08-browser-automation` is `mac: full / linux:
full`, verb-for-verb. This **composition** (a team of agents each driving a
surface) has only been demonstrated on **cmux-adw**; the same flow is untested
on macOS (`mac: untested`). It is *not believed* port-unique — it should compose
on macOS too — but it has not been run there, so nothing is claimed.

## Next steps / what it could evolve into

- **Shared-surface handoff** — one agent authenticates, `state save`s, another
  `state load`s and continues (auth reuse across agents).
- **Per-agent browser dashboard** — the lead aggregates every teammate's surface
  + url into one view.
- If any of these are wired as first-class verbs, author a `features/` page and
  flip this POC to `status: adopted` + `adopted: <slug>`. The page stays here as
  the origin record.
