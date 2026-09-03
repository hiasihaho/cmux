# Feature 17 — Pi as a harness substrate: a bounded evaluation

**Status:** evaluation, 2026-09-03. Not a migration, not a recommendation
to switch daily drivers. Three criteria were fixed BEFORE any measuring,
so the answer could be "no".

## Why this was run

Every failure of the 2026-09-02 evening was a **harness policy** failure,
not a model failure:

- a provider HTTP 429 became an invisible infinite loop (opencode records
  a rate-limited stream as a contentless step and retries forever);
- a missing `usage` object silently disabled the context meter and
  auto-compaction, with no warning before the wall;
- profile-scoped session stores broke resume
  (`INCIDENT-20260901-main-loop-livelock.md`, PROGRESS 2026-09-01/02,
  `opencode-sophia-empty-turns-20260903.md`).

In each case we could only observe and report: the policy lives inside
someone else's binary. That is the question this evaluation answers — not
"which agent is smartest", but **whose failure policy do we own?**

Second motivation: our team discipline is currently PROSE
([ONBOARDING.md](../ONBOARDING.md)). Every desk must read it and then
remember to write letters, take worktrees, do red-first, move the ledger.
A programmable harness could make parts of it executable.

## What Pi is (verified, not from marketing)

- npm `@earendil-works/pi-coding-agent` **0.84.4**, MIT,
  github.com/earendil-works/pi — 20 dependencies, 20.5 MB unpacked, bin
  `pi`. (`@mariozechner/pi` is a DIFFERENT package — a vLLM pod manager.
  The extension ecosystem uses the npm keyword `pi-package`; real
  community packages exist for subagents, package management, skill
  selection, UI tweaks.)
- **cmux already integrates it, and better than most**: the CLI has
  `installPiExtensionHooks` — a TypeScript *extension*, not shell-hook
  glue — and `AgentResume` knows `pi --session <id>`. Compare hermes
  (shell hooks with per-profile consent) and opencode (a bundled plugin).

## The three criteria, and what happened

Measured against a purpose-built fake OpenAI-compatible server
(`scratchpad/fake-openai.py`) with two modes — always-429 (no
`Retry-After`, the sophia shape) and 200-with-no-`usage` — so no load was
generated on the real provider and the failure modes were reproducible on
demand.

### 1. Does a 429 surface honestly instead of looping? **PASS**

    attempts: 4
    gaps between them: 2.0s, 4.0s, 8.0s
    then: `429: {"message":"Too Many Requests","type":"rate_limit"}`, exit 1

Exponential backoff, a bounded number of attempts, the provider's own
error text, and a non-zero exit. The same condition in opencode produced
2,785 contentless turns out of 3,314 and never terminated.

### 2. Does context accounting survive a silent provider? **FAIL, but harmless**

Pi sends `stream_options: {include_usage: true}` — exactly as opencode
does — and when the provider returns no usage, Pi reports
`usage: {input: 0, output: 0, totalTokens: 0}`. **It does not estimate.**
So the meter is equally blind.

The difference is what the blindness COSTS. In opencode it silently
disabled auto-compaction and the session walked into a wall it could not
see. In Pi the same blindness costs a display, because criterion 1 means
a failing request ends the turn instead of looping. Blind but not
weaponised.

### 3. Can a small extension make our discipline executable? **PASS**

[`linux/pi/cmux-letter.ts`](../../../linux/pi/cmux-letter.ts), 59 lines, registers a `cmux_letter` tool
that posts a durable feed letter and optionally rings a pane — with all
three doorbell traps encoded rather than taught: `tool_input` as an
OBJECT (a pre-encoded string double-encodes), an idle check before
ringing (a nudge into an active turn becomes an unsubmitted draft), and
text/Enter as SEPARATE sends (a trailing newline lands inside the input
box).

Proven end to end 2026-09-03 01:46 with a REAL model (Step35 via
myregio): pi loaded the extension, offered the tool, the model called it,
the tool executed, and the letter is in the feed —

    2026-09-03T01:46:26Z | source cmux | Pi evaluation, criterion 3: this
    letter was posted by a Pi extension tool called by a real model.

So the answer is yes: three traps that every desk currently has to be
TAUGHT (and that have each cost a debugging round) became 59 lines that
cannot be got wrong.

## Findings that were not in the criteria

- **Startup network operations can block.** Without `--offline` (or
  `PI_OFFLINE=1`) two runs hung with no output and no request ever
  reaching the endpoint; with `--offline` the same command answered
  immediately. Worth knowing before diagnosing a "hang".
- **Sane model defaults**: `contextWindow` defaults to 128000 and
  `maxTokens` to 16384 per model in `~/.pi/agent/models.json`. The
  opencode failure needed a hand-written `1048576/1048576` pair to
  happen; Pi's defaults are not a trap.
- **Custom providers are a documented JSON file**, not an interactive
  picker: `~/.pi/agent/models.json` with `baseUrl`/`api`/`apiKey`/`models`.
  That makes a profile reproducible and reviewable, which the hermes
  round showed matters.

## The one serious operational finding

**A provider that ACCEPTS connections and never answers hangs pi
indefinitely. A provider that is simply down does not.** Both were
measured, because the first version of this section blamed the wrong one.

| configured providers | `pi -p "hi"` |
|---|---|
| 0, 1, 2 dead (connection refused) | ~4 s |
| 3 dead | 10 s |
| ONE silent server (accepts, never responds) | **hangs — 90 s window exhausted** |

So "unreachable" is cheap; **silent** is fatal. The 400-second hang that
produced the original claim came from my own probe server: a
single-threaded `HTTPServer` wedged on a half-read connection, which
accepts and never answers — the exact fatal shape. I had blamed the
provider list.

**`retry.provider.timeoutMs` does not fix it**, though the settings file
IS read: setting `retry.maxRetries: 1` changed the observed attempt count
from 4 to 2, so the mechanism works — `timeoutMs` just does not bound a
silent request on the custom `openai-completions` path. That makes this
an upstream gap rather than a misconfiguration, and
`linux/tests/helpers/` now ships a six-line reproducer for it.

This cost four wrong diagnoses before the measurements: typebox,
`node:child_process`, TypeScript-vs-JavaScript, and then the provider
list — because loading an extension, adding a provider and wedging a
probe server all look identical from outside ("pi hangs").

Practical rules that follow:
- a provider that is DOWN is harmless; delete entries anyway, but not out
  of fear;
- never leave a half-open endpoint configured — that is the one that
  costs the session;
- if pi seems to hang, check whether something ACCEPTS but does not
  answer, before suspecting an extension;
- `retry.maxRetries` / `retry.baseDelayMs` in `~/.pi/agent/settings.json`
  are honoured and are the knobs for the 429 backoff (default 3 / 2000ms
  → the 2s/4s/8s ladder measured above).

## The harness, and why it lives in the repo

[`linux/tests/helpers/fake-openai-endpoint.py`](../../../linux/tests/helpers/fake-openai-endpoint.py)
— a provider that misbehaves on purpose, in three modes:

    fake-openai-endpoint.py ratelimit   # always 429, no Retry-After
    fake-openai-endpoint.py nousage     # streams fine, omits `usage`
    fake-openai-endpoint.py toolcall    # calls a named tool once, then stops

It exists because the two failure modes that cost the 2026-09-02 evening
could not be studied on the real provider: reproducing the 429 meant
ADDING to the load that caused it, and "provider never returns usage"
cannot be triggered on demand at all. Here both are a second's work and
cost no tokens. It also records what the CLIENT sent — which tools it
offered, whether it asked for usage, what it capped output at — which is
how the `stream_options: {include_usage: true}` comparison above was
made.

Re-verified after committing: pi against `ratelimit` gives **4 attempts,
gaps 2.0s / 4.0s / 8.0s, then the provider's error text and exit 1**.

TRAP inside the harness, paid for once: use `ThreadingHTTPServer`. The
single-threaded one wedges on a half-read connection and then ACCEPTS
but never answers — indistinguishable from the client hanging, and it
sent me chasing the extension for three rounds.

## Hooks and auto-resume in a real pane (2026-09-03, dev instance)

`cmux hooks pi install` writes a 572-line TypeScript extension to
`~/.pi/agent/extensions/cmux-session.ts` hooking six lifecycle events
(`session_start`, `before_agent_start`, `agent_end`,
`tool_execution_start/end`, `session_shutdown`) — a real integration, not
shell-hook glue.

**It warns on startup, and the warning is ours:**

    {"source":"cmux-pi-extension","level":"warning",
     "message":"failed to set Pi resume binding","status":1}

The extension calls `cmux --json surface resume set …`, and this port
answers `unknown_method` for **`surface.resume.set` / `.get` / `.clear`**
— macOS's newer per-surface resume binding, not implemented here (GAPS
row added).

**Auto-resume works anyway**, through the older path: the extension also
writes `~/.cmuxterm/pi-hook-sessions.json`, and `AgentResume`'s
record-only fallback (built for kimi's writer, which fills the record
before the index) resolves it. `debug.resume_plan` showed
`pi --session 01a06504-…` for the pane before any restart.

**End-to-end, on the isolated dev instance — never the daily:**

1. `pi` started in a pane, told to remember the word *pineapple*, replied.
2. `start.sh stop-dev` + `start.sh dev` — a genuine restore cycle.
3. The restored pane ran `pi --session 01a06504-…` by itself, and the
   conversation came back.
4. Asked what word it was told to remember: **"pineapple."**

**One caveat found by getting it wrong first.** The initial attempt
failed with `No session found matching '01a06504-…'` because that session
had ZERO turns — Pi does not persist an empty session, so a pane where
the agent was started but never used resumes into an error message. Not a
cmux bug, but it is what an operator will see.

**And a correction to criterion 2 above:** Pi's context meter is not
broken. Against step35 (which does return `usage`) the pane showed
`↑19k ↓104 14.3%/66k` — live tokens against the configured window. The
zeros in criterion 2 were the provider's silence, not Pi's accounting.

## Working around a provider that cannot stream

`chat.s.regio-ai.eu` returns an EMPTY stream for every model while
answering non-streamed requests correctly (UPSTREAM.md §5d). Every agent
CLI streams, so the provider is unusable by all of them at once.

**What does not work:** there is no config-only fix in pi.
`samplingParams` IS merged verbatim into the request body — setting
`{"stream": false}` reaches the wire — but pi's openai-completions client
has no non-streaming path and fails with `openaiStream is not async
iterable`. No `compat` flag disables streaming either (the documented
ones are `supportsDeveloperRole`, `supportsReasoningEffort`,
`supportsFinishReason`, `supportsEagerToolInputStreaming`, …).

**What works:** [`linux/scripts/unstream-proxy.py`](../../../linux/scripts/unstream-proxy.py)
— a ~90-line shim that accepts a streamed request, calls the upstream
WITHOUT `stream`, and re-emits the answer as the SSE chunks the client
expects (role delta → content → tool calls → finish_reason → usage →
`[DONE]`). Errors pass through untouched, so a client that classifies a
429 still sees the 429.

    linux/scripts/unstream-proxy.py https://chat.s.regio-ai.eu/api/v1 8480
    # then point baseUrl at http://127.0.0.1:8480/v1

Measured through it: `pi -p "…"` answers in **7.45 s, exit 0**, and the
usage the upstream does return arrives where a streaming client expects
it — `{"input": 8851, "output": 46, "totalTokens": 8897}`, i.e. **the
context meter comes back too**.

It fixes the provider for EVERY harness at once (pi, opencode, hermes)
rather than one, needs no change to any of them, and is meant to be
deleted when the operator restores streaming.

## Harness comparison, on the axes this project actually pays for

| | opencode | hermes | Pi |
|---|---|---|---|
| 429 policy | invisible loop | classified + eager fallback | backoff, then honest error |
| usage-less provider | meter dead, compaction dead | meter present | meter dead, turn still ends |
| provider config | JSON, hand-written limits | interactive picker + YAML | JSON, sane defaults |
| cmux integration | bundled plugin | shell hooks + per-profile consent | TypeScript extension |
| our discipline as code | plugin possible | shell hooks | first-class extension API |

## Configuration reference (as set up on this host, 2026-09-03)

### Where things live

| path | holds |
|---|---|
| `~/.pi/agent/models.json` | custom providers + models (the file below) |
| `~/.pi/agent/auth.json` | credentials saved via `/login` (empty here — see key handling) |
| `~/.pi/agent/models-store.json` | fetched model catalogs |
| `~/.secrets/sophia-api-key` | the ONE copy of the sophia key, 0600 in a 0700 dir |

### The provider file

```json
{
 "providers": {
  "sophia": {
   "baseUrl": "https://chat.s.regio-ai.eu/api/v1",
   "api": "openai-completions",
   "apiKey": "!cat /home/hias/.secrets/sophia-api-key",
   "models": [{ "id": "kimi-k3", "contextWindow": 262144, "maxTokens": 16384 }]
  },
  "lemonade": {
   "baseUrl": "http://127.0.0.1:13305/api/v1",
   "api": "openai-completions",
   "apiKey": "local",
   "models": [{ "id": "Qwen3.6-35B-A3B-MTP-GGUF", "contextWindow": 131072, "maxTokens": 16384 }]
  }
 }
}
```

Verified with `pi auth check --provider sophia` → `ready`.

### Key handling, and why it is a command

`apiKey` accepts four value shapes (docs/models.md, "value resolution"):

| shape | meaning |
|---|---|
| `"!command"` | run it, use stdout — `!op read`, `!security find-generic-password`, `!cat <file>` |
| `"$ENV_VAR"` / `"${VAR}"` | environment interpolation; a missing variable leaves it unresolved |
| `"$$x"` / `"$!x"` | escapes for a literal `$` or `!` prefix |
| anything else | literal (so a plain `MY_API_KEY` is the string, not the variable) |

**`!cat` was chosen deliberately over the other three.** A literal would
put a fourth plaintext copy of the key on disk (it already exists in the
opencode config and the hermes profile `.env`). `$ENV_VAR` would require
exporting the secret in a shell profile, which publishes it to every
child process's `/proc/<pid>/environ` — strictly worse than one 0600
file. The command form keeps exactly one owner for the secret, readable
only by the user, and works for a password manager later
(`!op read 'op://vault/item/credential'`) with no config change.

### Model fields worth knowing

`id` (required), `name`, `api`, `reasoning`, `thinkingLevelMap`, `input`,
**`contextWindow`** (default 128000), **`maxTokens`** (default 16384),
`samplingParams`, `cost`, `compat`. The last one matters for OpenAI-compatible
servers: `compat.supportsDeveloperRole: false` sends the system prompt as
`system` instead of `developer`, and `compat.supportsReasoningEffort:
false` drops `reasoning_effort` — the usual fixes for vLLM/Ollama/SGLang.

Contrast with the failure this project already paid for: opencode required
those numbers to be supplied by hand, and a wrong pair
(`1048576/1048576`) silently disabled the context meter and compaction.
Pi ships defaults that are merely conservative.

### CLI options that matter here

| option | why |
|---|---|
| `--offline` / `PI_OFFLINE=1` | **skip startup network operations** — without it two runs hung with no output and no request ever reaching the endpoint |
| `--provider` / `--model` | select; `--model provider/id` also works |
| `-e <file>` | load an extension (repeatable); `-ne` disables discovery |
| `-p` | non-interactive; `--mode json` emits structured events including a `usage` block |
| `-t` / `-xt` / `-nt` | tool allow/deny lists — the lean-toolset lever, per invocation |
| `--session` / `--fork` / `--session-dir` | session selection; forking is first-class |
| `--thinking <level>` | off … max |

## Verdict

**Two passes and one honest fail: Pi earns the substrate role, not
automatically the daily-driver one.**

- Criterion 1 (429 honesty) is the one that matters most here, and Pi
  wins it outright against the harness that cost us an evening.
- Criterion 2 fails the same way opencode does — nobody estimates tokens
  when the provider stays silent — but in Pi that blindness costs a
  display rather than a session.
- Criterion 3 passes, and it is the reason to care: our discipline can
  stop being prose. A `cmux_letter` tool is 59 lines; a lifecycle guard
  that refuses edits outside a worktree, or a stop-hook that checks the
  suites ledger moved, are the same shape.

**What would have to be true to adopt it as a desk harness**, beyond
this evaluation: cmux's Pi hooks installed and a session actually
restored in a pane (`installPiExtensionHooks` exists; untested here), and
a decision about WHICH harness it replaces. This machine already hosts
five; a sixth is only net-positive if it retires one, and the honest
candidate is the one whose failure policy we cannot change.

**What NOT to conclude.** Nothing here says Pi is a better model, a
better editor, or a better daily driver — those were not measured, and
Pi's own documentation positions OpenCode as the more finished agent.
What was measured is whose failure policy we own.

**Next, if pursued:** run a real task through Pi in a cmux pane, install
its hooks, and check auto-resume — the same three checks the hermes round
used, so the two are comparable.
