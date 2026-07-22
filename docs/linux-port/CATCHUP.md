# Catch-up — start here (living document)

Last updated: **2026-07-22 ~12:50** (GAPS batches 1–5 shipped — the
whole S-cluster plus surface.move/reorder and the tmux-compat pane
verbs; capabilities sweep covers both protocol generations; harness
roadmap documented). Update this file at the end of every significant
session; it is the fastest path from cold start to productive work.
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

**The resume path** (rows in GAPS *Now* with full detail):

1. **Browser JS console pane** — `browser.console.show`; distinct from
   DevTools, macOS opens a console directly.
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

- **MENTAL-MODEL.md** — the one-page shape of the system, mermaid
  diagrams: supervision loop, hierarchy, attention pipeline, Claude
  lifecycle, tmux shim, UI geography, doc map, port heat map. Start
  here for the big picture.
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
