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

- **A probe tells you what an API does in the probe's environment.** The
  Web Inspector probe (a web view alone in a `GtkWindow`) emitted
  `attach`; inside cmux's pane tree WebKit emits `open-window` instead —
  the surrounding widget tree changed its decision, and nothing in the
  probe could have revealed that. The implementation trusted the probe,
  claimed the one signal it had seen, and shipped a silently empty pane.
  Probe to learn the shape of an API, then handle every branch it might
  take and verify in the real environment. (2026-07-21)
- **Claiming a callback you do not honor is worse than not handling it.**
  Returning TRUE from `open-window` suppressed WebKit's own window *and*
  placed nothing — strictly worse than either outcome alone. Only claim
  responsibility once the work actually succeeded; otherwise decline and
  let the library keep its fallback.

## The verification loop that worked

Six features shipped on 2026-07-21 (navigation barrier, screenshot fixes,
Web Inspector pane, popup routing, cross-pane search, find-in-page,
per-pane tabs). Every one of them had a real bug caught before or shortly
after landing, and the same five-step loop caught them. It is written
down because the order matters more than any individual step.

1. **Probe the API in isolation first.** A throwaway C harness against the
   real library, answering the questions the docs do not:
   `inspector-probe.c`, `popup-probe.c`, `find-probe.c`. Each one
   invalidated an assumption that would otherwise have shipped —
   `get_web_view()` is NULL outside its signal;
   `new_with_related_view` no longer exists;
   `found-text` reports the total only on the first search.
   **But see the caveat in LESSONS: a probe tells you what an API does in
   the probe's environment.** The inspector probe's answer did not
   transfer into the pane tree.
2. **Add a socket verb, even for a UI feature.** This is the step that is
   easy to skip and pays the most. `browser.inspect` and
   `browser.find_in_page` made GTK widgets *machine-checkable*; both
   promptly exposed stale-state bugs (`attached: false`; "1 of 3" for a
   query with no matches) that the UI would have hidden. It also means an
   agent and the human drive the same code path rather than two.
3. **Write a regression suite with proven discriminating power.** Not
   "it passed" but "it would have failed before the fix" — the popup suite
   prints the pre-fix behaviour's failure count alongside the fixed one.
4. **Ask the human for the pixels.** Screen capture is not available to
   the agent here (see the memory note), and twice the programmatic checks
   reported success while the screenshot showed an empty inspector pane and
   unusably cramped popup panes. Numbers cannot see layout.
5. **Re-run every suite, not just the new one.** These features share
   `adoptBrowserSplit`, the surface factory and the pane container. The
   tab refactor legitimately broke four popup assertions — which is a
   signal to *update the test deliberately*, stating that the behaviour
   changed, not to quietly make it pass.

Then document, and correct the overclaims: three separate FEATURES.md
entries were written as "beyond macOS" and demoted to parity after
actually checking `Sources/` — macOS has DevTools, popup routing and
per-pane find. The check takes a minute; the wrong claim survives for
years.

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

## On APIs that succeed too early

`ghostty_embed_surface_write_display` returns `true` once the core
surface exists. That is *not* the same as "there is a terminal that will
show this": an unmapped pane has a core surface but no started terminal,
so the bytes are queued and lost while the caller records success and
throws its only copy away. Scrollback replay now gates on
`gtk_widget_get_mapped` — the real readiness signal — and treats the
API's return value as necessary but not sufficient.

The general shape: when a call's success means "accepted" rather than
"took effect", never let that be the point where the last copy is
dropped. Look for an independent signal that the effect landed.

## On verifying a fix before believing it

The background-workspace scrollback bug was "fixed" twice before it was
actually fixed. The first fix removed the discard; the reproduction still
returned zero. The second added a retry on view sync; the reproduction
still returned zero — the sync runs before GTK maps the pane. Only the
third (a restartable poll) worked.

What made this cheap rather than embarrassing was running the exact
reproduction after each attempt, so each wrong theory cost one run
instead of reaching the user. And after the real fix, running it
*backwards*: reinstate the original bug, confirm the new assertion fails,
restore. A regression test that has never failed is a hypothesis, not a
guard.
