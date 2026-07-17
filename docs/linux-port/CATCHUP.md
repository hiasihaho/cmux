# Catch-up — start here (living document)

Last updated: **2026-07-17 ~02:40**, end of the increment-3/4 night
session. Update this file at the end of every significant session; it is
the fastest path from cold start to productive work. Deep history lives
in [PROGRESS.md](PROGRESS.md); this is only "what now".

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

## THE open question (ask the human first!)

A **post-resize freeze** blocks the ghostty default flip: after
interactively resizing a window, ghostty panes stop presenting frames
(input still reaches the PTY; the pane looks dead). **Standalone ghostty
from the same fork build freezes identically — NOT an embedding bug.**
Full forensic trail: PROGRESS.md "OPEN BUG: ghostty pane freezes".

The human was handed a `GSK_RENDERER=gl` standalone ghostty window as
the last experiment of the night — **ask for the result**:

- gl renderer survives resize → workaround = export `GSK_RENDERER=gl`
  in `start.sh --ghostty` launches; root cause = GTK 4.20 default GSK
  renderer (ngl?) × GLArea × AMD Mesa 25.3.6 — check upstream
  GTK/ghostty issues, report if new.
- gl renderer freezes too → next leads, in order: upstream-ghostty-tip
  build test (fixed? → rebase fork), `GSK_RENDERER=cairo`, distro
  ghostty package comparison, Mesa/GTK debug toggles.

## Next milestones (after the freeze)

1. Ghostty **default flip** (`CMUX_TERM` default → ghostty, VTE
   fallback), then eager background spawn (designs assessed in
   PROGRESS 2026-07-17) if agent pain reappears.
2. Flatpak packaging.
3. Parity long tail: PARITY.md ❌ rows (system.tree, surface.focus,
   pane.resize, terminal find overlay, sidebar metadata pills…).

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
  zig build lib-gtk -Dapp-runtime=gtk -Dversion-string=1.3.0-dev
# ghostty header changes reach Swift only after the zig build reinstalls
# zig-out/include/ghostty_gtk_embed.h.
linux/scripts/dogfood.sh "focus…" [min]      # QA agent cycle (CMUX_SOCKET_PATH honored)
```

## Doc map

- **PROGRESS.md** — chronological evidence log + gotchas (append, same
  commit as the change).
- **PARITY.md** — per-verb/feature status vs macOS (update, same commit).
- **GHOSTTY-SHIM.md** — shim design, C API, increment status.
- **PORTING.md** — original plan/disposition table.
- **linux/README.md** — build/status/workflow for humans.
