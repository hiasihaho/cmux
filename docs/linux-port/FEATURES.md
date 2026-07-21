# cmux (Linux port) — features

What the GTK4/libadwaita Linux port does today, described for use rather
than for porting. Two companion docs go deeper: **PARITY.md** (per-verb
status vs macOS) and **PROGRESS.md** (how each piece was built + verified).

Legend: **✅ parity** (also in macOS cmux) · **★ beyond macOS** (Linux
has it, macOS doesn't — verified against `Sources/` on 2026-07-20) ·
**⚙ Linux-specific implementation** (same user feature, different
internals) · **🟡 partial** (works, with a documented caveat).

## Terminals

- ✅ **Real terminal panes** — every workspace pane runs a live shell with
  the cmux environment (`CMUX_WORKSPACE_ID`/`CMUX_SURFACE_ID`/
  `CMUX_SOCKET_PATH`), so bare `cmux …` inside a pane targets that pane.
- ⚙ **Two backends: Ghostty (default) or VTE.** Shim-linked builds
  (`CMUX_GHOSTTY=1`) embed real Ghostty surfaces via a GTK embedding shim
  and are the default; `CMUX_TERM=vte` (or a plain build) falls back to
  VTE. macOS embeds libghostty through an `NSView`; the Linux port reaches
  the same engine through a foreign-GTK embedding shim
  (`GHOSTTY-SHIM.md`). Ghostty panes get shell integration, full
  scrollback, OSC title/pwd, bell→attention, and snappy scrolling.
- ✅ **Find in terminal** — Ctrl+Shift+F (or the header magnifier) opens a
  search overlay with next/prev, highlighting, Esc-to-close. macOS has its
  own find UI (`Sources/Find/`); Ghostty panes here use Ghostty's native
  overlay.
- ✅ **Splits & workspaces** — nested pane trees (GtkPaned), a workspace
  sidebar with attention dots, keyboard shortcuts (new tab/split/close),
  focus-follows-click, cwd inheritance, clean auto-close on shell exit.
- ✅ **Session persistence** — workspaces, pane trees, live cwds, browser
  URLs, and selection restored across restarts (`$XDG_DATA_HOME/cmux/`).

## Browser panes

- ✅ **Live web views** (WebKitGTK) as a pane kind: `cmux browser open
  <url>`, navigate/back/forward/reload, titles drive the tab.
- ✅ **Full Playwright-style automation over the socket** — eval, snapshot
  (role/name tree + element refs), click/fill/type/select, screenshot,
  ten `find.*` locators, iframe scoping, dialogs, cookies, storage,
  console/error capture, wait. See PARITY for the complete verb list.
- ⚙ **Works on strict-CSP sites** (GitHub, banks, many SPAs). WebKitGTK
  applies the page's CSP to main-world evaluation — unlike WKWebView,
  which exempts user-agent scripts — so a string-evaluating envelope is
  refused outright there. Automation evaluates in the main world first
  (macOS-identical behavior) and retries once in a named isolated world
  (`cmuxAutomation`) on a CSP eval-refusal: same DOM, no main-world CSP.
  Deviation: on those sites `browser.eval` runs isolated, so **page JS
  globals are invisible** (macOS sees them everywhere).
- ★ **Console/error capture from page load, on every site.** A
  document-start *user script* (CSP-exempt, eval-free) posts console and
  error events through a script message handler into a per-surface
  app-side buffer — so capture works even on strict-CSP sites and needs
  no arming call. macOS arms a `window.console` wrap lazily and therefore
  only sees entries logged after the first `console list`. (We record
  what the *page* logs; our own isolated-world automation output isn't
  captured.)

## Agents, notifications, control

- ✅ **Control socket + shared CLI** — the same `CLI/cmux.swift` as macOS,
  building unmodified on Linux; the app speaks the v1/v2 wire protocol.
- ✅ **Drive any pane** — `send` / `send-key` / `read-screen`
  (incl. `--scrollback`, `--lines`).
- ✅ **Attention pipeline** — bell + `cmux notify` + Claude Code
  Stop/Notification hooks → sidebar dots, a notifications page, and
  GNotification desktop delivery.
- ✅ **Closed-loop dogfooding** — `linux/scripts/dogfood.sh` spawns a
  headless QA agent *inside* the running app; it now streams the agent's
  live tool calls into the pane.

## Beyond macOS (★) — verified Linux-only

Small but real. These are genuine additions, not just different internals:

- ★ **`browser.identify`** — a v2 verb (surface/url/title for a browser
  pane) with no macOS counterpart.
- ★ **`needs_attention` in `workspace.list`** — Linux emits a per-workspace
  attention flag so agents poll bell/notification state in one call;
  macOS's workspace list has no such field.
- ★ **Browser-automation correctness fixes** that macOS's shared scripts
  still get wrong (documented as upstream candidates in PARITY):
  `browser.select` validates the option exists before assigning;
  `browser.dblclick` fires `click, click, dblclick` so onclick handlers
  run; `browser.press` inserts text for single printable keys;
  `browser.snapshot` accessible names honor `label[for]`/wrapping labels;
  `browser.frame.select` validates top-relative so sibling-frame switches
  work.
- ★ **W3C WebDriver automation** (`CMUX_WEBDRIVER=1`) — cmux answers
  WebKitGTK's automation handshake, so `/usr/bin/WebKitWebDriver` and the
  Selenium ecosystem can drive it. This buys **trusted input events**
  (`isTrusted: true`), which page JavaScript can never synthesize —
  measured on one page: WebDriver click → `isTrusted=true`, our JS verb →
  `isTrusted=false`. The driver gets an ephemeral profile, not your
  cookies. macOS cmux has no automation opt-in at all.
- ★ **Renderer resize fix** — the fork's macOS-oriented stale-frame replay
  froze GTK surfaces after a window resize; the Linux work Darwin-gated it
  (macOS unchanged), a fix the fork/ecosystem benefits from
  (`roadmap/05-ghostty-embed-hardening.md`, UPSTREAM.md).

## Known gaps vs macOS

The honest short list (full detail in PARITY.md): multi-window, several
focus-intent verbs (`surface.focus`, `browser.focus_webview`),
`pane.resize`/`break`/`join`, a command palette, sidebar metadata pills
(git branch / ports / status), divider-position persistence, and
`debug.*`. One known limitation of the Ghostty backend: panes in
never-selected background workspaces spawn their shell on first selection
(the eager-spawn gap).

Beyond the JS-injection layer, the things page JavaScript can never reach
— trusted input events, network interception, a real debugger,
cross-origin frames, CSP-proof console capture — are tracked as a decided
direction in `roadmap/06-webkit-native-automation.md`: adopt native
WebKitGTK APIs (WebDriver/BiDi, user scripts, Inspector), explicitly
*not* a CDP/Chromium engine swap.

---

Keep this file honest: when a feature lands, mark it ✅/★/⚙ and verify
"beyond macOS" claims against `Sources/` before asserting them — several
plausible-looking enhancements (find overlay, scrollback read) turned out
to be parity.
