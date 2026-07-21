# linux/tests

Manual, on-demand test harnesses for the Linux port. None of these run in
CI yet; all of them are safe to run beside the human's daily instance
(each starts its own isolated cmux with a distinct `CMUX_APP_ID`,
socket and session file).

| Script | What it covers |
|---|---|
| [`webdriver-smoke.sh`](webdriver-smoke.sh) | The whole WebDriver stack: automation opt-in, attach mode, split adoption, trusted input, and cmux+WebDriver sharing one surface — plus a live strict-CSP run against github.com |
| [`ghostty-embed-smoke.c`](ghostty-embed-smoke.c) | Minimal C harness that hosts a Ghostty surface in a plain GtkApplication (proves the embedding shim independent of cmux) |
| [`ghostty-resize-bisect.sh`](ghostty-resize-bisect.sh) | X11 screenshot-diff detector for the (fixed) post-resize freeze; kept for reference — see the caveats in its header |

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
