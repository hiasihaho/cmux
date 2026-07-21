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
  cookies. The driver's view is adopted as a **real cmux pane**, so the
  human watches automation happen and cmux's own verbs (snapshot, get
  text, console capture) address the very same surface — trusted input
  and rich inspection on one pane. macOS cmux has no automation opt-in at
  all.
- ⚙ **Find-in-page in browser panes** (Ctrl+Shift+F, or `cmux browser
  find-in-page`). WebKitFindController behind a GTK find bar: match
  counter, next/previous with wrap, case-sensitive toggle. Parity with
  macOS's per-pane find (`Sources/Find/SurfaceSearchOverlay.swift`); what
  Linux adds is that the *same* controller is socket-drivable, so an agent
  and the human highlight identically instead of via parallel paths.
- ★ **`cmux search <query>` — text search across every pane at once.**
  One query spans terminal panes (screen/scrollback text) and browser
  panes (rendered `innerText`), returning per-hit `surface_ref` /
  `workspace_ref` / `pane_ref` under `--json` so an agent can find the
  pane showing an error and then act on it. Filters: `--workspace`,
  `--kind`, `--regex`, `--case-sensitive`, `--scrollback`. macOS cmux has
  per-pane find (`Sources/Find/`) but no cross-pane search verb.
  Deliberately separate from interactive find-in-pane, which is a
  different feature with a different engine.
- ★ **Native browser history across restarts.** Session v3 persists
  WebKitGTK's own `webkit_web_view_get_session_state()` blob alongside the
  portable URL list, so a restored browser pane has a *real* back/forward
  list — `back`/`forward` genuinely navigate after a restart. macOS stores
  history URLs too but has to emulate navigation with shadow stacks
  (`restoredBackHistoryStack`), because WKWebView cannot rebuild a list
  from URLs. The blob is never load-bearing: if a future WebKit rejects
  it, the portable fields still restore the pane.
- ⚙ **Per-pane tab strips (AdwTabView).** A pane holds several surfaces
  behind a tab bar that auto-hides when there is only one, and popups open
  as tabs rather than splits — three popups leave the pane at full size
  instead of shredding it into slivers. Parity with macOS, where Bonsplit
  panes carry their own tabs; the Linux model was MVP'd at one surface per
  pane until now.
- ⚙ **Popups become panes.** `window.open()` and `target="_blank"` open a
  browser tab in their opener's pane, sharing the opener's web process so
  `window.opener` keeps working — instead of being silently dropped (the
  WebKitGTK default emits no `create` signal at all, so nothing happened).
  **Parity, and macOS's version is currently richer**: its
  `BrowserPanel.webView(_:createWebViewWith:…)` also weighs middle-click
  intent, modifier flags and open-externally rules to decide new-tab vs
  new-window, none of which the Linux path does yet. What Linux adds is a
  per-opener burst budget (5 per 10s), needed because enabling popups
  turns the popup blocker off.
- ⚙ **Web Inspector in a cmux pane** (`cmux browser inspect`). Full
  DevTools — elements, network, debugger, console — hosted as a real cmux
  split you can move and close like any other pane, via public WebKitGTK
  API. Parity in capability, not a Linux-only feature: macOS cmux also has
  DevTools (`BrowserPanel.toggleDeveloperTools`, through WKWebView's
  private `_inspector` selectors); what differs is that theirs is WebKit's
  own inspector presentation and ours is a pane. Reports `attached`
  honestly, because WebKit places the widget asynchronously and the split
  can land while the embed is still pending.
- ★ **`browser screenshot --full-page`.** Captures the whole document
  (`WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT`) instead of just the visible
  viewport, so content laid out wider or taller than the pane is not
  silently cut off — measured 408x704 vs 980x1202 on the same pane.
  macOS's `BrowserPanel.takeSnapshot` uses a default
  `WKSnapshotConfiguration` (visible viewport) and exposes no equivalent
  flag. Viewport remains the default on both.
- ★ **Navigation barrier on `goto`/`back`/`forward`/`reload`.** The verb
  holds its response until the new document is committed, so a following
  `eval`/`wait`/`snapshot` cannot read the page you just navigated away
  from. macOS has the same latent race (`v2BrowserNavigate` calls
  `navigateSmart(url)` and returns `.ok` immediately), so this is a real
  divergence, not a port artifact — measured 2 stale reads in 12 against a
  live site before the fix, and 20/20 stale against a deliberately slowed
  local server. Optional `--wait-selector`/`--wait-function`/
  `--wait-load-state` chain onto the same barrier atomically; `--no-wait`
  restores the old fire-and-forget behavior. Regression test:
  `linux/tests/browser-navigation-smoke.sh`.
- ★ **Renderer resize fix** — the fork's macOS-oriented stale-frame replay
  froze GTK surfaces after a window resize; the Linux work Darwin-gated it
  (macOS unchanged), a fix the fork/ecosystem benefits from
  (`../../roadmap/05-ghostty-embed-hardening.md`, UPSTREAM.md).

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
direction in `../../roadmap/06-webkit-native-automation.md`: adopt native
WebKitGTK APIs (WebDriver/BiDi, user scripts, Inspector), explicitly
*not* a CDP/Chromium engine swap.

---

Keep this file honest: when a feature lands, mark it ✅/★/⚙ and verify
"beyond macOS" claims against `Sources/` before asserting them — several
plausible-looking enhancements (find overlay, scrollback read) turned out
to be parity.
