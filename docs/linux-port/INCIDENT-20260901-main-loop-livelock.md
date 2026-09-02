# INCIDENT 2026-09-01 — main-loop live-lock in the daily (Mesa/GTK GL teardown)

A postmortem. The daily cmux-adw instance (PID 14071, up 12 days) froze its
UI at ~23:11 while the main thread burned ~99% of one core. All agent
sessions (descendants of the daily) stayed alive; the control socket kept
answering on its own thread, which is how the diagnosis reached the process
at all. Resolved by a clean `promote.sh` restart at 00:47 the next day.

This file is the evidence chain and the transferable lessons. The fix itself
(the `realizeHiddenGhosttys` latch) is a separate, reviewed change — see
GAPS.md. Nothing here is applied code.

## 1. Symptoms

- Sidebar clicks did nothing; one window unusable; UI frozen.
- Main thread (TID 14071) state `R`, ~99% of one core, continuous; every
  other thread parked in `futex_do_wait` / `poll_schedule_timeout`.
- `/tmp/cmux-debug.log` stopped dead. Last lines were agent-hook notify
  timeouts:
  `agentHook.stop.notify.error agent=kimi ... error=ERROR: Command timed out`
  (15 s timeouts), plus an earlier `set_agent_pid` "not implemented in the
  Linux port yet" error.

## 2. What was ruled out, with evidence (not assertion)

Three hypotheses were raised and **refuted by measurement** before the real
cause was found. They are recorded because each is a plausible first guess
and each cost a correction.

- **"A build into `linux/.build` deleted the running binary's mappings."**
  Refuted. INSIDE-CMUX.md line 19: "`swift build` is always safe: it
  replaces the binary on disk; the running app is unaffected." The 198
  `(deleted)` mappings in `/proc/<pid>/maps` are the normal, expected result
  of any rebuild since the process started — not evidence of damage. The one
  named hazard (rebuilding the Ghostty shim over `ghostty/zig-out/lib` while
  mapped → SIGBUS) was checked: `libghostty-gtk.so` mtime 2026-07-22,
  mapping resolves to a live inode. Did not fire.
- **"The agent-hook notify path hung the app."** Refuted as *cause* (it is a
  *symptom*). `agentHook.stop.notify` (CLI/cmux.swift) sends
  `notify_target_async` over the control socket. The socket server's
  `dispatchOnMainLoop` (`ControlSocketServer.swift:163`) schedules the
  handler via `Idle { }` onto the GTK main loop, then blocks the socket
  thread in `response.wait(seconds: 15)`. When the main loop is wedged, the
  idle closure never runs and the call times out at 15 s — which is exactly
  the log line. The `set_agent_pid` "not implemented" error is an unrelated,
  known Linux-port gap.
- **"A stray agent test loop wedged it."** Refuted by the backtrace (below):
  the spin is in the GPU driver, not in any test or socket code.

## 3. Root cause (gdb, read-only, ptrace_scope=0)

Read-only backtraces of the spinning main thread (`gdb -p <pid> -batch -ex
"thread 1" -ex "bt" -ex "detach"` — briefly pauses the thread, modifies
nothing). Across samples the thread **oscillated** between two GPU-driver
stacks:

Teardown:

    gtk_widget_unrealize
      → gtk_gl_area_unrealize
      → gdk_gl_context_dispose
      → eglDestroyContext → dri2_destroy_context → st_destroy_context
      → _mesa_HashWalk(Locked) → st_texture_release_context_sampler_view   ← spin

Setup:

    gtk_popover_realize
      → gsk_gpu_renderer_realize → gsk_renderer_new_for_surface_full
      → gdk_draw_context_attach → gdk_vulkan_context_surface_attach
      → terminator_GetPhysicalDeviceSurfaceFormatsKHR
      → wsi_wl_surface_get_formats → wl_display_roundtrip_queue            ← setup

The cmux-side driver at the bottom of the stack:

    SurfaceRegistry.realizeHiddenGhosttys()   TerminalSurfaces.swift:157
      called from TerminalStackWidget.sync    TerminalSurfaces.swift:611
      → realizeSubtree → gtk_widget_realize   TerminalSurfaces.swift:170

**Mechanism.** `realizeHiddenGhosttys` is the Ghostty-shim
eager-background-spawn feature: it runs at the end of *every* sync and calls
`gtk_widget_realize` on every unmapped-but-rooted Ghostty `GtkGLArea`, so
background workspaces have a live shell. Combined with `AdwTabView` page
churn and notification popovers realizing/unrealizing, a GL area is realized
and unrealized **repeatedly**. Each cycle does expensive Mesa/Vulkan context
setup + teardown; the CPU burns in the driver and the main loop never
returns to process events. This is the same trap family the flatpak manifest
already documents: *"venus (virtio-GPU) Vulkan fences hang GTK teardown in
VMs — GL-only is the safe default"* (`--env=GDK_DISABLE=vulkan`).

**This is shipped code, not the in-flight passkey work.**
`realizeHiddenGhosttys` is present in the wedged binary's symbols; the
uncommitted P1b files touched only the WebAuthn vault path, never the
GL/terminal path. Proven via `gdb info functions realizeHiddenGhosttys`
against the live process.

## 4. Why SIGTERM was safe (a restart-decision input)

Neither the app nor GLib installs a SIGTERM handler. The only exit hook is
`SessionExitSave` on GTK's `close-request` (a *graceful window close* — a
different path). SIGTERM therefore uses the kernel-default disposition and
terminates the process immediately; a spinning userspace loop does not block
a default-disposition signal. The cost is that SIGTERM skips the
close-request exit-save — which is exactly why `promote.sh` does
`session.save` over the socket **first**. Ordering already correct; no
`kill -9` fallback was needed.

## 5. Resolution

`cd ~/cmux && linux/scripts/promote.sh` from a TTY (not inside cmux — the
self-hosting guard refuses). Built clean HEAD (`332969b30c`), shim-guard
passed, `session.save` attempted (tolerated a possible timeout on the
starved loop), SIGTERM, `start.sh` relaunched, session restore brought back
workspaces/panes/cwd/scrollback. Verified healthy post-restart: main thread
in `g_main_context_iteration`, ~20% CPU (normal active work), no Mesa spin.

## 6. Lessons (transferable)

- **A wedged GTK main loop turns every main-loop-dispatched call into a
  timeout — and the timeout's log line points at the *caller*, not the
  cause.** The notify timeouts named the agent hook; the cause was GL
  teardown. When a main-loop app wedges, read the *main thread's* backtrace
  before believing any error that came out of a queued/idle-dispatched path.
- **`gdb -p <pid> -batch -ex "thread 1" -ex "bt" -ex "detach"` is the
  highest-value first move** on a live-locked GUI process, and it is
  read-only. Sample several times: a live-lock *oscillates* (we caught both
  the Mesa teardown and the Vulkan attach, and later plain `ppoll`), so one
  sample can mislead. `ptrace_scope=0` on this host permits it.
- **`(deleted)` binary mappings after a rebuild are normal.** Do not
  reconstruct a cause from them; check the doc's named hazards first.
- **Forcing `gtk_widget_realize`/`unrealize` on GL areas in a per-sync loop
  is fragile.** GPU context setup/teardown is expensive and, under
  Mesa/Vulkan, can spin. Idempotent-eager work needs a latch ("already
  started this surface") and must not run during active popover/tab churn.
- **One variable at a time on a restart.** The restart already changes the
  binary; folding an untested GL-lifecycle fix (or a renderer env change)
  into the same step makes any outcome unattributable. The latch and
  `GDK_DISABLE=vulkan` are *separate* follow-ups, each with a repro.

## 7. Follow-ups (tracked in GAPS.md, not done here)

- **Latch for `realizeHiddenGhosttys`** — do not re-realize a surface that
  already started; skip during popover/tab churn. Own reviewed change with a
  repro. (Proposed; NOT in the restart binary.)
- **`GDK_DISABLE=vulkan` as experiment #2** if the wedge recurs on the fresh
  binary — clean attribution, one env var, already the flatpak default.
- **Upstream note**: the Mesa `st_destroy_context` hash-walk spin under
  repeated GtkGLArea teardown is upstream-reportable (Mesa/GTK). This doc's
  backtraces are the evidence.
