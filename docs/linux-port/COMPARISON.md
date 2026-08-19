# Three-way feature comparison — cmux-adw · cmux (macOS) · cmux-tui

**Purpose.** Strategy instrument, not a tracker. This document compares the
three cmux implementations at the *concept* level to inform one future
decision: whether the Linux port should ever become a protocol frontend over
upstream's Rust core (`cmux-tui-core`) instead of carrying its own control
plane. Verb-level two-way parity stays in [PARITY.md](PARITY.md); the
prioritized work-down list stays in [GAPS.md](GAPS.md). Nothing here creates
work items by itself.

**Snapshot stamp.** Surveyed **2026-08-19** against:

| Column | Code | Commit | Date |
|---|---|---|---|
| **cmux-adw** (our Linux port) | branch `linux-port`, `linux/` | `fefbc69044` | 2026-08-18 |
| **cmux-macos** (original app) | upstream/main, `Sources/` + `CLI/` | `786a35d099` | 2026-08-18 |
| **cmux-tui** (Rust core + TUI) | upstream/main, `cmux-tui/` | `786a35d099` | 2026-08-18 |

cmux-tui is moving at ~30 commits/day (736 commits in August 2026 alone;
~1,255 since the `mux` → `cmux-tui` rename on 2026-07-09, project born
2026-07-06 as PR #7180). **Cells about cmux-tui rot in days, not months.**
Treat every claim as "true at the stamp"; refresh before relying on one.

**How to refresh:** `git fetch upstream` in the main checkout; re-read
`cmux-tui/docs/concepts.md`, `cmux-tui/spec/README.md`, and the diff of
`cmux-tui/docs/` + `cmux-tui/spec/` since the stamped commit; re-run the
evaluation build if toolchains moved (Zig pin in `cmux-tui/README.md`,
Rust pin in `cmux-tui/rust-toolchain.toml`); update the stamp. An
evaluation worktree pattern that works: `git worktree add ~/cmux-upstream
upstream/main` plus a detached ghostty worktree at upstream's pin
(see PROGRESS.md 2026-08-19 for the UCD.zip zig-fetch trap).

**Empirical basis.** Beyond doc reading, cmux-tui was built and run on this
Fedora host on 2026-08-19 (debug build, zig 0.16.0 + rustc 1.95): headless
server + noun-first CLI smoke green (`workspace create`, `workspace current
run`, `terminal list` with lifecycle/exit records, idempotent `server stop`
preserving topology), and the interactive TUI ran nested inside a cmux-adw
pane. It is real, working software, not a paper spec.

---

## 0. What each program actually is

- **cmux-macos** — a native Swift/AppKit/SwiftUI macOS application: GUI
  shell, control plane, terminal host (GhosttyKit), embedded browser
  (WKWebView), agent cockpit, all in one process. The product the port
  mirrors.
- **cmux-adw** — this port: the same product shape re-implemented natively
  for Linux (GTK4/libadwaita, VTE + embedded-Ghostty shim, WebKitGTK), with
  its own control plane speaking the macOS socket protocol via the shared
  `CLI/cmux.swift`.
- **cmux-tui** — a *different architecture serving an overlapping goal*: an
  authoritative Rust backend (`cmux-tui-core`) owning topology, terminals
  (parsed server-side with libghostty-vt), durability (SQLite + event
  journal), and remote access — with **frontends as clients**: the in-tree
  tmux-like TUI, an in-tree web frontend (xterm.js), and a **native macOS
  frontend developed in the separate private repo `manaflow-ai/cmux-lite`**
  (per `cmux-tui/frontends/README.md`). Public API `cmux.protocol/2` with
  seven generated SDKs; private frontend protocol v12.

**The single most decision-relevant fact of this survey:** upstream is
already building a native GUI frontend over the Rust core (cmux-lite), and
`spec/native-frontend.md` is written for a persistent Swift frontend with
multiple OS windows over one socket. The "GUI shell over cmux-tui-core"
slot that cmux-adw could occupy on Linux is a slot upstream itself is
actively filling on macOS. Watch item: whether cmux-lite eventually
*replaces* the monolithic macOS app. If it does, our parity target
(the monolith) becomes legacy and the Rust core becomes the product.

---

## 1. Object model

*What a user's work is made of, and what closing something means.*

- **cmux-macos:** Window → Workspace (sidebar entry) → Pane (split region)
  → Surface (tab in the pane's tab bar) → Panel (terminal/browser/viewer
  content). Workspace groups with anchor semantics. One split layout per
  workspace (plus the freeform Canvas mode). **A surface *is* its content:
  closing a terminal tab kills the process.**
- **cmux-adw:** same model 1:1 (minus multi-window and canvas); full
  workspace-group wire parity; AdwTabView tab strips per pane.
- **cmux-tui:** session → workspaces → **screens** → split-tree panes →
  tabs. Two concepts we don't have:
  1. **Screens** — tmux-window-like switchable layouts *within* one
     workspace (`Ctrl-b c/n/p/0-9`), including horizontally scrollable
     column screens with per-column split trees.
  2. **Placement vs resource** — a terminal is a *session-owned resource*;
     a PTY tab is only a *view placement* of it. Several tabs (or several
     frontends) can project one terminal; closing a tab/pane/screen/
     workspace detaches views only; only explicit `terminal.close` kills
     the process. Verified live in our smoke: an exited terminal remains
     listable with a typed exit record and zero placements.
  Also: stable `SplitId` divider identity, per-screen layout undo with
  stale-revision fences, most-recently-active pane focus fallback.

**Divergence:** cmux-tui's placement/resource split is the deep one — it
changes what "close" *means* across the whole verb surface and is the
mechanism that makes multi-frontend work. Screens are additive UI. Both
would be conceptual migrations for us, not feature ports.

## 2. Terminal engine

- **cmux-macos:** GhosttyKit embedded in-process via the macOS embedding
  API; rendering in-app (Metal-only); strict typing-latency discipline in
  repo rules.
- **cmux-adw:** two backends — embedded real Ghostty surfaces via our GTK
  shim (`ghostty_gtk_embed.h`, default) or VTE fallback. Rendering
  in-process, same architecture class as macOS.
- **cmux-tui:** **parse-once, view-many, server-side**: the backend is the
  only VT emulator (libghostty-vt — Ghostty's parser as a C library built
  with Zig, no Ghostty renderer); frontends receive either raw PTY bytes
  after a VT-state replay ("bytes" mode) or server-resolved styled
  rows/runs with damage deltas ("render" mode). Kitty graphics state is
  owned by the terminal runtime and survives attach/remote within replay
  budgets. TUI draws via ratatui + a vendored crossterm fork (restores
  Kitty CSI-u fields crossterm drops).

**Divergence:** all three sit on Ghostty's VT lineage, but ownership
differs: we and macOS embed the whole terminal (parser + renderer) in the
GUI process; cmux-tui splits parser (server) from renderer (any client).
For a hypothetical cmux-adw-as-frontend, the honest open question from the
first look stands, now sharpened: render mode has **no mouse/focus input
path yet** (`send-mouse`/`send-focus` are declared "required vNext
primitives" in `spec/frontends.md`), so a GUI frontend today would run
bytes mode and keep its own local VT — i.e. keep most of our current
terminal stack anyway.

## 3. Sessions & durability

- **cmux-macos:** versioned JSON snapshot (layout, cwds, bounded inline
  scrollback, browser URLs with emulated history); explicit "no live
  process checkpointing" contract; 17-agent auto-resume matrix; reopen-
  last-closed, History pane, layout templates.
- **cmux-adw:** same snapshot model, schema v3, with two deliberate
  improvements: out-of-band per-surface scrollback files (configurable up
  to unlimited) and native WebKitGTK session-state blobs (real back/forward
  after restart). Agent auto-resume landed 2026-08-18 (14-agent table,
  `debug.resume_plan` audit instrument).
- **cmux-tui:** a different league of ambition: **SQLite (WAL,
  synchronous=FULL, exclusive writer lease) plus a formally specified
  event-sourced session journal** — every semantic fact an immutable
  record, idempotency receipts in the same transaction, deterministic-gzip
  checkpoints of VT state by SHA-256, sealed segments, size pressure never
  silently deletes history, raw keystrokes/paste secret-by-default and
  never journaled. Detach/attach is native (tmux model). Sobering caveat
  from its own migration table: **live restoration application is still
  "Pending"** — the journal records everything; replaying it into a live
  session isn't wired yet. Our humble JSON snapshot *restores today*;
  their journal is architecturally superior but not yet closed-loop.

**Divergence:** biggest maturity inversion in the survey — strongest spec,
weakest shipped restore. Their journal spec is worth reading regardless of
the frontend decision; it is the strongest durability design in the family.

## 4. Multi-client / multi-frontend

- **cmux-macos:** none in the multiplexer sense. Multi-window yes; iOS
  companion streams terminals; remote tmux mirroring makes *it* a client
  of tmux. One app owns the session.
- **cmux-adw:** none; single window today. Our instance multiplicity
  (daily/dev/scratch) is developer infrastructure, not multi-client.
- **cmux-tui:** the raison d'être. Focus/scroll/selection are
  frontend-local by contract; shared state is only "compatibility
  defaults". Frontend projections (personal/shared, schema-versioned)
  store per-frontend presentation. Geometry has one explicit owner per
  terminal (others crop/pan). Attach leases, mutation-identity dedupe,
  subscription overflow contracts. Web frontend in-tree; native macOS
  frontend in cmux-lite (private).

**Divergence:** this is the axis where cmux-tui simply has a capability
class the other two lack entirely — and it's the capability our port would
be buying in a frontend future. The detach/attach + placement model is
what "leave the office, reattach from the laptop" needs.

## 5. Remote & machines

- **cmux-macos:** rich and product-shaped: `cmux ssh` remote workspaces
  with the Go relay daemon (browser traffic proxied through the remote
  network, reverse CLI tunnel), detachable remote PTYs, cloud VM family,
  iOS pairing over Iroh.
- **cmux-adw:** deliberately nothing (out of scope per CONCEPTS.md).
- **cmux-tui:** the deepest of the three and security-engineered to an
  unusual standard: Noise-authenticated device enrollment (invitation
  files, owner-approved, revocable), transports Unix/SSH/WebSocket/Iroh/
  relays (native Rust relay + Cloudflare Durable Objects), lane QoS
  (interactive/control/bulk/tunnel), machine rail in the TUI,
  `machine-agent` outbound-only registration with cmux.cloud, bearer-token
  loopback HTTP API. Explicit trust model: one daemon = one OS user;
  workspaces are navigation, not isolation.

**Divergence:** upstream's serious remote investment now clearly lives in
the Rust core, not the Go relay. If Linux ever needs a remote story,
building it ourselves would be repeating this work at a fraction of the
rigor; consuming it via the core is the only realistic path to parity.

## 6. Browser panes

- **cmux-macos:** WKWebView embedded in-process; ~140-verb automation
  grammar; profiles, passkeys, downloads, focus/design modes.
- **cmux-adw:** WebKitGTK embedded in-process; 92 shared v2 browser/core
  methods implemented, several correctness fixes macOS lacks, plus
  Linux-only additions (WebDriver trusted input, full-page screenshots,
  console capture v2, ephemeral profiles, navigation barrier).
- **cmux-tui:** **attach-only CDP**: never launches or owns a browser; a
  separate `cmux-browser` product publishes its DevTools endpoint and
  tab→target map; the TUI paints screencast PNGs via kitty graphics with a
  pointer-frame-guard protocol (clicks only against acknowledged frames);
  agent automation delegates to Vercel's `agent-browser` through a
  provider adapter, not an own verb grammar.

**Divergence:** three-way fork, and ours is arguably the strongest column:
real embedded engine + the deepest scripted automation surface. In any
frontend future this is the subsystem we would keep, not adopt — cmux-tui
deliberately outsources what we own.

## 7. Control API, CLI & SDKs

- **cmux-macos / cmux-adw:** shared surface by design — one v2 JSON-lines
  socket protocol, shared `CLI/cmux.swift` (verb-first, `workspace:N`
  refs), guarded by our capabilities-sweep tripwires. No SDKs; blessed
  pattern is raw socket + JSON.
- **cmux-tui:** two-tier: public `cmux.protocol/2` (124 transported
  operations in a machine-readable catalog; noun-first CLI; typed
  selectors with `selector.ambiguous`-style stable error codes; mandatory
  idempotency keys; optimistic revisions; redaction of interactive input
  from durable fingerprints) over private frontend protocol v12. **Seven
  generated SDKs** (Rust/Python/TS/Go/Java/C++/Zig) with fake-server and
  live-server conformance suites; deterministic codegen (each language
  rendered twice, byte-equality required, CI fails on drift).

**Divergence:** they built the contract discipline we approximate with
sweep scripts, and took it much further (CI compares spec inventory
against the Rust enums — even context-menu actions are a versioned
contract). Their CLI would also collide with ours: same binary name
`cmux`, different grammar. See §13.

## 8. Input & keyboard

- **cmux-macos:** modifier chords (⌘-family), fully rebindable with
  two-key chords and VS Code-style `when` clauses, command palette,
  shortcut editor UI.
- **cmux-adw:** hardcoded bindings (19 of macOS's 28 commands), no
  rebinding yet (open gap), no palette.
- **cmux-tui:** tmux prefix model (`Ctrl-b`) + modeless Alt/Super layers;
  ~60 rebindable actions via config chords; Kitty keyboard protocol
  enabled to see Super in terminals; vendored crossterm fork to keep
  CSI-u fidelity; `Ctrl-b ?` action-catalog modal. Zellij-style modal
  layers are an explicit non-goal.

**Divergence:** mildly embarrassing for us: the *TUI* has full shortcut
rebinding while our GUI port doesn't. Their `Ctrl-b ?` catalog modal is
also the same idea as our queued GtkShortcutsWindow answer.

## 9. Configuration

- **cmux-macos:** `~/.config/cmux/cmux.json` (JSONC, schema, best-effort
  on unknown keys, palette schema-error row), project `.cmux/` configs
  behind a trust flow, live reload.
- **cmux-adw:** same file, `linux` section (small key set), env >
  file > default, live reload incl. Ghostty propagation.
- **cmux-tui:** **`~/.config/cmux/cmux-tui.json` — the same directory as
  ours.** Strict typed sections: an unknown key invalidates the document
  and falls back to defaults entirely (opposite error philosophy to
  macOS's best-effort parse). Theme seeds selection colors from the
  user's *Ghostty* config. Hook manifests deliberately rejected from the
  config file (journal API is the only install path).

**Divergence:** philosophical split on error handling (strict-reject vs
best-effort) and a literal cohabitation hazard (§13).

## 10. Platform integration & notifications

- **cmux-macos:** deep macOS citizenship — desktop notifications with a
  rich lifecycle contract and JSON policy hooks, Dock badge, menu bar,
  Sparkle, drag-and-drop UTTypes, localization pipeline (en/ja).
- **cmux-adw:** GNOME citizenship — GNotification desktop delivery with
  the full three-rule suppression contract, libadwaita idioms over macOS
  cosplay (recorded 🎨 deviations), Flatpak packaging pending.
- **cmux-tui:** a terminal citizen: **no desktop notifications at all** —
  notifications are in-TUI markers/colors plus protocol events; host
  integration limited to what escape sequences allow (OSC 52 clipboard,
  OSC 22 pointer, kitty graphics/keyboard). macOS + Linux today,
  **Windows via ConPTY planned as phase 2**. Ships via npm/PyPI
  (`npx cmux`). English+Japanese locales (partial catalog).

**Divergence:** desktop integration is precisely what a *frontend* is for
in their architecture — the core deliberately doesn't do it. Our
GNotification/attention pipeline would be a contribution a Linux frontend
brings, not something the core makes redundant. Note also: cmux-tui on
Windows (phase 2) would leapfrog both native apps' platform coverage.

## 11. Agent integration

- **cmux-macos:** the agent cockpit is the product: wrapper-based Claude
  integration, 9-agent feed bridges, agent teams via tmux-compat shim,
  Vault transcript index, TextBox, diff viewer, hibernation, Task
  Manager, auto-naming.
- **cmux-adw:** hooks + feed verbs live (2026-08-18, shared engine),
  agent auto-resume, teams verified end-to-end, dogfood harness with
  standing consent, live-agent-display (ADR-0010). Missing the reading
  surfaces (Vault, diff/markdown viewers, TextBox).
- **cmux-tui:** agents are journal citizens: 9 hook providers (Claude,
  Codex, Gemini, Cursor, Grok, Hermes, OpenCode, Amp, Pi) feed typed
  records with exactly-once scheduling identities, parent/child agent
  relations with explicit evidence rules, `agent.report` projections,
  seccomp/sandbox fencing of hook processes, and 4-second hook timing
  budgets specified normatively. Terminal-side: `attach --terminal` for
  driving one PTY, `workspace run` receipts. Browser agents delegate to
  agent-browser.

**Divergence:** three shapes of the same instinct — macOS builds cockpit
UI, we build closed-loop dev harnesses, cmux-tui builds audited event
infrastructure. The journal's agent model (typed provenance, causal
chains) is stronger than the feed JSONL both native apps share.

## 12. Maturity & engineering discipline

- **cmux-macos:** mature shipped product (0.64.x, Sparkle, ~weekly
  releases, localization audits, regression-test policy).
- **cmux-adw:** five weeks old, phases 0–5c done, self-hosting since
  2026-07-16, honest two-way parity ledgers, suite-guarded (feed-smoke 24,
  agent-resume 11, dock, tmux-compat, browser suites), single developer +
  agents.
- **cmux-tui:** six weeks old, ~30 commits/day, and paradoxically the most
  formally disciplined codebase in the family: spec-in-same-commit rule,
  machine-readable operation/inventory catalogs enforced against code by
  CI, 7-SDK conformance, hosted-CI-only build policy, versioned protocol
  ladders with explicit deprecation windows — while still carrying live
  inconsistencies ("Proposed Commands" that other specs treat as
  implemented, open v7 render questions, restoration Pending). Discipline
  of a platform, age of a prototype.

**Divergence:** the investment signal is unmistakable: upstream is
building cmux-tui like *infrastructure others will depend on* (SDKs,
protocol promises, provenance-verified releases), while the macOS app is
built like a product. That asymmetry is the strongest hint about where
the architecture is heading.

## 13. Naming & cohabitation hazards (practical, today)

Three products share one name and one config directory:

- **CLI:** cmux-tui's packaged CLI is also `cmux` (`npx cmux`). On any
  machine with our port, `npm install -g cmux` would shadow or collide
  with `~/.local/bin/cmux`. Source builds are safe (binaries `cmux-tui`,
  `cmux-tui-hook`); avoid the npm global install on dev machines.
- **Config dir:** `~/.config/cmux/` holds our `cmux.json` and their
  `cmux-tui.json`. No key overlap today, but tooling that treats the
  directory as "cmux's config" must not assume one owner.
- **Env namespaces:** verified disjoint at the stamp — cmux-tui reads
  `CMUX_TUI_*` / `CMUX_MUX_*` / `CMUX_RELAY_*` and never our
  `CMUX_SOCKET_PATH` / `CMUX_WORKSPACE_ID` / `CMUX_SURFACE_ID`.
- **Sockets:** theirs at `$XDG_RUNTIME_DIR/cmux-tui-<uid>/<session>.sock`;
  ours at `/tmp/cmux*.sock` + XDG state. Disjoint.

---

## What a frontend future would gain / must preserve / must resolve

**Gain (capabilities we would inherit rather than build):**
detach/attach and multi-frontend sessions; the placement/resource terminal
model; screens; the entire remote/machines stack (Noise enrollment, Iroh,
relays, machine-agent, cloud); journal-grade durability once restoration
ships; seven SDKs + a stable public protocol for third parties; Windows
reach (phase 2); the spec/CI contract discipline.

**Preserve (what cmux-adw/macOS have that the core deliberately lacks):**
native GUI shell and GNOME/desktop citizenship (notifications, attention
tiers, drag-and-drop, Flatpak); the embedded real browser with our
automation grammar, profiles, and WebDriver trusted input; embedded
Ghostty *rendering* (GPU terminal in a GUI window — the core only exports
parsed state); workspace groups and the sidebar UX; the macOS-compatible
socket/CLI surface our skills, harnesses, and users depend on; the
closed-loop dogfood machinery.

**Resolve (open questions that decide feasibility — each is checkable):**
1. **Input in render mode** — `send-mouse`/`send-focus` are vNext; until
   they exist, a GUI frontend runs bytes mode with a local VT, keeping
   most of our terminal stack anyway. Watch `spec/frontends.md`.
2. **Model mapping** — window/workspace/pane/surface vs
   session/workspace/screen/pane/tab+terminal: can our verb surface be
   projected onto theirs without breaking every existing consumer?
   (Their own "compatibility tree" suggests they've kept legacy
   projections cheap so far.)
3. **Protocol churn** — v12 in six weeks; `cmux.protocol/2` is
   "prelaunch". Building against it today means chasing; the signal to
   move is upstream declaring it stable (watch `spec/README.md`
   versioning section and the cmux-lite repo going public).
4. **Browser philosophy** — attach-only CDP vs our embedded WebKitGTK is
   a genuine fork; a Linux frontend would either keep our browser outside
   their model (as another "provider"?) or lose our strongest subsystem.
5. **cmux-lite's trajectory** — if upstream's own native frontend replaces
   the monolith, parity-with-the-monolith becomes parity with a legacy
   target and this decision makes itself. Single highest-value watch item.

**Recommendation at the stamp (2026-08-19):** keep building the port on
the macOS parity track — it ships today, self-hosts, and its strongest
subsystems (browser, desktop integration, dogfood loop) are exactly the
ones a frontend future would keep. Do not start a frontend rewrite while
render-mode input is missing and the public protocol is prelaunch. Do:
re-survey monthly (or on any cmux-lite news), read `spec/session-journal.md`
before designing any future durability work of our own, and treat every
new large port investment through one filter: *"would this survive a move
onto the core?"* — favoring work in the Preserve list over work that
duplicates the Gain list.

---

## Appendix A — CmuxLite: a worked example of a native frontend (frozen public snapshot)

The cmux-lite native frontend (§0) is private, but it spent its first five
days **in-tree in the public repo**: `cmux-tui/frontends/swift/CmuxLite/`
from 2026-07-13 (`a0c177ecc4`, "minimal Swift libghostty frontend") to
2026-07-18 (`ecebdbb64b`, PR #8305 "move CmuxLite out of tree"), 19
public commits. The last public state is recoverable:

```sh
git -C ~/cmux-upstream archive ecebdbb64b^ cmux-tui/frontends/swift/CmuxLite \
  | tar -x -C <dest> --strip-components=4
```

A full structural read of that snapshot (local copy:
`~/cmux-lite-snapshot/`, surveyed 2026-08-19) yields the best available
empirical answer to *"how much work is a native GUI over cmux-tui-core?"*

**Scale.** 9,252 LOC / 111 Swift files: AppKit app 2,736 · protocol core
4,561 · smoke harness 415 · tests 1,508 (46 tests, core only). **Zero
external dependencies** — Foundation/AppKit/Network/CoreText, no
GhosttyKit, no packages. Swift 6 actors throughout, macOS 14+, dark-only,
single window, no menu bar.

**Architecture at the freeze (protocol v7+):**

- **Server-rendered only.** Attaches `mode:"render"`; the client never
  sees an escape sequence. The entire styled-terminal renderer — 7 SGR
  attrs, 5 underline styles, 3 cursor shapes, blink, retina-exact cell
  alignment via a kerning trick — is **418 lines** (`CmuxRenderView`)
  plus ~80 of font metrics; delta application is **83 lines**. This is
  the payoff of the core's parse-once model, quantified.
- **16 wire commands total** (identify, set-client-info, list-workspaces,
  subscribe, new-workspace/screen/tab, split, set-ratio, close-surface,
  select-tab, attach-surface, send, send-key, read-scrollback,
  resize-surface). Navigation is client-local by design — it never sends
  select-workspace/screen (test-asserted). No tree deltas: four event
  names (`tree-changed`, `layout-changed`, `surface-exited`,
  `title-changed`) each trigger a full `list-workspaces` re-snapshot and
  AppKit view rebuild — correct by construction, the design's biggest
  scaling shortcut.
- **One connection per visible pane**, with generation counters guarding
  every async callback against staleness; pane view controllers cached
  across snapshot rebuilds.
- **Where the effort actually went:** not rendering — *protocol
  correctness*. Resize left the most scar tissue (a dedicated echo-
  suppression policy with a documented rule, 100 ms debounce with
  cancellation, all geometry in backing pixels, 7 tests); split-ratio
  needed optimistic commit with request-id rollback and a subtle
  (pane,direction) divider-target search. One empirically-tuned liveness
  hack (`wakePeer` sending **two** unsolicited WebSocket pongs after each
  response) marks a real backend bug they worked around.
- **Ghostty theming confirmed**: it shells out to `ghostty +show-config`
  (2 s deadline) to seed font and colors — and parses palette/selection/
  cursor fields **with tests but zero consumers**: scaffolding for
  selection rendering, frozen exactly where the public work stopped.

**Omissions at the freeze** (what five days had not reached): no
reconnect (a dropped socket is a dead window), no text selection or copy,
no mouse reporting to the PTY (vim/tmux mouse dead — the §"resolve" #1
render-mode input gap, observed biting a real frontend), no browser panes
(deliberately filtered, with a test), no notifications, no config, no
multi-window. Localization en/ja, partial.

**What this changes in our assessment:**

1. **The frontend-cost estimate now has a number:** ~9 kLOC for a usable
   splits/tabs/screens/workspaces terminal frontend, of which only
   ~3 kLOC is genuinely hard logic (session orchestration, resize/ratio
   correctness, transport) — *provided the backend does all VT work*.
   The GUI itself is the cheap part (2.7 kLOC).
2. **CmuxLiteCore is largely platform-free and Sendable** — value types,
   render model, scrollback windowing, key encoding, layout/geometry
   math have no AppKit dependency. A Linux frontend could reuse most of
   the 4.5 kLOC core outright (same AGPL ecosystem as our fork),
   swapping the two NWConnection transports (~250 LOC) for POSIX
   sockets. The moat is smaller than the §"resolve" section assumed.
3. **The render-mode input gap is confirmed in practice, not just spec:**
   upstream's own frontend shipped its public phase without mouse
   support. Watch `send-mouse`/`send-focus` (spec/frontends.md) — their
   arrival likely coincides with cmux-lite maturing.
4. The recommendation in the main document stands unchanged — but if the
   frontend path is ever taken, the starting point is now concrete:
   study `CmuxFrontendSession` (718 LOC) and `CmuxResizePolicy` first;
   they encode the two hardest lessons upstream already paid for.

---

*Sources: cmux-tui `docs/` (10 files) + `spec/` (18 files) + README/
AGENTS/Cargo at the stamped commit; our PARITY.md / FEATURES.md /
CONCEPTS.md / MENTAL-MODEL.md / GHOSTTY-SHIM.md / UX-PARITY.md /
MACOS-UX.md / GAPS.md / CATCHUP.md / kb/; live build + smoke on Fedora 43,
2026-08-19 (PROGRESS.md entry of that date); CmuxLite frozen snapshot
structural read, 2026-08-19 (Appendix A).*
