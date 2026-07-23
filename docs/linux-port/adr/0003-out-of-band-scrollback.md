# 0003 — Scrollback stored out of band, replayed via inject_output

- **Status:** Accepted
- **Date:** 2026-07-21
- **Deciders:** hias + Claude

## Context

Terminal scrollback must survive a restart. macOS stores it inline in the
session document and replays it by having the shell `cat` a temp file to
the pty (so the tty's ONLCR discipline adds carriage returns for free).
The port rewrites its session JSON on every model change, so inline
scrollback made *every line of terminal output* rewrite the whole document
(observed: 327 KB per save in a real dev session).

## Options considered

- **A — inline, like macOS:** simplest to mirror, but the write
  amplification is unacceptable and caps how much history we can keep.
- **B — out of band, one file per surface, replayed through the terminal
  parser:** decouples scrollback size from session-doc churn; but bypassing
  the pty means we owe the CR normalization the tty would have done.

## Decision

**Option B.** Scrollback lives in `dirname(session)/scrollback/<id>.txt`,
one file per surface, so the limit is configurable up to unlimited
(`CMUX_SCROLLBACK_LIMIT=0`). Restore parks the text and replays it through
the fork's `inject_output` (Ghostty) / `vte_terminal_feed` (VTE) — parsed
as terminal *output*, never handed to the shell as input. `replayPayload`
normalizes LF→CRLF (the bill for bypassing the pty).

## Consequences

- **Buys:** session JSON stays tiny; "keep all history" becomes affordable;
  the same backend-agnostic replay path serves both terminals.
- **Costs:** we own two subtleties macOS gets free — replay must be gated
  on the pane being **mapped** (an unmapped pane's write silently
  succeeds and loses the text), and LF must become CRLF or the block
  staircases. Both are now regression-tested.
- **Deviation from macOS:** deliberate and more flexible (configurable,
  unlimited); the macOS budget exists only because its scrollback rides
  inline.

## Links

- Wiring: [wiring/06-persistence.md](../wiring/06-persistence.md); PROGRESS
  2026-07-21 (staircase + mapped-gate), PARITY.md scrollback row.
