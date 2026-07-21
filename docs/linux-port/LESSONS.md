# Lessons — distilled, cross-cutting

[PROGRESS.md](PROGRESS.md) is the evidence log: chronological, dated,
append-only, and the right place to answer *"what happened on the 21st?"*.
It is the wrong shape for *"we are about to do X — what do we already
know?"*. This file is that second view: the transferable lessons, each
one paid for by a real debugging round, with a pointer back to the
evidence.

Keep entries **transferable**. Port trivia (GTK reparenting order, the
`CMUX_GHOSTTY=1` build trap, socket etiquette) belongs in PROGRESS,
PORTING or INSIDE-CMUX — not here.

## On trusting your own conclusions

- **Check the product's surface before declaring a primitive missing.**
  A design note claimed a "wait for JS condition" wrapper was the key
  missing primitive for SPA work. It had existed all along
  (`browser wait --selector/--function/--load-state/--timeout-ms`); the
  claim was inferred from the *test harness's* helpers rather than from
  `cmux browser --help`, and a QA agent found the real answer in two
  minutes. Grep the CLI surface before designing a replacement for it.
  (2026-07-21)
- **Root-cause before trusting a finding, including a friendly one.**
  Dogfood cycle 2's phantom "identify" bug manufactured two downstream
  bugs that did not exist. Cycle 6's "transient 20 s wait timeout" was
  not flaky network — it was our own transport capping every timeout at
  15 s and reporting it in language indistinguishable from a genuine
  condition-not-met. A tool that lies about *why* it failed will have
  its lies written down as bugs.
- **A/B only comparable things.** The "ReleaseSafe breaks socket spawn"
  conclusion came from comparing a fresh instance against one churned
  through 122 cycles. The build mode was innocent; the churn was the
  bug. (2026-07-19)
- **When you fix something, re-measure rather than reason.** The
  quadratic-transfer fix was predicted at "roughly linear"; measurement
  showed 51× at 6 MB and turned a vague improvement into a number worth
  upstreaming.

## On tests

- **"The suite is green" is not "the suite is clean."** The WebDriver
  harness passed 5/5 while leaking a fixture server every run: `$!` after
  `cd X && cmd &` records the *wrapper subshell*, so cleanup orphaned the
  real process, and the next run's pre-flight port cleanup hid it. Check
  processes and ports after a run, not just exit codes. (2026-07-21)
- **A race test needs proven discriminating power.** Asserting "the race
  did not happen" is worthless unless you know the test *could* have seen
  it. `browser-navigation-smoke.sh` runs the same loop twice — barrier
  vs `--no-wait` (the exact pre-fix behavior) — and prints the latter's
  stale count. Barrier 0/20 *while* `--no-wait` is 20/20 is what makes
  the PASS mean something. Print it; do not assert on it, because
  timing-dependent expectations are how suites go flaky.
- **Write the regression test before believing the patch.** The
  navigation barrier's own test caught a real bug *in the barrier* — a
  cancelled in-flight load fires the same completion event, settling the
  barrier on a load that was never ours. Hand-testing had passed.
- **Poll, don't sleep.** A fixed sleep is a latent flake that fails
  looking like a product bug. Polling was also 25% faster end-to-end.
- **Stall the server, not the client**, when you need to widen a race
  window — and thread the fixture server, or a deliberately slow handler
  turns into a request backlog that wedges every later assertion and
  reads exactly like a product bug.

## On oracles and ground truth

- **An oracle is ground truth only for the surface under test.**
  pocketyoga's `poses.json` lists 563 poses, but `visibility` splits them
  167 primary / 312 secondary / 84 tertiary, and the index page links
  *only* the 167. Asserting "did you get all 563?" against an index-only
  extraction would have scored a perfect result as a 70% failure.
- **Check whether the hard way is necessary before building for it.**
  The SPA extraction test was nearly built as an elaborate browser crawl;
  the app fetches a plain JSON endpoint, so `curl` gets everything and
  the elaborate version would have proven nothing about the browser
  stack. The same discovery is what made a *good* test possible —
  extract via the browser, score against the endpoint.
- **Guard the shortcut in the prompt.** A capable agent handed "extract
  the data" will find the JSON endpoint and use it — correct engineering,
  green report, zero coverage of the thing under test. Say: browser only;
  the oracle is the grader, not the solution.

## On asynchronous APIs (WebKit, GTK, anything signal-driven)

- **Connect the completion signal before starting the operation.**
  Checking afterwards is the race. This is the whole navigation-barrier
  bug in one line.
- **Completion events are not automatically yours.** Starting a
  navigation cancels the in-flight one, and the cancellation emits the
  same `LOAD_FINISHED`. Require a commit (or another provably-ours
  marker) before accepting a completion event.
- **Returning success early is worse than returning slowly.** The failure
  mode is not a crash but silently correct-looking wrong data, which then
  gets written into a report and believed.
- **A silent cap is worse than a hard error.** The 15 s transport cap and
  the quadratic transfer shared a shape: no error, no truncation, just
  behavior that looks like something else (a hang, a failed predicate).
  If you must bound something, say so in the response.

## On dogfooding

- **Exploratory agents answer a different question than regression
  tests.** A scripted test asks "does the path I already know still
  work?"; a fresh agent asks "does someone who does not know the path
  succeed, and where do they stumble?" The stumbling is the output.
  Order: dogfood to discover, then codify the working path as a test.
- **Match the harness to the runtime.** Since the Ghostty default flip, a
  dogfood run must target the **dev** instance: Ghostty surfaces spawn
  their shell on first map, so the tester's background workspace stays
  shell-less, and on the daily instance the harness deliberately skips
  the `select-workspace` that would start it (focus etiquette). A
  daily-targeted run just times out.
