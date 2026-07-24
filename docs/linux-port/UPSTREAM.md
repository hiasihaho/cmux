# Prepared upstream suggestions (manaflow-ai)

Material ready to send to the manaflow folks — the human decides when
and what. Prepared 2026-07-17 after the resize-freeze fix.

## 1. Renderer fix PR (ready to open)

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
