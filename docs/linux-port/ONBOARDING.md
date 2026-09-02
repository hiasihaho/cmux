# Onboarding — you are joining the cmux desk team

Ten minutes. Read it once, then start; the rest is linked, not repeated.
If something here contradicts a dated entry in
[PROGRESS.md](PROGRESS.md), the dated entry wins.

## 1. Where you are

You are almost certainly running **inside the app you are changing** — a
VTE or Ghostty pane of a live `cmux-adw`. `$CMUX_SURFACE_ID` confirms it.
Read [INSIDE-CMUX.md](INSIDE-CMUX.md) before your first risky command; it
is the host-survival briefing (don't kill your host, the isolated dev
instance, the scratch harness, promotion as a user-approved checkpoint).

The one rule that has bitten three times: **never `pkill -f <pattern>`** —
it matches your own shell's command line.

## 2. What this project is

A GTK4/libadwaita port of macOS cmux, Swift throughout, developed in a
closed loop inside itself since 2026-07-16. [PORTING.md](PORTING.md) has
the plan, [PARITY.md](PARITY.md) the per-verb status against macOS,
[CATCHUP.md](CATCHUP.md) the living "what now".

## 3. Who else is here, and how we talk

Several agent sessions work in ONE checkout, inside one running app.

**The channel ladder** — git (banked truth) → feed threads (coordination
state) → pane (literal transcript + doorbell). Never conclude "stalled"
from one channel alone.

- **`cmux notify` is for the HUMAN, never for another session.** Nothing
  delivers a notification to an agent and nothing polls it. A desk that
  "informed" a sibling by notify informed hias only.
- **Session-to-session is a feed letter plus a doorbell**: `feed.push` a
  `UserPromptSubmit` into a stable workstream (`announce-<target>`), then
  `cmux send` a one-liner and `send-key Enter` as SEPARATE sends. Text
  rides in `tool_input` as a JSON OBJECT. Check the recipient is alive AND
  idle first — a nudge during an active turn becomes an unsubmitted draft.
  Protocol: `skills/cmux-feed/SKILL.md`.
- **One writer per file, enforced by `git worktree add`.** Not etiquette —
  a worktree. Two desks in one checkout is how a half-feature ends up
  uncommitted in the tree a promote builds from.
- **Ownership lives in the docs.** Every active track names its owning
  desk in its GAPS row; hand-overs go into the feature doc.
- **A correction is a contribution.** Record what a probe RULED OUT with
  its evidence, next to what it found. Three theories were disproven the
  night the daily wedged, two by the desks that proposed them.

## 4. What an agent pane actually contains

Not one session. Know this before you debug one.

`cmux omo`, `cmux omx`, `cmux claude-teams`, `cmux codex-teams` are **not
different agents** — they launch the underlying CLI (opencode, Oh My
Codex, Claude Code, Codex) inside a cmux-aware environment: a tmux-like
env plus a private tmux shim on PATH, so the tool's multi-pane
orchestration becomes real cmux splits with sidebar metadata and
notifications. The session store belongs to the underlying tool, which is
why `cmux omo --continue` resumes an *opencode* session.

Under `omo` (oh-my-openagent) a pane is an orchestrator plus members:

| agent | role |
|---|---|
| **Sisyphus** (Ultraworker) | orchestrator — plans, delegates, drives to completion in parallel |
| **Prometheus** (Plan Builder) | planner — interview mode, builds a verified plan before code |
| **Atlas** (Plan Executor) | executes the plan |
| hephaestus · oracle · librarian · explore · metis · momus | specialists Sisyphus delegates to |

Delegation picks a **category**, not a model; the category maps to a
model. Team mode (this host: 8 members max, 3 parallel, 500 turns each,
120 min wall clock) means one pane can hold nine sessions with nine
contexts. When a pane "hangs", find out WHICH session first.

**Provider caveat learned the hard way** (2026-09-02, full write-up in
`opencode-sophia-empty-turns-20260903.md` at the repo root): a provider
that returns no `usage` object leaves opencode's context meter at zero
forever — no percentage, no auto-compaction, no warning before the wall.
Team mode multiplies that across members. External meter:
`opencode-session-size` (in `~/.local/bin`); treat ~1 MB of stored parts
(~250K tokens) as "compact now".

## 5. How work lands here

1. **Implement**, then verify on a scratch or dev instance — never the
   human's daily.
2. **Test, red first where feasible.** Two commits: the failing test,
   then the fix. Prove it both ways and say the numbers in the commit
   message. Suites live in `linux/tests/`; the assertion-count ledger is
   `linux/tests/suites.tsv` and moves in the SAME commit.
3. **Docs in the same commit**: [PROGRESS.md](PROGRESS.md) (what +
   evidence + traps), [PARITY.md](PARITY.md) (per-verb status),
   [GAPS.md](GAPS.md) (a row from discovery to fix — adding one is as
   valuable as closing one), [CATCHUP.md](CATCHUP.md) at session end.
4. **One increment per commit.** Never fold an unrelated fix into a
   change the human will test — a failure must stay attributable.
5. **End of day**: a `CONCLUSION-<YYYYMMDD-HHMM>-<desk>.md` — what you
   did, time with machine evidence, what you hand to tomorrow with
   owners, one lesson.

## 6. First day

- [ ] Read INSIDE-CMUX.md end to end.
- [ ] `cmux identify` — know your own workspace and surface.
- [ ] Skim CATCHUP.md, then the GAPS "Now" table. Pick nothing yet.
- [ ] Read the last two PROGRESS entries: that is the house voice.
- [ ] Introduce yourself in a letter to `announce-cmux-desk` — who you
      are, what you intend to own, what you need. Ring the doorbell.
- [ ] Take a worktree before your first code change.

## 7. Where the durable knowledge is

| file | what it holds |
|---|---|
| [CATCHUP.md](CATCHUP.md) | living "start here" briefing |
| [PROGRESS.md](PROGRESS.md) | every phase, every trap, with evidence |
| [GAPS.md](GAPS.md) | the prioritized backlog, with owners |
| [PARITY.md](PARITY.md) | per-verb status vs macOS |
| [PORTING.md](PORTING.md) | subsystem disposition and phases |
| `features/NN-*.md` | one file per feature investigation |
| `INCIDENT-*.md` | post-mortems |
| `skills/` | task-specific contributor rules (`/cmux*`) |
| `~/olmo/WORKFLOW.md` | the cross-team cooperation contract (attribution, threads, rings) |

Everything here was paid for by something going wrong once. If you find a
rule that no longer matches reality, correct it in the same commit as the
work that proved it — that is the job, not a distraction from it.
