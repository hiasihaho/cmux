# Prepared upstream reports

The collection point for everything this project could usefully send
somewhere else. **Nothing here has been sent.** hias decides what and
when, and a dedicated session will do the sending; until then this file
is the queue.

Sections 1–4 are **manaflow-ai** (cmux + ghostty), prepared 2026-07-17
onward. Section 5 is **third-party projects** — the agent harnesses and
providers this machine runs.

Each entry aims to be report-ready: what happens, a reproducer someone
else can run, the evidence, what was ruled out, and the versions it was
seen on. An entry that cannot be reproduced by a stranger is not ready
to send.

## 1. Renderer fix PR — **OBSOLETE, do not open** (2026-07-24)

The 2026-07-24 fork catch-up merge (16,853 manaflow commits, see PROGRESS)
showed manaflow **deleted the stale-frame-replay early-returns entirely**
from `src/renderer/generic.zig` — the code our Darwin-gate patched no
longer exists upstream, so the bug it fixed cannot occur there. The PR
branch and draft body are kept only as history. Do not open the PR.

*(historical, pre-2026-07-24:)*

Branch **`fix-stale-frame-replay-gtk`** on hiasihaho/ghostty: exactly
one commit (`91024ab`, cherry-picked from our `ae8ba5f0a`) on top of the
manaflow base `80d3fa0`. Zero macOS behavior change by construction
(`comptime isDarwin()` — Darwin compiles the identical code as before).

Open it with:

```sh
cd ghostty && gh pr create --repo manaflow-ai/ghostty \
  --base main --head hiasihaho:fix-stale-frame-replay-gtk \
  --title "renderer: Darwin-gate the stale-frame replay during resize" \
  --body-file ../docs/linux-port/upstream-pr-body.md
```

Draft body: [upstream-pr-body.md](upstream-pr-body.md).

## 2. Optional mentions for the same conversation

- **The Linux embedding work exists**: branch `linux-gtk-embed` on
  hiasihaho/ghostty carries a GTK embedding shim (`zig build lib-gtk` →
  `libghostty-gtk.so` + `ghostty_gtk_embed.h`) that lets a foreign
  GTK4/libadwaita app host GhosttySurface widgets — cmux's Linux port
  self-hosts on it. All embed behavior is gated so standalone ghostty is
  unchanged. If manaflow wants Linux support in their cmux, this is the
  foundation; happy to walk through it.
- **Submodule hygiene**: the cmux repo's recorded ghostty SHA `80d3fa0`
  was unreachable from any branch on manaflow-ai/ghostty (orphaned —
  fresh clones can't fetch it). Our fork now hosts it; pushing a branch
  containing it to the manaflow fork would fix that for everyone.

## 3. Longer-term

- The fork is a squashed graft of upstream (histories unrelated; a
  `git merge-base` against ghostty-org/ghostty fails). If manaflow ever
  wants regular upstream syncs, content-level diffs (`git diff
  <upstream-commit> <fork-commit> -- src/`) are the workable tool — that
  is exactly how this bug was isolated.

## 4. cmux repo (not ghostty) — two findings that affect macOS today

Both came out of the 2026-07-21 SPA-extraction dogfood. Unlike the
renderer patch above, these live in the **cmux** repo, and one of them is
already fixed in a file macOS compiles.

### 4a. Quadratic CLI response transfer — fix already written, macOS included

`SocketClient.send` in the shared `CLI/cmux.swift` rescanned the *entire*
accumulated buffer for a newline after every 8 KB read (`N/8192 × O(N)`).
Any large v2 response pays it — `browser eval` is just the easiest way to
notice. Measured on Linux, but the code is platform-neutral, so **macOS
has the same cost**:

| payload | before | after |
|---|---|---|
| 1 MB | 1.43 s | 0.24 s |
| 3 MB | 11.65 s | 0.50 s |
| 6 MB | 44.32 s | 0.87 s (51×) |
| 16 MB | ~5 min (projected) | 2.15 s |

Fix is one condition (`sawNewline` is monotonic, so only the newly-read
chunk needs scanning) in our commit `183bdd102`. Worth flagging that the
symptom is **no error and no truncation — it simply looks like a hang**,
which is how it survived unnoticed.

Caveat for whoever lands this: since 2026-07-24 shared-CLI changes are
compile-verified on real macOS (15.7.7 VM, CLT-only) via the
`macos-verify/` package — which on its first run caught two
`__suseconds_t` glibc-isms our port commit had introduced. Still not
`xcodebuild`-verified: the app target needs full Xcode + GhosttyKit,
which the VM does not have.

### 4b. `browser.navigate` returns before the load commits — macOS bug, unfixed there

`Sources/TerminalController.swift:5322` calls `browserPanel.navigateSmart(url)`
and returns `.ok` immediately. WKWebView loads asynchronously, so a
following `browser.eval`/`wait`/`snapshot` can run against the *previous*
document and report success with data from the wrong page. This is the
dangerous class: not a crash, but silent wrong data, and a `wait`
predicate that happens to hold on the old page passes instantly and
confirms the illusion.

We measured the equivalent Linux bug at **2 stale reads in 12** against a
live site, and 20/20 against a deliberately slowed local server. We have
not reproduced it on macOS (no toolchain here) — the claim is a code
reading, so treat it as "please check this" rather than a bug report.

Our fix, if useful as a design (commit `0cf741644`): hold the response
until the new document commits — `LOAD_FINISHED` normally, `COMMITTED`
once the deadline passes (surfaced as `load_state`), else a real timeout,
because with no commit the old page is still the one answering. Two
traps we hit that any implementation will meet:

- The load-progress signal must be connected **before** the load is
  requested; checking afterwards is precisely what races.
- Starting a navigation cancels any in-flight one, and the cancellation
  *also* fires the completion event — honoring it settles the barrier on
  the previous load and reintroduces the exact staleness you are fixing.
  Requiring a commit before accepting completion is what disambiguates.

Related, same area: any verb carrying its own `timeout_ms` needs the
transport budget to exceed it. Ours capped flat at 15 s on both ends, so
`wait --timeout-ms 20000` died at 15 s with a transport timeout that is
indistinguishable from the predicate never being met.

### 4c. `browser highlight` shadowed by the find-in-page alias — macOS affected after any merge of our branch

Our Linux find-bar work aliased `highlight` onto the `find-in-page` CLI
block; upstream independently added a dedicated `highlight` subcommand
(element outline via `browser.highlight`) *below* it. In the merged CLI
our block matched first, so upstream's element-highlight became dead
code — on macOS too, for anyone building the CLI from our tree. Fixed
2026-07-22 by dropping the alias (`find-in-page` keeps its own name).
Worth flagging in any upstream PR that touches CLI/cmux.swift.

### 4d. `browser devtools console` shadowed by the sweep's devtools alias — macOS affected

Same first-match-wins class as §4c, caught one day later while building
the Linux `browser.console.show`. The 2026-07-22 capabilities sweep
aliased `devtools` onto our `browser inspect` CLI block; upstream's
dedicated `devtools` block (toggle→`browser.devtools.toggle`,
console→`browser.console.show`) sits ~450 lines below and became dead
code — so `cmux browser devtools console` silently sent
`browser.inspect` on BOTH platforms. Found by strace'ing the CLI's
socket write after the server's reuse logic tested clean in isolation.
Fixed 2026-07-22 by scoping our block back to `inspect` only; upstream's
block owns `devtools` again. Lesson now twice-paid: never alias a
subcommand name in an upstream CLI file without grepping for an existing
block that owns it lower down.

### 4e. Possible macOS bug to verify: navigation timeout may not stop the load

Found on Linux 2026-07-23 (PROGRESS "corp-network accident"): the
navigation barrier's timeout branch reported failure without
`stop_loading`, so the provisional load could commit later and yank the
pane. The Linux port is fixed; macOS's barrier (`BrowserPanel`
navigation paths) should be checked for the same pattern on the next VM
round before any upstream PR claims parity here.

### 4f. codex-teams orphans its `codex app-server` child on teardown — macOS affected

Found on Linux 2026-07-24 by the teams-siblings dogfood (codex installed).
`codexTeamsTerminateProcess` (CLI/cmux.swift) does only `process.terminate()`
(SIGTERM to the immediate child). The `codex app-server` it starts
(`codex app-server --listen ws://127.0.0.1:<port>`) escapes codex-teams'
process group AND ignores SIGTERM, so an abnormal codex-teams exit leaves an
orphaned app-server bound to a loopback port (observed directly while
probing). Shared-CLI code — macOS has the same terminate path. Fix wants
SIGTERM→wait→SIGKILL escalation and/or process-group signaling (killpg).
Not fixed here (shared CLI, unverifiable on macOS from this host); flag for
the next upstream PR touching codex-teams.

## 5. Third-party projects (not manaflow)

Found while making the Linux port's desks work; all measured on Fedora
43, 2026-09-02/03. Details and raw numbers:
[features/17-pi-harness-evaluation.md](features/17-pi-harness-evaluation.md)
and `opencode-sophia-empty-turns-20260903.md` at the repo root.

### 5a. pi — a silent HTTP endpoint hangs the agent for ever (no request timeout)

**Project:** `@earendil-works/pi-coding-agent` (github.com/earendil-works/pi), MIT
**Version:** 0.84.4 · **Node:** v22.21.1 · Linux

**What happens.** A provider whose server ACCEPTS the TCP connection and
then never responds makes pi wait indefinitely. There is no request
deadline: a 90-second window was exhausted with no output, no error and
no retry. A provider that is merely DOWN (connection refused) is handled
fine — the difference is silence, not unreachability.

**Reproducer** (six lines, no dependencies):

```python
import socket
s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 9955)); s.listen(8)
while True:
    c, _ = s.accept()   # accept, then never answer
```

Then in `~/.pi/agent/models.json`:

```json
{ "providers": { "blackhole": {
    "baseUrl": "http://127.0.0.1:9955/v1", "api": "openai-completions",
    "apiKey": "x", "models": [{ "id": "m" }] } } }
```

```sh
pi --offline --provider blackhole --model m --api-key x -p "hi"   # never returns
```

**Measurements** (same machine, `pi -p "hi"`):

| configured providers | wall time |
|---|---|
| 0, 1, 2 unreachable (connection refused) | ~4 s |
| 3 unreachable | 10 s |
| ONE silent server | hangs; 90 s window exhausted |

**What does NOT fix it.** `retry.provider.timeoutMs` (documented as
"Provider/SDK request timeout in milliseconds") has no effect on this
path: set to 5000 with `retry.maxRetries: 1`, the hang persisted for a
full 100 s window. The settings file IS being read — changing
`retry.maxRetries` from its default 3 to 1 changed the observed attempt
count against a 429 endpoint from 4 to 2 — so this looks like the
timeout not being wired into the custom `openai-completions` client
rather than a config mistake.

**Why it matters.** A hung endpoint is indistinguishable from a hung
agent, and the natural suspects are all wrong: this cost four wrong
diagnoses on our side (an extension's imports, `node:child_process`,
TypeScript transpilation, the provider list) before the silent-server
shape was isolated.

**Suggested fix.** A default request deadline on the custom-provider
path, and/or honour `retry.provider.timeoutMs` there. Failing fast with
"provider did not respond within Ns" would have made this a five-second
diagnosis.

**Credit where due, in the same report:** against a 429 endpoint pi does
exactly the right thing — 4 attempts at 2s/4s/8s, then the provider's own
error text and a non-zero exit.

### 5b. opencode — an HTTP 429 becomes a contentless turn and an unbounded retry loop

**Project:** opencode · **Version:** 1.18.26–1.18.27 · Linux

**What happens.** When the provider answers a streamed request with HTTP
429, opencode records the turn as a step with no content
(`step-start`/`step-finish` only, `reason: "unknown"`, all token counts
zero) and immediately retries. Nothing surfaces the status code. The
retries become the load that sustains the rate limit, so the session
spins until a human interrupts it.

**Evidence** (from `~/.local/share/opencode/opencode.db`):

- one session: **2,785 contentless assistant turns out of 3,314**;
  a healthy session on another provider: **1 of 551**;
- the log shows `process` → `stream` → `loop` repeating at ~0.8 s for two
  hours, ending only at the user's `cancel` (`error=Aborted`);
- a BRAND-NEW session (4K tokens) produced **64 contentless turns out of
  64** — so it is not context exhaustion;
- a hand-made request to the same endpoint returned **429**, a second
  seconds later returned 200.

**Suggested fix.** Treat a rate-limited stream as a typed error with
backoff (the way pi does), surface the status code, and do not persist a
contentless turn as if the model had answered.

**Related, same project:** when a provider returns no `usage` object,
the context meter reads zero for ever and auto-compaction never fires —
no warning before the context wall. opencode does request usage
(`stream_options: {include_usage: true}`), so this is about the missing
fallback, not the request.

### 5c. hermes — CSI-u key matching ignores lock modifiers (NumLock breaks Ctrl+C and Enter)

**Project:** Hermes Agent · **Version:** v0.20.4 (2026.8.18)

**What happens.** Hermes enables the kitty keyboard protocol when
`TERM_PROGRAM` is one of its allowlist (ghostty included). With **NumLock
on**, the terminal reports the lock bit in the modifier bitmask, and the
key table does not match — the sequences arrive as literal text in the
composer, so Ctrl+C, Enter and Escape stop working.

**Observed sequences** (NumLock on, GTK/Ghostty terminal):

- `ESC[99;133u` — codepoint 99 (`c`), modifier 133 → 132 = 128 (num_lock) + 4 (ctrl) = **Ctrl+C**
- `ESC[27;129u` — Escape with 128 (num_lock)

A comment at `cli.py:4143` records the same bug class without the lock
bit (`ESC[99;5u`), which was fixed.

**Suggested fix.** Mask lock modifiers (num_lock 128, caps_lock 64)
before matching, so `99;133u` folds to `99;5u`.

**Workarounds meanwhile:** turn NumLock off, or start hermes with
`TERM_PROGRAM` unset so it never enables the extended mode.

### 5d. regio-ai gateway (`chat.s.regio-ai.eu`) — operator report, not open source

Two things a client cannot work around:

1. **No `usage` object in streamed responses.** Every other provider on
   this machine reports it (anthropic 18.9M input tokens recorded,
   joyai, devstral, lmxomni…); this endpoint reports none across 3,314
   assistant messages. Clients ask for it correctly
   (`stream_options: {include_usage: true}`), so every context meter and
   every auto-compaction trigger is dead against this endpoint.
2. **429s carry no `Retry-After` and no rate-limit headers**, so a client
   cannot back off intelligently — only guess.

Also observed: streams ending without a `finish_reason`.
