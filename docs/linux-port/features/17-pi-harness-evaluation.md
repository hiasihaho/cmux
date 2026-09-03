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

### 3. Can a small extension make our discipline executable? **See below**

`scratchpad/cmux-letter.ts`, 59 lines, registers a `cmux_letter` tool
that posts a durable feed letter and optionally rings a pane — with all
three doorbell traps encoded rather than taught: `tool_input` as an
OBJECT (a pre-encoded string double-encodes), an idle check before
ringing (a nudge into an active turn becomes an unsubmitted draft), and
text/Enter as SEPARATE sends (a trailing newline lands inside the input
box). Result recorded below.

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

Recorded at the bottom of this file once criterion 3 lands, together with
what would have to be true to adopt it — and what it would replace, since
this machine already hosts five harnesses and a sixth is only net-positive
if it retires one.
