# Catch-up — start here (living document)

Last updated: **2026-08-19 late** (deep 2-way parity audit: one month of
upstream drift — 4,067 commits, 0.64.20/21/22 — mined by three parallel
source readers into **DRIFT-2026-08.md**; PARITY gained a baseline note,
GAPS gained 5 Now + 4 Next rows incl. the upstream-merge-#2 umbrella.
Fixed same-session: 7-method capabilities advertise drift (feed.* +
debug.resume_plan; sweep green, shim build green — needs promote).
Sharpest edges: group `delete` is now non-destructive upstream and
anchor-close PROMOTES (we implement the old destructive contracts);
destructive verbs fail closed on stale ids (#9422); `feed.push` id-less
form wants NO reply; `equalizeSplits` silently rebound; Dock panes now
persist on macOS. Our socket line framing verified already-correct.
Earlier same day: cmux-tui triangulation below.)

Previous update: **2026-08-19** (cmux-tui triangulation: upstream's Rust
core/TUI subproject was built and run on this host — zig 0.16 + their
pinned rust toolchain, headless smoke green, the TUI ran nested inside a
cmux-adw pane. New strategy doc **COMPARISON.md**: stamped three-way
concept comparison (cmux-adw · cmux-macos · cmux-tui @ upstream
786a35d099). Headline finds: upstream builds a native macOS frontend
over the Rust core in the *private* repo `manaflow-ai/cmux-lite`; the
core's terminal model is placement-vs-resource with detach/attach and 7
SDKs; render-mode frontends still lack mouse/focus input (vNext); no
desktop integration or embedded browser in the core by design.
Recommendation recorded there: **stay on the macOS parity track**,
re-survey monthly (watch cmux-lite), filter big investments by "would
this survive a move onto the core". Evaluation worktree at
`~/cmux-upstream` (build traps in PROGRESS 2026-08-19). Back to 2-way
parity work next.)

Previous update: **2026-08-18 late** (the agent-fleet session: feed
pipeline + persistence + tool-level capture LIVE and promote-proven;
AGENT AUTO-RESUME landed and carried the fleet across two promotes
(claude ×2, kimi, opencode ×3 — 14-agent command table, UUID gate for
claude, record-fallback for kimi-shaped stores, hermes --resume-flag
confusable pinned); `debug.resume_plan` + `linux/scripts/resume-audit.sh`
as the drift-proof coverage instrument; the feed doubles as an
inter-session channel (announce workstreams + prompt-typed nudges —
pattern in the cmux-feed skill, incl. the tool_input text rule and
text-then-Enter delivery). Suites: feed-smoke 24, agent-resume-smoke 11,
cli-open-smoke 4. Ghostty merge staged on the fork as
`linux-gtk-embed-next`. Earlier same day below.)

Previous update: **2026-08-18** (lfm-dl findings work-down, roadmap/08:
`feed.*` verbs LIVE on Linux — the agent-hook event pipeline works,
built on the shared CMUXAgentLaunch WorkstreamStore, `feed-smoke.sh`
19 green; opencode-plugin install fallback + `cmux open file://` fixed,
`cli-open-smoke.sh` 4 green. NEEDS PROMOTE to reach the daily. macOS
compile check GREEN on the revived ultmos VM (flatpak virtqemud
socket takeover diagnosed + Restart=always hardening, see PROGRESS).
Standing from 2026-07-24: ghostty fork catch-up compiled on trial
branch `trial-merge-probe`, runtime validation next — see GAPS.)

Previous update: **2026-07-24 ~20:00** (POC-0003 increment 1 EXECUTED:
the full macOS app builds on the GPU-less Intel VM — Xcode 16.4 +
swift.org 6.2.3 hybrid, `macos-verify/build-app.sh` — and RUNS
headless: socket up, auth enforced, surfaces degrade exactly as
predicted. En route: ghostty fork catch-up merge done on a trial
branch, shim increment 4 now in GAPS; the drafted stale-frame upstream
PR is OBSOLETE (upstream deleted the block). Earlier same day: the
`macos-verify/` compile checker + two `__suseconds_t` fixes; ADR-0010
watch/point; comfort mirror ①–⑦).
Update this file at the end of every significant session; it is the
fastest path from cold start to productive work.
Deep history lives in [PROGRESS.md](PROGRESS.md), distilled
transferable lessons in [LESSONS.md](LESSONS.md); this is only
"what now".

## Where we are, in one paragraph

The Linux port is **self-hosted on embedded Ghostty**: the human's daily
instance runs `CMUX_TERM=ghostty` with the Claude session inside a
Ghostty pane, driving the app through its own socket. Agents can fully
drive ghostty panes (`send` / `send-key` / `read-screen` incl.
scrollback — richer than the VTE path). Browser automation, workspace
verbs, notifications: all done (PARITY.md). The Ghostty shim lives on
the ghostty submodule branch **`linux-gtk-embed`** (fork
hiasihaho/ghostty); design + increment log in
[GHOSTTY-SHIM.md](GHOSTTY-SHIM.md).

## Current state

Daily driver is FULLY LANDED: the human launches cmux from the GNOME
desktop launcher; the binary self-locates GHOSTTY_RESOURCES_DIR,
defaults to Ghostty terminals, resize works (fork renderer patch
Darwin-gated, ghostty `ae8ba5f0a`), and scrolling is snappy (embed tick
at G_PRIORITY_DEFAULT + ReleaseSafe shim — Debug shim scrolls
sluggishly; ReleaseFast SEGVs, see build cheat sheet). Human-confirmed
"supersmooth" 2026-07-20.

Browser automation now survives strict-CSP sites (GitHub et al.):
isolated-world fallback in `BrowserJS.run`, landed 2026-07-21 (see
PROGRESS). The fix is in the debug binary on disk — the daily instance
picks it up at its next (human-approved) restart.

**Browser stack proven on a real SPA** (2026-07-21): a dogfood agent
extracted 563/563 pocketyoga poses through browser verbs alone, scored
against the site's own data file. It surfaced two defects, both now
fixed and regression-tested — `goto` returning while the *previous*
document was still live (silent wrong data; `0cf741644`) and a quadratic
CLI response transfer (51× at 6 MB; `183bdd102`). Two suites guard this
now: `linux/tests/browser-navigation-smoke.sh` (8) and
`webdriver-smoke.sh` (9). Both fixes touch the **shared** `CLI/cmux.swift`
or mirror a macOS bug — see UPSTREAM.md §4; neither is xcodebuild-verified
(no macOS toolchain here).

**The work-down list lives in [GAPS.md](GAPS.md)** (since 2026-07-22):
pick from its *Now* table, follow its rules (same-commit updates, suite
per fix, sweep after every merge). The milestones below are the
narrative context.

## Latest session (2026-07-24 afternoon): the macOS compile checker

The UPSTREAM.md caveat "no macOS toolchain here" is retired. A QEMU/KVM
macOS 15.7.7 VM is reachable as `ssh hias@ultmos` (CLT-only, no Xcode,
no GPU — `MTLCopyAllDevices()` = `[]`, so the app itself can never
render there; ghostty macOS is Metal-only with no software fallback).
New `macos-verify/` package compiles the exact Linux CLI file set
(symlink to `linux/Sources/CmuxCLI`) + its four packages on macOS with
plain `swift build`. First run caught real damage: the 2026-07-22
CLI-port commit `7af1ce44f5` used glibc-internal `__suseconds_t` in two
files — macOS-broken since landing, invisible until now. Fixed
(`suseconds_t`), swept for siblings (none), green both sides. Workflow
now: after touching `CLI/` or the four shared packages, rsync + `cd
cmux/macos-verify && swift build` on the VM (details: PROGRESS
2026-07-24, gotchas incl. the pipe-exit-code lie and openrsync flags).
The app-on-VM question is now a written proposal — **POC-0003**
(`poc/0003-headless-macos-reference.md`): increment 1 = full Xcode on
the VM (cheap, no fork changes, retires the app-target UNVERIFIED);
increment 2 = null-renderer fork increment for a headless-but-fully-
driveable macOS reference (terminal state is CPU-side; only pixels
need the GPU). Parked, status `idea`.

## Earlier session (2026-07-24): live agent displays + the pointing channel

**ADR-0010 accepted (A+B both) and fully landed.** `scratch.sh` gained
`watch` (x11vnc+noVNC → browser pane in a *background* workspace of the
caller's cmux; ports derive `:N` → rfb `5900+N` / web `6900+N`,
localhost-only), `watch-status` (the check guard — verifies processes,
serving, and that the pane is *actually connected* via `browser eval`),
`point` (the deixis verb: the human clicks the element they mean inside
the agent's display, the agent reads back exact coords + a
crosshair-marked shot), and `unwatch` (pid-verified kills; `stop`
implies it). Measured: a VNC-injected click really operated the scratch
instance's sidebar, and `point` returned the exact coordinates.
POC-0002 → `adopted` as `features/12-live-agent-display` — the first
completed authored-intent → measured-reality graduation. New system
deps (optional): `x11vnc`, `novnc` (DEPENDENCIES.md).

**Incident, same morning:** the dev desktop starter came up VTE-only —
the documented plain-`swift build` trap had silently overwritten the
shim-linked binary overnight (DEPENDENCIES.md calls `CMUX_GHOSTTY=1`
load-bearing; the daily kept Ghostty only because it held the old
binary in memory). Rebuilt with the flag, restarted dev, both instances
back on `ghostty(default)`. **Candidate small task:** a `start.sh`
warning when the on-disk binary lost the shim that the running
instances still have.

**Found gap** (GAPS row, source: watch-harness build): `browser
screenshot` errors on background-workspace surfaces
(`invalid_state`) even though backgrounded WebKit pages keep running
(`eval` works, the VNC session holds). Probe WebKit's offscreen
snapshot path.

A `vncpoc` scratch instance (+watch) may still be running from the
build session — `scratch.sh stop vncpoc` tears it all down.

**Comfort mirror ①–⑤ landed** (same day, after the UX survey —
MACOS-UX.md): ① omnibar states (back/forward/reload⇄stop/https lock),
② hover affordances (row ✕, header ＋), ③ right-click context menus on
rows+headers, ④ workspace colors (16-swatch palette, left rail,
persisted), ⑤ tab icons + loading spinner + end-action four, ⑥ sidebar DnD (drag membership/reorder, drop indicators) + the workspace.reorder verb (one shared core). All
suite-verified (workspace-groups 58, ui-commands 51-leg, navigation
14). Fat trap found ⑤: the ghostty shim exports bundled libpng and
WebKit's UI-process favicon decode SEGVs into it — favicons guarded
off in shim builds, GAPS row for the fork-side fix. Also found: the sidebar ListBox render can desync from the projection under long churn (GAPS Now, repro recipe recorded). ⑦ minimal Dock landed too (global dock.json terminal controls, Ctrl+Shift+B, debug.dock, dock-smoke 8) — ALL SEVEN mirror items done in one day. Remainder: DnD long tail, Dock remainder, the two Now-bugs (renderer desync, shim libpng). Trap fixed on
the way: lib.sh now exports DISPLAY so a bare xdotool in a suite can
never drive the developer's real desktop again (PROGRESS).

**Workspace groups stages 1+2 landed** (same session, later): all 17
`workspace.group.*` verbs + the `workspace.create` group params serve
with macOS wire parity — model, contiguity/pin-tier ordering, anchor
semantics, session persistence — AND the sidebar renders sections:
chevron header rows (click toggles collapse, no selection theft),
indented members, collapsed counts, attention aggregation.
`workspace-groups-smoke` 47 green incl. rendered-row and color/icon assertions via the
new `debug.sidebar_rows` (projection shared with the view). New trap in
PROGRESS: ListBox rows must be structure-stable across renders — wrap
kind-switching rows in EitherView. Last mile (GAPS "Next", S):
colors/icons rendering + a management context menu. The daily instance
won't serve any of this until its next approved restart/promote.

## Current focus and the parity resume path (2026-07-22, ~17:00)

**Done today:** the harness batch (run.sh front door, freshness
preflight, flake hunter, assertion ledger, kept gate logs — plus the
saboteur hunt it resolved, see PROGRESS), the per-session scrollback
directory, `surface.respawn` on VTE (in place, old pid killed,
scrollback survives; ghostty refuses honestly), and the realize half
of eager background spawn.

**Done 2026-07-22 evening: ghostty shim increment 3** — respawn for
ghostty panes (macOS's replace-and-replay, same surface id, buffer +
cwd survive), eager background spawn (agents can drive panes in
never-shown workspaces), live config reload. Plus the bugs the hunt
surfaced: `surface.list` omitted background tabs (broke the shared
CLI's surface resolution everywhere), PaneTabs reconcile kept stale
pages on same-id widget replacement. GHOSTTY-SHIM.md increment 3 has
the C API; the shim branch is `linux-gtk-embed` (fork
hiasihaho/ghostty).

**Done 2026-07-22 (late): CLAUDE CODE AGENT TEAMS WORKS ON LINUX** —
a real teammate spawned as a native split, full lifecycle verified
(PARITY row, PROGRESS story, `tmux-compat-smoke.sh` guard). Two server
additions did it: `surface.current` + identify's `focused` block. Also
that session: the JS console (`browser.console.show`, Ctrl+Shift+J) and
a second shared-CLI shadowing find (UPSTREAM §4d). Gate: 13 suites,
163 assertions green. All of it reaches the daily at the next
`promote.sh --no-build`.

**The resume path** (rows in GAPS *Now* with full detail):

1. ✅ **Browser JS console** — DONE 2026-07-22 late (`browser.console.show`,
   `browser devtools console`, Ctrl+Shift+J; reuse-not-stack; the fix
   also un-shadowed upstream's `devtools console` CLI block on macOS —
   UPSTREAM.md §4d).
2. **Bare Ghostty pane relocation respawns its shell** — batch-5 known
   limitation; roadmap/05 lifecycle hardening; `debug.surfaces` is the
   probe.

Then GAPS *Next* (ephemeral panes S-row first, then profile popover UI,
workspace.reorder, multi-window, Flatpak — see the table).

Standing state to remember on resume: the daily instance runs the
**21:06 promote (2026-07-22)** — GAPS batches 1–5 and all of the day's
work (harness batch, per-session scrollback, respawn on both backends,
eager background spawn, live reload — shim increment 3) are LIVE in
the daily; eager spawn was verified against the running instance.
Gate: 12 suites, 155 assertions green. Session-history note: the
2026-07-22 day session died at 100% context, which makes
`claude --continue` bail silently — start fresh and reconstruct from
this file + PROGRESS + GAPS (proven to work, ~10 minutes).

## Next milestones

1. ✅ Default flip DONE (2026-07-17): shim-linked builds default to
   ghostty, `--vte`/`CMUX_TERM=vte` falls back. Next: eager background
   spawn (designs assessed in PROGRESS 2026-07-17) — background panes
   still spawn on first selection only.
2. Ghostty-embed hardening (deferred, security-flavored): the fast-churn
   resource leak — see ../../roadmap/05-ghostty-embed-hardening.md (agent-
   drivable local DoS + ReleaseFast memory-unsafety smell; not blocking).
3. WebKit-native automation (decided 2026-07-21, no CDP/Chromium):
   ../../roadmap/06-webkit-native-automation.md. Increments 1 (console capture
   v2 — CSP-proof, from page load) and 2 (W3C WebDriver opt-in via
   CMUX_WEBDRIVER=1 — trusted input, verified isTrusted=true) are DONE,
   as is WebDriver split adoption (the driver drives a visible cmux pane)
   the navigation barrier, and the **Web Inspector pane** (increment 3,
   done 2026-07-21 — `cmux browser inspect`, human-confirmed rendering).
   Next: increment 4 (native console tap) and the increment-5 long tail
   (WebKitFindController, download hardening, popup routing).
4. ✅ The four open gaps of 2026-07-20 are DONE (2026-07-21): terminal
   scrollback persistence (out of band, configurable up to unlimited,
   replayed via the fork's `inject_output`), browser state captured on
   `load-changed` with a debounce, divider positions as fractions, and
   the browser URL bar + pane zoom + `browser.tab.*`.

   **Planned (2026-07-21): browser profiles** — per-profile
   cookie/storage/cache isolation plus ephemeral panes. Full design in
   roadmap/07-browser-profiles.md. Upstream macOS already ships this
   (BrowserProfileStore, profile popover, `browser profiles` verbs), so
   it is parity work and deliberately waits until after the upstream
   catch-up merge, which defines the exact surface to mirror.

   ✅ **DONE (2026-07-22): VTE backend parity for scrollback** — as designed below, plus `read_text --scrollback` now works on VTE too. Historical design note:

   **(decided 2026-07-21): VTE backend parity for scrollback.**
   Only Ghostty panes capture/replay today — `ghosttyReadText` returns
   nil for VTE surfaces, so under `CMUX_TERM=vte` the feature is absent
   (not broken). Feasibility checked against VTE 0.82.3: capture via
   `vte_terminal_get_text_range_format` (rows spanning the scrollback,
   bounds from the terminal's adjustment), replay via `vte_terminal_feed`
   — the exact analog of the fork's `inject_output`, parsed as output and
   never reaching the shell. The LF→CRLF normalization already lives in
   the backend-agnostic `replayPayload`, so the staircase lesson carries
   over for free. Achievable; it is a second implementation, not a port
   blocker.

   ✅ **DONE (2026-07-22): settings.** `~/.config/cmux/cmux.json`
   (`linux` object, env > file > default) + preferences window
   (Ctrl+comma): backend ComboRow, scrollback slider with preset marks,
   search-URL row. Raw libadwaita C (adwaita-swift lacks GtkScale).

   Method: read the macOS implementation first (it is usually right and
   is the parity target), then deviate only where our own approach is
   demonstrably more flexible — as with session state, where WebKitGTK's
   native blob beats macOS's shadow-stack emulation.

5. **Keyboard/UI commands** — mostly DONE 2026-07-22: directional pane
   focus (Ctrl+Shift+arrows, geometry-based), rename-workspace dialog
   (Ctrl+Shift+E — NOT F2, terminals eat function keys), jump-to-unread
   (Ctrl+Shift+U), open-folder workspace (Ctrl+Shift+O), flash
   (surface.trigger_flash + CLI). Still open: browser JS console pane,
   multi-window. The full capabilities sweep ran 2026-07-22
   (`linux/scripts/capabilities-sweep.py`, re-run it after every merge):
   9 quiet renames fixed, ~140 remaining methods are honest macOS-only
   feature gaps (vm/remotes/groups/canvas/feed/auth/layout). ALSO:
   `notification.create_for_caller` implemented —
   `cmux notify` had silently regressed after the merge (upstream
   renamed the method); agent hooks were failing quietly.

   **(historical) Keyboard/UI commands still to do.** macOS binds 28 commands; Linux
   now binds 12. The gap is what a person can *reach*, which a verb-level
   test suite cannot see — every suite was green while the browser pane
   had no way in.

   *Cheap-ish (needs a small dialog, verb already exists):*
   - **Rename workspace** — `workspace.rename` works over the socket;
     there is no text-entry dialog, which is the only missing piece.

   *Real work (no verb, needs new logic):*
   - **Directional pane focus** (`focusLeft/Right/Up/Down`) — needs
     geometry-aware traversal of the paned tree, not just list order.
     Pairs with `surface.focus` ❌ in PARITY; the socket verb and the
     shortcut should land together.
   - **Jump to latest unread** (`jumpToUnread`) — needs an ordering over
     workspaces with attention state.
   - **Open folder** (`openFolder`) — a directory picker that opens a
     workspace there; needs a file-chooser dialog.
   - **Browser JavaScript console** (`showBrowserJavaScriptConsole`) —
     distinct from DevTools; macOS opens the console pane directly.
   - **Flash focused panel** (`triggerFlash`) — a visual ping; the verb
     exists on macOS as `surface.trigger_flash`.
   - **Multi-window** (`newWindow`/`closeWindow`) — the whole
     `window.create/close/current/focus` family, a phase of its own.

6. ✅ **DONE (2026-07-22): the catch-up merge.** origin/main (5657
   commits) merged into linux-port and upstream's entire CLI ported to
   Linux (see PROGRESS 2026-07-22 — packages, compat layers, /proc
   ports). The fork's `main` now carries the merged result. Remaining
   drift: upstream/main was ~268 commits ahead of origin/main at merge
   time — the next catch-up is small. The macOS build is untouched in
   intent but UNVERIFIED (no toolchain here); verify on the VM before
   any upstream PR. The old procedure below still applies to future
   merges.

   **(historical) Deferred: merge `linux-port` into the fork's `main`.** Not urgent —
   the work is pushed to `origin/linux-port` and the upstream PR flows
   from there, so nothing is stranded. But it is real work that gets
   harder the longer it waits, and it has a trap:

   - local `main` is a **stale shallow snapshot** (`552a9364`), while
     `origin/main` has moved to `25dc9139` — **172 commits ahead** of the
     point `linux-port` was cut from;
   - the clone is **shallow**, so git reports *"refusing to merge
     unrelated histories"* — it cannot compute a merge base at all;
   - therefore a naive `main` fast-forward + push would try to **discard
     those 172 commits**. Never force-push `main`.

   The procedure when the time comes:

   ```sh
   git fetch --unshallow origin          # large; restores the real history
   git checkout linux-port
   git merge origin/main                 # INTO linux-port, so main stays intact
   # resolve — both sides edited CLAUDE.md, CLI/cmux.swift and docs
   cd linux && CMUX_GHOSTTY=1 swift build
   for t in linux/tests/*-smoke.sh; do "$t"; done   # all six must pass
   git checkout main && git merge --ff-only linux-port
   git push origin main                  # never --force
   ```

   Merge *into* `linux-port` first is the point: `main` is never left
   broken, and a bad resolution costs a branch rather than the fork.

7. Flatpak packaging.
5. Parity long tail: the remaining PARITY.md ❌ rows — see GAPS.md,
   which owns the prioritized list (system.tree, pane.resize/swap/
   break/join, surface.move/reorder, tab.action all landed 2026-07-22).
6. Upstreaming to manaflow: everything is PRE-PREPARED in
   [UPSTREAM.md](UPSTREAM.md) — a clean single-commit PR branch
   (`fix-stale-frame-replay-gtk` on hiasihaho/ghostty), a drafted PR
   body, and the optional talking points (embed branch, submodule
   hygiene). The human just runs the `gh pr create` command when ready.

## Instance topology & etiquette (short form)

- **daily** = the human's instance (and usually your host): default
  socket, persistent session. NEVER kill it — you die with it.
- **dev / dev2** = isolated test slots: `linux/scripts/start.sh dev2
  --ghostty`, `stop-dev2`, `status`. Test new binaries here; `swift
  build` alone never affects running instances.
- Full rules: [INSIDE-CMUX.md](INSIDE-CMUX.md) (auto-loaded via
  CLAUDE.md).

## Build cheat sheet

```sh
cd linux && swift build                      # VTE-only default
cd linux && CMUX_GHOSTTY=1 swift build       # + ghostty shim linkage
cd ghostty && PATH=~/.local/zig/zig-x86_64-linux-0.15.2:$PATH \
  zig build lib-gtk -Dapp-runtime=gtk -Doptimize=ReleaseSafe \
  -Dversion-string=1.3.0-dev
# ReleaseSafe is the STANDARD shim mode (Debug scrolls sluggishly;
# ReleaseSafe is snappy AND correct for normal use + dogfooding —
# confirmed 2026-07-20, see PROGRESS).
# KNOWN ISSUE: -Doptimize=ReleaseFast SEGVs inside ghostty_embed_init
# at first surface creation (coredump 2026-07-20 16:45, pid 821401);
# ReleaseSafe does not panic → not a checkable safety violation. Park.
# ghostty header changes reach Swift only after the zig build reinstalls
# zig-out/include/ghostty_gtk_embed.h.
linux/scripts/dogfood.sh "focus…" [min]      # QA agent cycle (CMUX_SOCKET_PATH honored)
```

## Doc map

- **MACOS-UX.md** — the measured macOS comfort-surface reference
  (2026-07-24 four-agent survey): color language incl. the 16-swatch
  palette, full icon inventory with state handling, the complete
  drag-and-drop and context-menu maps, and the corrected Dock model —
  plus the proposed mirror order awaiting decision. UX-PARITY stays the
  decision ledger; this is its evidence base.
- **adr/** — Architecture Decision Records: numbered, status-tracked
  decisions with rationale + alternatives (interaction-parity-sacred,
  out-of-band scrollback, DevTools-as-pane, focused-ledgers, ghostty
  embed, parallel-dogfood). Record a *decision* here; start at
  `adr/README.md`. Proposed → Accepted → Superseded lifecycle.
  Browse it as an ATLAS (decision graph + all records, live) with
  `linux/scripts/atlas-serve.sh adr`; the graph regenerates via
  `linux/scripts/adr-atlas-graph.py` (re-run when you add/re-status an ADR).
- **PARALLEL-DOGFOOD.md** — the harness for running several agents on
  DISJOINT work packages at once (worktree + scratch instance + browser
  profile each), integrated via a local bare repo. Mechanics proven on
  the testbed 2026-07-23 (`linux/scripts/pkg-harness.sh`); the intended
  flow spawns one claude-teams teammate per scoped package. Not yet run
  on real GAPS packages — that is a next step.
- **PARITY-DASHBOARD.md** — the board of boards: coverage-by-subsystem
  roll-up (from `macos-surface-survey.py`), the discovery cadence, and
  links to every focused ledger. Start here to see "how much of macOS,
  and how we find what's left". Live-viewable as page ⓪ of the atlas.
- **MENTAL-MODEL.md** — the one-page shape of the system, mermaid
  diagrams: supervision loop, hierarchy, attention pipeline, Claude
  lifecycle, tmux shim, UI geography, doc map, port heat map. Start
  here for the big picture.
- **wiring/** — the component-level wiring ATLAS (2026-07-23): 9 pages,
  ~30 mermaid diagrams reading straight from the code (topology,
  claude-teams shim, control protocol, surface lifecycle, attention,
  persistence, browser, build/promote). View it live with
  `linux/scripts/wiring-serve.sh` → open the printed URL in a cmux
  browser pane; the viewer live-reloads on `.md` edits (the human-AI
  loop). Uses cmux's own vendored mermaid — no CDN.
- **CONCEPTS.md** — how cmux is *meant*: the official-docs
  distillation (crawled 2026-07-22 via the port's own browser stack);
  read before deciding whether/how to build a macOS feature.
- **kb/** — the deep knowledge base (docs + guides + 15 blog posts +
  changelog, crawled 2026-07-22 by an agent driving the port's own
  browser): per-topic distillations incl. `claude-with-cmux.md` (the
  intended Claude workflow), `tmux-compat.md` (shim↔verb↔port table),
  full config schema, notification contract, resume matrix. Start at
  `kb/INDEX.md`.
- **UX-PARITY.md** — how it looks and feels vs macOS (dual code survey
  2026-07-22): per-surface verdicts (✅/🎨/❓/❌), decision queue,
  recorded decisions. Update in the same commit as any visible UI
  change.
- **FEATURES.md** — user-facing feature overview; marks parity vs the
  small set of beyond-macOS additions (verify ★ claims vs Sources/).
- **PROGRESS.md** — chronological evidence log + gotchas (append, same
  commit as the change).
- **PARITY.md** — per-verb/feature status vs macOS (update, same commit).
- **GHOSTTY-SHIM.md** — shim design, C API, increment status.
- **PORTING.md** — original plan/disposition table.
- **linux/README.md** — build/status/workflow for humans.
