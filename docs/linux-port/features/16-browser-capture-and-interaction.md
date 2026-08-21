---
title: Browser capture & interaction history
area: browser
kind: product
mac: partial
linux: partial
verbs: browser.screenshot
---

# 16 — Browser capture & interaction history

Two threads that came out of one evening's questions (2026-08-20/21) and
should not be re-derived: **why full-page capture cannot simply be made
to work on long documents**, and **what a deep interaction history would
take**. Written to be picked up cold — every claim below is measured, and
the measurements name the conditions that produced them.

Related: [GAPS.md](../GAPS.md) rows (capture ceiling, `browser.viewport.set`),
[PARITY.md](../PARITY.md) browser rows, PROGRESS 2026-08-21.

---

## Part A — full-page capture

### Already fixed (do not redo)

- **`--full-page` never reached the server** (`02cae5eb3c`). The flag had
  been in CLI help since 2026-07-21 and the server honoured `full_page`
  all along (`WEBKIT_SNAPSHOT_REGION_FULL_DOCUMENT`), but the CLI never
  parsed it — every "full page" capture was silently a viewport shot.
  Red-first cover in `browser-navigation-smoke` (tall fixture + height
  assertion).
- **Captures could hang forever** (`14da67ea90`+). No server-side
  deadline existed; a snapshot that never calls back waited indefinitely.
  Now a one-shot guard: callback vs 20s deadline, exactly one answers,
  timeout reply names the cause.

### The ceiling, and why it is not a bug we can patch

A screenshot must exist as **one image**. GTK renders through the GPU by
default, and GPU textures have a hard per-side maximum — **16384 px** on
this host (`glxinfo -l | grep GL_MAX_TEXTURE_SIZE`, AMD Radeon 8060S).
It is a driver/hardware ceiling, not a memory one.

Measured 2026-08-21 (sibling session ws:16, real display, DPR 2):

| Page | CSS px tall | Device px @2x | Result |
|---|---|---|---|
| purpose-built fixture | 3,000 | 6,000 | 1150×6000 PNG, content verified pixel-sampled, scroll-invariant |
| Wikipedia *Cuneiform* | 41,382 | ~82,700 | **no output, no error, >120s** |
| Wikipedia *Ugarit* | 34,740 | ~69,500 | same territory |

Counter-measurements from a headless probe (Xvfb, **software** GL):
40k, 100k, and 3000×40000 (120 Mpx, ~480 MB raw) all captured in
seconds. **Software rendering has no texture ceiling** — which is why
this cannot reproduce in CI and why "cannot reproduce" was the wrong
conclusion for an hour. *Renderer, not size, is the variable.*

### Options

| Approach | Mechanism | Cost / caveats |
|---|---|---|
| **Tiling** (recommended) | scroll → capture viewport-sized shots → stitch | Works on ANY renderer at ANY length; tiles stay small. Must save/restore scroll; sticky/fixed headers repeat per tile and need suppressing during capture; seam handling. Bonus: scrolling triggers lazy-loaded images a single native capture misses |
| **PDF print path** | `webkit_print_operation` → PDF → rasterize (poppler), optionally in tiles at any DPI | No texture limits at all; gives text-selectable output as a side effect. Costs pagination artifacts (page breaks mid-content) |
| **Software snapshot** | force cairo/llvmpipe for the capture | Removes the ceiling, but the renderer is chosen at surface-realize time — **not selectable per call** through `webkit_web_view_get_snapshot`. A global switch would degrade all browsing/terminal rendering. Bounded by RAM instead (2300×82,700×4 ≈ 760 MB raw). Note: software **GL** is verified to 100k px; **cairo specifically is NOT verified** and has its own limits in some builds |
| **Clamp** | capture the first N px, report truncation | Trivial, honest, rarely what was wanted |

### Recommended order

1. **Pre-flight guard** — measure `scrollWidth × scrollHeight × dpr`,
   compare against the ceiling, answer `invalid_params` with the max
   **immediately** (the sibling session's ask, and better than the 20s
   timeout, which is a backstop rather than an answer).
   **This is not throwaway work:** that comparison IS the decision
   function tiling needs ("one native capture, or tile?"). Today it
   returns an error; later the same branch routes to the tiler.
   Ceiling source: conservative constant 16384 with an env override, or
   probe `GL_MAX_TEXTURE_SIZE` once at startup.
2. **CLI silent-fallback fix** — asking for a background-workspace
   surface returned a plausible PNG *of a different visible pane*
   instead of surfacing the server's `invalid_state`. Never answer a
   different question than the one asked.
3. **Payload honesty** — return `width_css`, `height_css`, `dpr`
   alongside the PNG. Device-vs-CSS pixels burned two sessions in one
   night (a "1150×1560" report that was 575×780 CSS; a conflated
   "6000×404" from mixing two instances' measurements).
4. **Tiling** — the actual capability.
5. **`browser.viewport.set`** — unimplemented here (`unknown_method`)
   though macOS has it and agents advise using it. Also gives tiling a
   clean way to normalize tile size.

### Regression assertions worth keeping

- full-page height > viewport height on a tall fixture (landed).
- **scroll-invariance**: capture at `scrollY=0` and `scrollY=1500`,
  assert byte-identical output (sibling session's idea — sharper than
  the height check, and would catch a silent scroll-and-stitch
  regression).
- content sampling, not just dimensions: decode the PNG and sample a
  pixel every N rows against declared block colours.

---

## Part B — deep interaction history

**The question:** can the browser record what the human did — navigation
steps, clicks, timings — deeply enough that an agent can answer *"look
at the last 5 steps of this UX flow; can we improve it?"*

**The answer: yes, and most of the plumbing exists.** We already inject a
script at document-start through WebKit's user content manager and
receive messages on a registered handler — that is how console capture
works (`BrowserAutomation.swift`, `consoleMessageHandlerName`). An
interaction recorder is the same channel with a richer payload.

### What to capture, and where it comes from

| Signal | Source |
|---|---|
| clicks with element identity | injected script; reuse the snapshot `ref` scheme so refs line up with `browser snapshot` |
| SPA navigations | `pushState`/`replaceState` hooks — these never fire `load-changed`, so app-internal steps are invisible without them |
| pointer positions | `clientX/clientY` in JS (page-space, survives scrolling) — **not** GTK widget coordinates, which need scroll/zoom correction |
| load timings | Navigation Timing + `PerformanceObserver`: TTFB, DOMContentLoaded, load, LCP per step |
| per-resource detail (optional) | `resource-load-started` on the web view |
| form interaction | field **identity** only — see privacy |

### Privacy posture (non-negotiable design constraints)

- **Identity and timing, never values.** No keystrokes, no field
  contents by default. Same posture as socket-input tagging, which
  records surface id and byte count and never content.
- **Opt-in per surface, with a visible indicator.** A browser that
  silently records interaction is a different product than a terminal
  that types for you.
- Redaction on persistence, as the feed already does for tool payloads.

### Shape

Per-surface ring buffer (bounded), a `browser.interactions --last N`
verb, and optionally the feed as durable storage — the workstream store
already handles exactly this event shape. Pair each step with an
optional snapshot so a model reasons about the DOM the human saw rather
than a re-fetch.

### Open questions

- Cross-origin iframes: the injected script runs per-frame if
  configured; message handlers need frame awareness.
- Cost of an always-on recorder (CPU per event, buffer memory).
- Retention: session-scoped, or persisted across restarts like
  scrollback?
- Does the ref scheme stay stable enough across DOM churn to be the
  identity key, or does the recorder need its own stable-selector
  strategy?

---

## Why this file exists

Both threads were answered in conversation on 2026-08-20/21 and would
otherwise live only in a session export. The capture ceiling in
particular is the kind of finding that gets rediscovered expensively:
it does not reproduce headless, it looks like a hang rather than a
limit, and the obvious fix (force software rendering) is unavailable
per-call.
