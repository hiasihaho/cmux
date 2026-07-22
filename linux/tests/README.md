# linux/tests

Manual, on-demand test harnesses for the Linux port. None run in CI yet;
all are safe to run beside the human's daily instance — each starts its own
cmux with a distinct `CMUX_APP_ID`, socket, session file **and X display**.

```sh
linux/tests/run.sh                # full gate: freshness check, every suite, ledger
linux/tests/run.sh find popup     # only suites matching those words
linux/tests/run.sh --list         # what exists, what each covers, expected counts
linux/tests/run.sh --suite ui-commands --keep       # one suite, leave it up to poke
linux/tests/run.sh --suite vte-scrollback --repeat 10   # flake hunter: timed runs
linux/tests/run.sh --suite session-persistence --until-fail   # run until red
linux/tests/run.sh --build        # CMUX_GHOSTTY=1 swift build first, then the gate
```

`run.sh` is the front door — flags only, no prompts, so agents and CI
never hang on a menu. `run-all.sh` stays the sequential gate executor
underneath (calling it, or a suite script, directly still works).
Three tripwires ride along (2026-07-22):

- **Freshness:** suites test `.build/debug/` binaries as-is, so a
  forgotten `swift build` silently tests yesterday's code. Every run
  warns when a binary is older than the newest `.swift` source
  (including the shared CLI via the `CmuxCLI/CLI` symlink).
- **The assertion-count ledger** ([`suites.tsv`](suites.tsv)): a suite
  whose executed assertion count drops below its ledger row FAILS the
  gate — an early exit that skips half a file can no longer read as
  green. Update the count in the same commit as any intentional change;
  suites with skips are waived (skips collapse whole blocks).
- **Flake hunting:** `--repeat N` / `--until-fail` time every iteration
  and keep the full log of each red one under `/tmp/cmux-flakehunt/`,
  so "is this a flake or a regression" is one flag instead of an
  evening.
- **Kept gate logs:** the gate writes every suite's full output to
  `/tmp/cmux-gate-logs/<suite>.log` — the summary shows only
  PASS/FAIL lines, and a red suite's diagnostics are useless if the
  gate throws them away (2026-07-22: they were being thrown away).

Suites share [`lib.sh`](lib.sh), which holds the setup, teardown and every
lesson that cost a debugging round — pre-flight port cleanup, killing by
exact name rather than `pkill -f`, backgrounding servers without a wrapper
subshell, polling instead of sleeping. Fixing one of those now fixes it
everywhere instead of in six copies.

**Suites run on a private X display (Xvfb).** That is not cosmetic: a
Ghostty surface spawns its shell on first *map*, so on a real desktop the
terminal assertions depend on whether the window happens to be visible,
which produced a stretch of unexplained failures on 2026-07-21. A virtual
display removes the variable and makes `screenshot` work, so UI can be
asserted rather than eyeballed. `CMUX_TEST_XVFB=0` disables it.

**Skips are not passes.** When a precondition is missing a suite calls
`skip`, which prints, counts separately, and never fails the run — so a
missing precondition can never masquerade as a product failure, nor as
success.

| Script | What it covers |
|---|---|
| [`browser-navigation-smoke.sh`](browser-navigation-smoke.sh) | The navigation barrier: goto/back/forward/reload must never let a following eval read the previous document; plus load_state, wait-flag chaining, honest timeouts |
| [`run.sh`](run.sh) | The front door: gate, `--list`, single suites, `--repeat`/`--until-fail` flake hunting, `--build`. Flags only, no prompts |
| [`run-all.sh`](run-all.sh) | Runs every suite sequentially and summarizes; separates failures from setup errors; enforces the assertion-count ledger |
| [`suites.tsv`](suites.tsv) | Suite inventory + assertion-count ledger — update counts in the same commit as intentional changes |
| [`lib.sh`](lib.sh) | Shared setup/teardown, Xvfb, assertions, `screenshot`, `wait_for_shell`, `v2` (raw JSON), `force_save`, capture-epoch verification (`mark_capture_epoch`/`fresh_marker_files`), freshness + foreign-instance warnings |
| [`webdriver-smoke.sh`](webdriver-smoke.sh) | The whole WebDriver stack: automation opt-in, attach mode, split adoption, trusted input, and cmux+WebDriver sharing one surface — plus a live strict-CSP run against github.com |
| [`browser-urlbar-smoke.sh`](browser-urlbar-smoke.sh) | Address bar: mirrors navigation, typed loopback/domain/search resolution — driven with xdotool on the private display |
| [`pane-zoom-smoke.sh`](pane-zoom-smoke.sh) | Pane zoom: geometry, toggle, switching panes, not persisted, screenshot |
| [`session-persistence-smoke.sh`](session-persistence-smoke.sh) | Schema v3: v2 migration, multi-tab panes round-tripping as tabs, selected tab, browser URLs, navigable restored history |
| [`browser-find-smoke.sh`](browser-find-smoke.sh) | Find-in-page: counts, next/previous wrap, case sensitivity, no-match recovery |
| [`find-probe.c`](find-probe.c) | Standalone probe for WebKitFindController signal semantics |
| [`pane-search-smoke.sh`](pane-search-smoke.sh) | `cmux search` across panes: both pane kinds, --kind/--regex/--case-sensitive, innerText semantics, JSON refs |
| [`browser-popup-smoke.sh`](browser-popup-smoke.sh) | Popup routing: window.open and target=_blank land in panes, window.opener survives, burst budget holds |
| [`popup-probe.c`](popup-probe.c) | Standalone probe for `WebKitWebView::create` — which settings gate it, who loads the URL, what returning NULL does |
| [`inspector-probe.c`](inspector-probe.c) | Standalone probe that answers what `webkit_web_inspector_get_web_view()` returns and when — how the Web Inspector pane was designed. **Read its caveat below before trusting a probe like this.** |
| [`ghostty-embed-smoke.c`](ghostty-embed-smoke.c) | Minimal C harness that hosts a Ghostty surface in a plain GtkApplication (proves the embedding shim independent of cmux) |
| [`ghostty-resize-bisect.sh`](ghostty-resize-bisect.sh) | X11 screenshot-diff detector for the (fixed) post-resize freeze; kept for reference — see the caveats in its header |

## Harness roadmap — enhancement ideas, and when to invest

The harness is development infrastructure for every future cmux version,
so its improvement ideas deserve the same treatment as product gaps: an
inventory kept where decisions are made, instead of a re-survey each
time someone wonders "should we build X now?". This section is that
inventory. GAPS.md carries one pointer row; the reasoning lives here.

**When to invest (and when not to):**

1. **After a flake class repeats.** One flake gets a targeted fix
   (poll-don't-sleep); the same *class* appearing a third time has
   earned a harness feature that hunts it.
2. **After hand-instrumenting twice.** Anything a debugging round adds
   by hand for the second time — refcount prints, timing probes, marker
   greps — belongs in the harness or the `debug.surfaces` doctor verb,
   so the third round starts with it for free.
3. **When invocation needs explaining.** If running something takes
   more than one obvious command, or a flag exists that nobody can
   discover without reading the source, wrap it.
4. **Never speculatively.** Ideas wait here until a rule above fires;
   an unused harness feature is maintenance debt with no rent paid.

**Landed 2026-07-22** (the four S-items, one batch): the unified
`run.sh` front door (flags only — the interactive TTY picker stays
deferred until the flag surface settles), the binary-freshness
preflight (`lib.sh` + gate, `--build` to fix inline), flake-hunter mode
(`--repeat`/`--until-fail`), and the assertion-count ledger
(`suites.tsv`, drop = gate failure). Per-suite durations print in the
gate as a side effect — the *trend* half of the timing idea remains
below.

**The inventory:**

| Idea | What / why | Effort |
|---|---|---|
| Per-suite timing trend | Durations print per suite now; *recording* them and flagging a suite at >2× its usual time would name load flakes as load flakes the moment they happen, instead of after a debugging round | S |
| Interactive picker | The deferred half of the front door: a suite picker when `run.sh` runs bare on a TTY — never for agents/CI, who always get flags | S |
| Preflight doctor (`cmux doctor`) | Merge lib.sh's environment checks (deps, ports, display) with the `debug.surfaces` verb (GAPS batch 5) into one command that says why an environment will or won't work — for the harness, the dogfood loop, and eventually users | M |
| Dual-backend gate | Run the full suite matrix under `CMUX_TERM=ghostty`. This is the precondition for flipping the default terminal backend (shim increment 3): the flip happens when the ghostty-mode gate is as green as the VTE one | M |
| CI | The suites are already headless-capable (Xvfb, private displays, own instances, sequential by design) — a GitHub Actions Linux runner could run the gate per push. Open questions: WebKitGTK/dependency provisioning and the ~6–7 min gate runtime | M–L |

## webdriver-smoke.sh

```sh
linux/tests/webdriver-smoke.sh          # run all assertions, clean up
linux/tests/webdriver-smoke.sh --keep   # leave instance + driver up for poking
```

Requires `WebKitWebDriver` (Fedora: `webkitgtk6.0`) and a shim-linked
build (`cd linux && CMUX_GHOSTTY=1 swift build`). Exit code: 0 all
passed, 1 an assertion failed, 2 setup problem. The github.com section
skips itself when offline.

**Nine assertions, in order:** automation opt-in banner · attach session
created without launching a browser · split adoption grew the workspace
by a pane · driver and cmux report the same URL for that pane · a
WebDriver click makes the page see `isTrusted=true` · console capture v2
records entries on the driver-controlled pane · cmux `snapshot` works on
github.com (isolated-world CSP fallback) · a WebDriver click really
navigates GitHub · cmux observes that navigation on the same pane.

### Lessons this harness encodes (each cost a debugging round)

- **Pre-flight cleanup is mandatory.** A previous `--keep` run leaves the
  fixture HTTP server holding its port; the next run then fails five
  assertions for unrelated-looking reasons (empty JSON everywhere). The
  script now frees `PAGE_PORT`/`WD_PORT`/inspector port and kills any
  instance with its own `CMUX_APP_ID` before starting.
- **Build WebDriver JSON with `json.dumps`, never by hand-escaping.**
  CSS selectors legitimately contain double quotes
  (`a[href$="/issues"]`); interpolating them into `"value":"$1"` produces
  invalid JSON, and the request silently matches nothing.
- **Pick the first *displayed* element, not the first match.** WebDriver
  enforces real-user interactability and answers `element not
  interactable` for hidden nodes — GitHub renders several hidden copies
  of its nav links. (A synthetic JS click would have fired blindly on the
  hidden one; this stricter behavior is a feature, not an obstacle.)
- **Assert that state actually changed.** The first version compared
  before/after URLs that were both unchanged and called it a pass. Any
  navigation assertion must require `after != before`.
- **Background a server directly, not behind `cd X && …`.** With
  `cd "$WORK" && python3 -m http.server &`, `$!` is the *wrapper
  subshell's* pid — cleanup kills the wrapper and orphans the server,
  which then keeps holding the port. Use `--directory` (no subshell) and
  free the port on exit as a backstop. This leak stayed invisible for a
  while because the pre-flight cleanup papered over it on the next run:
  the suite was green while leaving a stray process behind every time.
- **Poll, don't sleep, for network-dependent state.** The GitHub section
  originally waited a fixed 6s; that is the classic latent flake (and it
  fails looking like a product bug). Polling for the link is both more
  robust and faster (27s → 20s per run).
- **Each WebDriver session adopts its own pane**, so a second session
  against the same instance adds another surface — target surfaces by the
  ref captured after *that* session started, not a hard-coded one.

## browser-navigation-smoke.sh

```sh
linux/tests/browser-navigation-smoke.sh          # 8 assertions, cleans up
linux/tests/browser-navigation-smoke.sh --keep   # leave the instance up
```

Serves its own fixture with a **deliberate 300 ms server-side stall**, so
the race window is wide and the verdict does not depend on network luck.

### Lessons this harness encodes

- **A race test needs proven discriminating power.** The suite runs the
  same loop twice — once with the barrier, once with `--no-wait` (which is
  exactly the pre-fix behavior) — and prints the latter's stale count as
  INFO. Barrier 0/20 while `--no-wait` is 20/20 is what makes the PASS
  meaningful; if that INFO ever drops to 0, the fixture has stopped
  widening the window and the assertion has quietly lost its teeth. It is
  deliberately *not* asserted on, because timing-dependent expectations
  are how you get a flaky suite.
- **Stall the server, not the client.** A fixed client-side sleep tests
  nothing; a slow *response* is what actually opens the race.
- **Thread the fixture server.** `HTTPServer` is serial, so a handler that
  sleeps 300 ms turns rapid-fire navigations into a backlog that wedges
  every later assertion — which reads exactly like a product bug. Use
  `ThreadingHTTPServer`. (This cost one confusing round of six cascading
  failures.)
- **`--json` prints the result payload directly**, with no `result`
  wrapper. A `.get("result", d)` fallback silently hides which of the two
  you actually got; assert on the real shape.

## inspector-probe.c

```sh
gcc linux/tests/inspector-probe.c -o /tmp/inspector-probe \
    $(pkg-config --cflags --libs gtk4 webkitgtk-6.0) && /tmp/inspector-probe
```

Answers three things the WebKitGTK docs do not: `get_web_view()` is NULL
outside the placement signal, the object is a `WebKitWebViewBase` that is
**not** a `WebKitWebView`, and returning TRUE claims responsibility for
placement.

**Caveat — the reason this file is kept.** The probe emits `attach`,
because its web view sits alone in a plain `GtkWindow`. Inside cmux's pane
tree WebKit emits `open-window` instead: the surrounding widget tree
changes its docking decision, and no amount of probing in the simplified
environment would have shown that. The first implementation trusted the
probe, claimed `open-window` without placing anything, and produced a
silently empty pane. **A probe tells you what an API does in the probe's
environment.** Handle every signal it might send, and verify in the real
one.

## browser-popup-smoke.sh

```sh
linux/tests/browser-popup-smoke.sh          # 6 assertions, cleans up
linux/tests/browser-popup-smoke.sh --keep   # leave the instance up
```

Guards the fix for popups silently doing nothing. Note assertion 5's
wording: the burst budget is per opener per 10s, so earlier assertions in
the same run have usually already spent part of it — the check is "no more
than the cap", not an exact count.

## popup-probe.c

```sh
gcc linux/tests/popup-probe.c -o /tmp/popup-probe \
    $(pkg-config --cflags --libs gtk4 webkitgtk-6.0) && /tmp/popup-probe
```

Answers, for WebKitGTK 6.0: `javascript-can-open-windows-automatically`
defaults FALSE and while it is off `create` never fires;
`webkit_web_view_new_with_related_view` no longer exists (`related-view`
is construct-only); WebKit loads the target URL into the view you return,
so loading it yourself fetches twice; returning NULL blocks cleanly.

Both triggers in the probe are **synthetic** clicks
(`is_user_gesture=0`), so it does not tell you how a genuine user gesture
behaves with the setting off — an untested branch, stated here rather
than assumed away.
