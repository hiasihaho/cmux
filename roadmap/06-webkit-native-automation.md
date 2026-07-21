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
3. **Web Inspector pane.** `webkit_settings_set_enable_developer_extras`
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
