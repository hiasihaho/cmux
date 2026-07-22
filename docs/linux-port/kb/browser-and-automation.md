# Embedded browser and automation — beyond the verb list

> Sources: https://cmux.com/en/docs/browser-automation, /en/docs/configuration
> (browser.*), /en/docs/ssh (remote routing), /en/blog/passkey-auth,
> /en/docs/changelog (0.63.0, 0.64.x). Crawled 2026-07-22 via the port's own browser.
> The verb-by-verb port status lives in docs/linux-port/PARITY.md — not repeated here.

## Automation grammar (contract shape)

Target positionally or with `--surface` (`cmux browser surface:2 url` ≡
`cmux browser --surface surface:2 url`). Command index by category:

- **Navigation/targeting**: identify, open, open-split, navigate, back,
  forward, reload, url, focus-webview, is-webview-focused, zoom, focus-mode,
  react-grab, devtools (toggle|console), history clear --force.
- **Waiting**: wait --load-state|--selector|--text|--url-contains|--function
  [--timeout-ms].
- **DOM**: click, dblclick, hover, focus, check, uncheck, scroll-into-view,
  type, fill --text, press, keydown, keyup, select, scroll --dx/--dy
  [--selector]. Mutating actions accept `--snapshot-after` for cheap
  verification.
- **Inspection**: snapshot [--interactive --compact --selector --max-depth],
  screenshot --out, get title|url|text|html|value|attr|count|box|styles,
  is visible|enabled|checked, find role|text|label|placeholder|alt|title|
  testid|first|last|nth, highlight.
- **JS**: eval, addinitscript, addscript, addstyle.
- **Frames/dialogs/downloads**: frame "<selector>" / frame main;
  dialog accept ["text"] | dismiss; download --path --timeout-ms.
- **State**: cookies get/set/clear, storage local|session get/set/clear,
  state save/load <file> (full browser state snapshot for persist/restore
  workflows).
- **Tabs/logs**: tab list/new/switch <n|surface:N>/close; console list/clear;
  errors list/clear.

Documented patterns: navigate→wait→snapshot→get; form-fill + `wait --text` +
`is visible`; failure artifacts (console list, errors list, screenshot,
snapshot); state save/load around auth.

## Authentication surface (the differentiator)

- **Passkeys / WebAuthn / FIDO2 / Touch ID / hardware keys** work inside
  browser panes (0.64.0; inside-out signing keeps the notarized build
  compatible with macOS auth services).
- **`cmux browser import`**: wizard imports cookies, history, and sessions
  from "Chrome, Arc, Brave, Firefox, Safari, and 20+ browsers", per-profile
  selection, "so you're already logged in." Purpose per blog: agents testing
  authenticated local apps without leaving cmux.
- HTTP basic-auth prompt (#2500); invalid-TLS proceed-anyway (#3711);
  insecure-HTTP host allowlist defaults to localhost family.

## Modes layered on the webview

- **Focus mode** (⌥⌘↩, Esc Esc exits): page gets first claim on shortcuts;
  strips surrounding chrome.
- **Design mode** (⌃⌥⌘D, 0.64.20): visually edit pages, annotate elements,
  "hand the annotated changes straight to an agent to implement."
- **React Grab** (⌘⇧G; pinned version `browser.reactGrabVersion`): component
  picking for React apps.
- DevTools ⌥⌘I; JS console ⌥⌘C; zoom ⌘=/⌘-/⌘0; hard reload ⌘⇧R.

## Routing and lifecycle policy (settings-driven)

Terminal links open in the embedded browser (`openTerminalLinksInCmuxBrowser`,
`interceptTerminalOpenCommandInCmuxBrowser` for `open http…`);
`hostsToOpenInEmbeddedBrowser` allowlist vs `urlsToAlwaysOpenExternally`;
window.open popups share OAuth context; bare `window.open(_blank)` becomes a
tab; hidden webviews discard page memory after `hiddenWebViewDiscardDelaySeconds`
(300 s default) and restore on show; audio-playing indicator + tab mute;
downloads to Downloads or save-panel (`askWhereToSaveDownloads`); search from
the address bar via 17 named engines or custom template.

## Remote workspaces

In `cmux ssh` workspaces, browser panes route **all HTTP/WebSocket traffic
through the remote network** (SOCKS5/HTTP CONNECT over the relay daemon's
stdio channel) — `localhost:3000` is the remote dev server, no port
forwarding; per-connection isolated cookie stores.

## Port relevance

PARITY already tracks 92 shared verbs. Facts here that PARITY/CONCEPTS lack:
the auth story (passkeys + import) as the *reason* agents can test real apps;
design mode/React Grab as agent-handoff features rather than devtools sugar;
the state save/load workflow; discard/restore memory policy; and the
routing-policy settings family a Linux browser stack would eventually need.
