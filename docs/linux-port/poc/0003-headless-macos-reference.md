---
title: Headless macOS reference instance (null renderer on the VM)
area: dev-tooling
kind: experiment
status: wip
linux: n-a
mac: untested
substrate: >
  macos-verify/ compile checker + the ultmos VM (macOS 15.7.7, x86_64,
  CLT-only today) + the ghostty fork (hiasihaho/ghostty)
adopted: none
evolves_to: >
  a live `mac` source for capslib/the features board (uniqueness ★ checks
  against a *running* macOS cmux, not a code survey); two-sided dogfood
  (Linux agents driving the macOS instance and vice versa); xcodebuild test
  in the pre-upstream-PR loop
---

# 0003 — Headless macOS reference instance (null renderer on the VM)

- **Status:** wip — increment 1 EXECUTED 2026-07-24 (same day as proposed):
  the app builds on the VM (`macos-verify/build-app.sh` is the recipe) and,
  launched with `CMUX_TAG=vmprobe`, **survives without Metal** — control
  plane up, socket created, auth enforced, surfaces loop "not ready" as
  predicted. Full story + measurements: PROGRESS 2026-07-24 (evening).
  Next: external-probe socket auth (keychain-only today; no password file
  by default), then increment 2's null renderer for real terminal content.
  Side-product: the ghostty fork catch-up merge (see GAPS "shim
  increment 4" for the one piece still open).
- **Substrate:** the `hias@ultmos` VM + `macos-verify/` + the ghostty fork
- **Adopted as a feature:** none

## Purpose

Turn the GPU-less macOS VM from a compile checker into a **running,
socket-driveable macOS cmux** — a live parity reference. Not for pixels
(the VM can never render them) but for *behavior*: real `system.describe`
output, real verb responses, real wire formats, measured instead of
read-from-source.

## The measured ground truth this builds on

- `MTLCopyAllDevices()` returns `[]` in the VM (measured 2026-07-24):
  QEMU/KVM offers no Metal device, and macOS has no software Metal.
- Ghostty macOS is Metal-only: `chooseDevice()` in
  `ghostty/src/renderer/Metal.zig:443` errors `NoMetalDevice`; the OpenGL
  backend is compile-gated to GTK. No config/env/build switch exists.
- **The key insight that makes this viable:** ghostty's terminal state
  (cells, scrollback) lives CPU-side in the IO thread. Rendering is a
  separate pipeline. A renderer that accepts surface creation and no-ops
  every draw leaves PTYs, `send`/`read-screen`, and the whole control
  plane fully functional — pixels are the *only* casualty, and the VM has
  nowhere to show pixels anyway.

## Two increments, deliberately independent

**Increment 1 — full Xcode, no fork changes (cheap, do first).**
Install Xcode 16.x (x86_64, macOS 15-compatible) on the VM — it is already
signed into an Apple ID; add the zig 0.15.2 macOS tarball and build
GhosttyKit (x86_64-only, skip universal). Then
`xcodebuild build CODE_SIGNING_ALLOWED=NO` of the app target. Payoff even
if increment 2 never happens: the app target joins the CLI in the
verified-on-macOS set before any upstream PR, and `xcodebuild test`
becomes available. Also *measure* what launching the unpatched app does
(does surface-creation failure crash it or degrade it? — record the exact
failure mode; a degraded-but-alive control plane would already be
partially driveable).

**Increment 2 — null renderer in the ghostty fork (the deep play).**
A no-op backend behind the renderer's generic API (accept device-less
init, no-op begin/end frame, still service resize + frame-completed
callbacks so the surface lifecycle proceeds), selected by env
(e.g. `GHOSTTY_RENDERER=null`) so a stock build is untouched. Own fork
branch (e.g. `macos-null-renderer`), *not* mixed into `linux-gtk-embed`.
Watch-outs: grid metrics must not depend on Metal texture queries
(`queryMaxTextureSize`); the macOS app side may assume a live
`CAMetalLayer` — the null path may need a plain NSView; keep everything
out of the typing-latency-sensitive paths listed in CLAUDE.md.
Done means: app boots headless in the VM, `cmux` CLI against its socket
runs workspace-create / send / read-screen green.

**Then (graduation path):** point `capabilities-sweep.py` / capslib at the
live macOS socket — the features board's `mac` column gains an empirical
source, and every ★ uniqueness claim is checked against a running macOS
cmux instead of a source survey. That wiring step is what would graduate
this POC into a `features/` page.

## Risks / costs

- **Fork divergence:** one more patch to carry through upstream ghostty
  merges. Mitigate: isolated backend file + a single init hook.
- **Disk:** VM has ~45 GB free; Xcode installed + DerivedData +
  GhosttyKit is tight. May need qcow2 growth first.
- **Speed:** KVM x86 VM; a clean app build will be slow (tens of
  minutes). Acceptable for a reference instance that rebuilds rarely.
- **Unknowns in increment 2:** the macOS app's renderer assumptions are
  unmeasured — hence increment 1's "launch it and record the failure
  mode" comes first and bounds the design.
- **User-gated step:** the Xcode download/install wants the Apple ID
  session — a human-at-the-VM moment, like the promote checkpoint.

## Decision status

Parked behind the current mirror/dogfood priorities. Pull increment 1
forward on its own whenever an upstream PR needs app-target verification
— it needs no fork work and pays for itself immediately.
