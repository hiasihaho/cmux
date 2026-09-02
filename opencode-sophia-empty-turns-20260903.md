# opencode + sophia/kimi-k3: contentless turns, no usage, no meter

Written 2026-09-03 after the pk3 desk session (`ses_fa185ee38ffeK731NQW0rYb67H`,
"Project analysis") spun for two hours and could not be recovered. Companion
to `omo-session-not-really-working-strange-session-ses_fa19.md` — though see
"what this does NOT explain" below: those two cases are **not** the same.

## Measured, from `~/.local/share/opencode/opencode.db`

**1. The provider reports no token usage at all.** All 3,314 assistant
messages of that session carry `tokens: {input: 0, output: 0, cache: {…0}}`.
Per-provider sums of assistant input tokens:

| provider | assistant msgs | input tokens |
|---|---|---|
| anthropic (via opencode) | 1,274 | 18.9M |
| joyai | 87 | 1.8M |
| devstral | 102 | 1.27M |
| lmxomni | 501 | 0.94M |
| **sophia** | 3,314 | **absent** |

opencode *asks* for usage — `stream_options` / `include_usage: true` are in
the binary — so the gateway at `chat.s.regio-ai.eu` is dropping it. Its
`/models` endpoint also reports no context length. Consequence: opencode's
context meter never leaves zero, so **no percentage is displayed and
auto-compaction never triggers**, whatever `limit.context` says.

**2. The session produced contentless turns at a pathological rate.** A turn
with only `step-start`/`step-finish` parts — no text, no tool call, no
reasoning:

| session | provider | size | contentless turns |
|---|---|---|---|
| ses_fa185ee38ffe… (pk3 desk) | sophia | 2.9 MB | **2,785 of 3,314 (84%)** |
| ses_f9bef633fffe… | sophia | 2.2 MB | 60 of 589 (10%) |
| ses_fa19e2627ffe… | sophia | 2.7 MB | 3 of 249 (1.2%) |
| ses_477160b8fffe… (control) | anthropic | 15.0 MB | **1 of 551 (0.2%)** |

The control matters: contentless turns are not normal bookkeeping.

**3. The terminal state was a tight loop of them** — `process` → `stream` →
`loop` in the opencode log every ~0.8 s, each producing one empty step, until
`cancel` + `error=Aborted` (the human's escape).

**4. Config found wrong, one half fixed.** `sophia/kimi-k3` declared
`limit: {context: 1048576, output: 1048576}`. An output budget equal to the
whole window is certainly wrong — the binary does arithmetic on it
(`limit.output-1`, `limit.output/2-1`), and if it reaches the wire as
`max_tokens`, a 1M completion request is itself a candidate cause of empty
responses. Set to `16384` on 2026-09-03 (backup:
`opencode.json.bak-sophialimit-20260903-001652`). `context` deliberately left
at 1048576: with no usage reported, lowering it buys no trigger.

## ROOT CAUSE FOUND, 01:45 — HTTP 429, not context (amends the above)

A minimal, hand-made request to the endpoint returned **HTTP 429 Too Many
Requests**; a second, seconds later, returned 200. The endpoint
rate-limits intermittently, and opencode records a rate-limited stream as
a **contentless step** — `{"reason":"unknown", tokens all zero}` — and
retries immediately. That is the exact signature of every "empty turn"
counted below, and it is self-sustaining: the retries generate the load
that keeps the limit tripped.

Decisive evidence that context was NOT the driver: a BRAND-NEW session
(`ses_f9b7c6240ffe…`, 4K tokens, 0.0 MB) produced **64 contentless turns
out of 64** within a minute of starting. Nothing that small is near any
context window. The context-exhaustion reading below is therefore
WRONG as a cause, and is kept only because the size numbers remain true
and the no-usage finding stands on its own.

It also explains the spread: 84% contentless in the session that ran
alongside other sessions and a runaway fork, 1.2% in one that ran while
the endpoint was quiet.

Practical consequences:
- **Stop retry loops first.** They are the load. A runaway fork reached
  1,425 assistant turns despite `max_member_turns: 500` — that cap did
  not hold it.
- **Probe before starting an agent**: one hand-made `chat/completions`
  request. 429 means wait; 200 means go.
- Ask the provider for the quota (requests/min, tokens/min) and whether
  429s carry `Retry-After` — the ones observed carried no rate-limit
  headers at all, so a client cannot back off intelligently.
- opencode treating a 429 as an empty step rather than an error is worth
  reporting upstream: it turns a recoverable, well-defined HTTP status
  into an invisible infinite loop.

## What this does NOT explain

- Why `fa19` (2.7 MB, same provider) shows 1.2% and `fa18` (2.9 MB) shows
  84%. Size alone does not predict it; turn count might (3,314 vs 249), or
  time (17.5 h vs 25 min), or something server-side. Unproven.
- Whether the trigger is context overflow. Plausible — the stored parts imply
  ~750-860K tokens at 3.5-4 chars/token, and nothing ever compacted — but the
  provider reports nothing, so the request size it refused is unobservable.
  The earlier claim in chat that "two of two cases match" was **wrong** and is
  corrected here.

## Working practice until the provider is fixed

- Ask the provider for (a) the real context window of `kimi-k3` and (b) why
  `usage` is absent from streamed responses. Without (b) opencode is blind on
  this provider — permanently, by construction.
- Compact by hand. There is no meter in the TUI, so use the external one:
  `opencode-session-size` (in `~/.local/bin`) prints stored size and a token
  estimate per session. Calibration: the session that died was 2.9 MB
  ≈ 790K tokens. Treat ~1 MB (~250K) as "compact now".
- Prefer shorter sessions on this provider. 17.5 hours and 3,300 turns is the
  shape that walked into this.
- Recovery, if it happens again: the session data survives. `opencode -s
  <full-id> --fork` resumes a copy (mind the trailing character of the id —
  a truncated id reports "Session not found", which reads like data loss and
  is not). The **durable** record is the commits and docs the session
  produced, not its context.
