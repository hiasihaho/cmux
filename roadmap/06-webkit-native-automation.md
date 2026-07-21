# WebKit-native automation — decided direction & feature roadmap

Opened 2026-07-21 from the strict-CSP session (see `docs/linux-port/PROGRESS.md`
2026-07-21 entries). **Decision: we stay on system WebKitGTK and adopt its
native API surface for everything the JS-injection layer can't reach.
We do NOT pursue a CDP-capable engine (Chromium/CEF embedding).**

## Why this came up

Dogfooding the browser verbs from inside the port showed that every
DOM-level verb died on GitHub with a CSP `EvalError`. Root cause and fix
(isolated-world fallback in `BrowserJS.run`, commit `c562a3924`): WebKitGTK
main-world evaluation is subject to the page CSP, unlike WKWebView which
exempts user-agent scripts. That triggered the broader question: is our
JS-injection automation the right architecture, or should we want CDP
(Chrome DevTools Protocol) capabilities?

## The architecture comparison (the important explanation)

Our verbs are essentially the **content-script / WebDriver-classic
subset**: querySelector-driven reads, synthetic DOM events, in-page eval.
That is the same mechanism Playwright uses for most element interaction —
in-process, zero external dependencies, works with plain system WebKitGTK.

What CDP adds that in-page JS **cannot** reach, ever:

| Capability | Why JS injection can't | Do we need it? |
|---|---|---|
| Trusted input (`isTrusted: true`) | synthetic events are flagged untrusted; some login flows, drag-and-drop, video players ignore them | occasionally — real gap |
| Network interception / HAR | no page-JS API for other requests' bodies/headers | for deep QA, yes |
| JS debugger (breakpoints, stepping) | not exposed to page JS | human debugging, via Inspector |
| Cross-origin iframes | same-origin policy blocks contentDocument | rare but real |
| Out-of-band console/exception capture | page CSP + world isolation limit wrap-based capture | yes — see increment 1 |

WebKit does not speak CDP (it's Chromium's protocol) and never will; its
equivalents are the **Inspector protocol** (private, powers the Web
Inspector UI), **W3C WebDriver** (`/usr/bin/WebKitWebDriver` ships in
Fedora's webkitgtk6.0, 2.52.4), and growing **WebDriver BiDi** support.
Embedding Chromium to get CDP would be a massive dependency swap, lose the
GTK-native integration, and buy us only the rows above. The port has
already been peeling off JS-layer weaknesses with native WebKit APIs
(cookies via the cookie manager, screenshots via `get_snapshot`, dialogs
via the script-dialog signal). **This roadmap continues that pattern to
the full useful WebKitGTK feature set.**

## Increments (roughly priority-ordered)

1. **Console/error capture v2 (fixes a real blind spot).** Today's
   `browser console list` wraps `window.console` lazily via the eval
   envelope. On strict-CSP sites the arming script lands in the isolated
   world → wraps the wrong world's console → captures nothing the page
   logs. Replace with a **document-start user script in the main world**
   (`webkit_user_content_manager_add_script`) posting through a
   **script message handler**
   (`webkit_user_content_manager_register_script_message_handler`) into a
   per-view app-side ring buffer. User scripts are user-agent scripts —
   exempt from page CSP, no eval involved — so this captures on every
   site and from page load (better than lazy arming on both counts).
   Keep wire shape of `browser.console.list`/`errors.list` unchanged.
2. ✅ **WebDriver opt-in** (shipped 2026-07-21). `webkit_web_context_set_automation_allowed(TRUE)`
   + handle `WebKitWebContext::automation-started` →
   `WebKitAutomationSession` (+ `set_application_info`). Gate behind an
   env var / socket flag (e.g. `CMUX_WEBDRIVER=1`) — automation mode has
   security implications, same posture as `CMUX_SOCKET_MODE`. Payoff:
   Selenium and friends can drive cmux browser panes via
   `/usr/bin/WebKitWebDriver`; **trusted input** and standardized
   navigation come from the driver side. Revisit **WebDriver BiDi** as
   WebKitGTK's support matures (event streams: console, network — the
   real CDP-alternative).
3. **Web Inspector pane** (noted for later — see decision below; not scheduled yet). `webkit_settings_set_enable_developer_extras`
   + `webkit_web_view_get_inspector()`; present the inspector (it is a
   GTK widget via `WebKitWebInspector`) in a cmux split next to its page.
   Full DevTools — elements, network, debugger, console — for the human;
   a headline feature no terminal-multiplexer-with-browser has.
4. **Native console tap (cheap stopgap/debug aid).**
   `webkit_settings_set_enable_write_console_messages_to_stdout` in DEBUG
   builds so page console output lands in the app log even before (1).
5. **Longer tail of the native API, as verbs when needed:**
   `WebKitFindController` (native find-in-page — parity with the new
   terminal find overlay), `WebKitDownload` hardening for
   `browser.download`, `WebKitWebsiteDataManager` (targeted storage/data
   clearing beyond cookies), permission-request handling (geolocation,
   notifications, media capture → explicit socket-controllable policy),
   `WebKitWebView::create` (popup/window.open routing into new panes),
   TLS error policy, favicon database (sidebar tab icons), user content
   filters (content-blocker JSON — ad-block for agent browsing),
   print-to-PDF (`webkit_print_operation` / `webkit_web_view_send_message_to_page`
   alternatives to be evaluated when a full-page-PDF verb is requested).

## Non-goals

- CDP compatibility or Chromium/CEF embedding (rejected above).
- Playwright's patched-WebKit protocol (requires their fork build, not
  system WebKitGTK).
- Speaking the private Inspector wire protocol programmatically — we get
  its value through the Inspector UI (3) and WebDriver/BiDi (2).

---

# WebDriver: operating model, findings, and the split-adoption decision

Everything below was established empirically on 2026-07-21 against
Fedora's `/usr/bin/WebKitWebDriver` (webkitgtk6.0 2.52.4) driving
cmux-adw. Increment 2 shipped the opt-in; this section is the reference
for what the model actually is, so nobody re-derives it.

## 1. How a session is established (two modes, both verified)

**Mode A — driver launches the browser (the default W3C model).**
Capabilities carry `webkitgtk:browserOptions.binary`; the driver spawns
that binary and waits for it to allow automation.

```jsonc
{"capabilities": {"alwaysMatch": {
  "webkitgtk:browserOptions": {"binary": "/path/to/wrapper.sh", "args": ["--automation"]}
}}}
```

Two traps, both hit and both real:
- **Omit `browserName`.** We report `browserName: "cmux"` (from our
  `webkit_application_info_set_name`), so a request asking for
  `"webkitgtk"`/`"MiniBrowser"` fails with *"Failed to match
  capabilities"*. Omitting it matches anything.
- **Point `binary` at a wrapper**, not at `cmux-adw` directly. The
  launched instance must get its own `CMUX_APP_ID` / `CMUX_SOCKET_PATH` /
  `CMUX_SESSION_PATH`, or it collides with the human's daily instance.

**Mode B — driver attaches to an ALREADY-RUNNING instance.** Start cmux
with a WebKit inspector server, then point the driver at it:

```sh
WEBKIT_INSPECTOR_SERVER=127.0.0.1:5555 CMUX_WEBDRIVER=1 cmux-adw   # running instance
WebKitWebDriver --port=4446 --target=127.0.0.1:5555                # attach
curl -X POST localhost:4446/session -d '{"capabilities":{"alwaysMatch":{}}}'
```

Verified: the session is created against the running process (returns
`browserName: cmux`) with **no browser launch at all** and no `binary`
capability. This is the mode that matters for cmux, because it can target
the human's live instance.

## 2. The session limit — and how to actually parallelize

**One session per driver *process*.** A second `POST /session` to the
same driver returns *"Maximum number of active sessions"*. `/status`
reports `ready:false, "A session already exists"`. `--replace-on-new-session`
swaps the existing one rather than running two.

**Parallelism = multiple driver processes on different ports.** Verified:
drivers on `:4444` and `:4445` held two concurrent sessions, each with its
own isolated cmux instance. That is also how Selenium Grid scales
WebKitGTK nodes.

**tmux does not help here** — it multiplexes *terminals*, not browsing
contexts; a WebDriver session is a protocol object owned by one driver
process. The equivalent "multiplexer" is either N drivers on N ports or a
Grid in front of them. (If the goal is many *pages* rather than many
sessions, one session can open multiple windows/tabs and switch between
them with `POST /session/{id}/window` — cheaper than N drivers.)

## 3. What the driver drives (the decisive finding)

**WebDriver never adopts an existing browsing context.** In *both* modes,
session creation fires our `WebKitAutomationSession::create-web-view`
handler and drives whatever view we return. Measured in attach mode
against a running instance that already had a browser pane open on a
real URL: the session reported an **empty url/title and exactly one
window handle** — i.e. the fresh view we handed it, not the human's pane.

Two consequences:
- The driver cannot wander into the human's other panes. That is a
  **safety property**, not a limitation.
- Which view the driver gets is **entirely our choice**, because
  `create-web-view` is our hook. Today we return a view in a standalone
  window; nothing stops us returning a view that lives in a cmux split.

## 4. Recommendation: yes, adopt a cmux split (in attach mode)

Combining §1 Mode B with §3: with the driver attached to the human's
running instance, `create-web-view` can create a **browser pane in the
live workspace** and hand the driver that pane's web view. The result:

- Automation appears **as a normal cmux pane**, visible to the human,
  splittable, with a terminal alongside — instead of an orphan window.
- **Both automation layers address the same surface**: WebDriver drives
  it with trusted input, while cmux's socket verbs (`browser snapshot`,
  `get text`, console capture v2, screenshot) read/act on the very same
  web view. That combination is strictly more than either layer alone,
  and is exactly what the JS-injection limits table above asks for.
- Session lifecycle maps onto pane lifecycle: driver session ends →
  close the pane (and vice versa: pane closed → session invalidated).

**Why it isn't done yet (the actual work).** cmux creates web views
itself: `BrowserSurfaceFactory.create` calls `webkit_web_view_new()`
while `TerminalStackWidget.sync()` materializes widgets from the model.
Adoption inverts that — the web view exists *first*, and the surface must
wrap it. The change is:

1. A pending-adoption registry: `surfaceId → WebKitWebView*`.
2. `BrowserSurfaceFactory.create` consults it and adopts instead of
   constructing when an entry exists.
3. `create-web-view` (main thread already) builds the view with the
   construct-only automation properties, appends a `.browser` leaf to the
   target workspace's model, registers it for adoption, and returns the
   view — the widget lands in the pane on the next `sync()`.
4. Lifecycle: close-pane → invalidate the session's view; session end →
   close the pane. Plus a policy for *which* workspace receives it
   (suggest: the selected one, or a dedicated "automation" workspace so
   agents never disturb the human's layout).

Effort: moderate, and it touches the surface-creation path that the
mid-init leak (roadmap/05) also lives in — worth doing carefully, ideally
after or alongside that hardening.

**Interim recommendation:** keep the standalone-window behavior as the
default (it is honest and zero-risk), and treat split adoption as the
next WebDriver increment, gated on the same `CMUX_WEBDRIVER=1`.

## 5. Security posture (unchanged, restated)

`CMUX_WEBDRIVER=1` is required; never default. Attach mode additionally
requires the human to set `WEBKIT_INSPECTOR_SERVER`, which opens a local
port — bind it to `127.0.0.1` only. The automation view uses the
**automation network session** (ephemeral): the driver does not inherit
the human's cookies. Any local process that can reach the driver port or
the inspector port can drive the browser, which is why both are opt-in.
