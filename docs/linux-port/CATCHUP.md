# Catch-up — start here (living document)

Last updated: **2026-07-20 ~17:05** (scroll snappiness fixed; desktop
launcher is the canonical daily starter). Update this
file at the end of every significant session; it is the fastest path
from cold start to productive work. Deep history lives in
[PROGRESS.md](PROGRESS.md); this is only "what now".

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

## Next milestones

1. ✅ Default flip DONE (2026-07-17): shim-linked builds default to
   ghostty, `--vte`/`CMUX_TERM=vte` falls back. Next: eager background
   spawn (designs assessed in PROGRESS 2026-07-17) — background panes
   still spawn on first selection only.
2. Ghostty-embed hardening (deferred, security-flavored): the fast-churn
   resource leak — see roadmap/05-ghostty-embed-hardening.md (agent-
   drivable local DoS + ReleaseFast memory-unsafety smell; not blocking).
3. Flatpak packaging.
4. Parity long tail: PARITY.md ❌ rows (system.tree, surface.focus,
   pane.resize, terminal find overlay, sidebar metadata pills…).
5. Upstreaming to manaflow: everything is PRE-PREPARED in
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

- **FEATURES.md** — user-facing feature overview; marks parity vs the
  small set of beyond-macOS additions (verify ★ claims vs Sources/).
- **PROGRESS.md** — chronological evidence log + gotchas (append, same
  commit as the change).
- **PARITY.md** — per-verb/feature status vs macOS (update, same commit).
- **GHOSTTY-SHIM.md** — shim design, C API, increment status.
- **PORTING.md** — original plan/disposition table.
- **linux/README.md** — build/status/workflow for humans.
