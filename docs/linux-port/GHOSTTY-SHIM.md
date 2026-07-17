# Ghostty GTK embedding shim — design

Goal: replace the VTE terminal panes in cmux-adw with real Ghostty
surfaces, by exporting the fork's GTK apprt `Surface` GObject widget
through a small C API ("the shim") that a foreign GTK4/libadwaita app can
link and instantiate. This is the plan of record from PORTING.md Phase 2;
this document is the result of the 2026-07-16 scouting pass (three
source sweeps over `ghostty/` at HEAD `80d3fa0`, v1.3.0-dev,
zig 0.15.2 required and available at `~/.local/zig/`).

## Why not the existing C embedding API

`include/ghostty.h` + `src/apprt/embedded.zig` is what macOS cmux uses.
It is structurally complete for input/clipboard/actions/lifecycle — but
its platform union is macos/ios only, and on Linux the `.lib` artifact
forces apprt=embedded + renderer=OpenGL, whose context hooks are no-op
stubs (`src/renderer/OpenGL.zig:162-235`, "libghostty is strictly broken
for rendering on this platform"). Making that path work means inventing a
GL-context handshake for the embedded apprt — more upstream-invasive than
embedding the GTK apprt, which already owns a working GLArea lifecycle.

## What the GTK apprt gives us for free

- `Surface` is a registered GObject class (`GhosttySurface`, extends
  `AdwBin`, implements `GtkScrollable`) — `src/apprt/gtk/class/surface.zig`.
  Its blueprint template self-wires: GLArea (realize/render/resize),
  key/scroll/motion/click controllers, IMMulticontext (IME), overlays
  (bell, resize, search, child-exited, progress). Instantiable standalone
  via `Surface.new()`; core surface init happens lazily on first GLArea
  resize (`initSurface`, surface.zig:3249).
- `title` and `pwd` are GObject **properties** — a host app gets OSC
  title/pwd via plain `notify::title` / `notify::pwd` signals. Bell state
  likewise (`setBellRinging`).
- `Application.new(rt_app, core_app)` (application.zig:238) creates all
  globals (config load, adw.init, winproto, CSS provider) **without**
  registering or running the GApplication — init/run are already separate.
- Scrollback text extraction exists at core level (`dumpTextLocked`,
  `src/Surface.zig:1889`) — the embedded apprt exports it as
  `ghostty_surface_read_text`; the shim re-exports the same for our
  `read_text` verb (better than VTE: real scrollback).

## The three hard couplings (and the fixes)

1. **`Application.default()`** resolves via
   `gio.Application.getDefault()` (application.zig:225) — in cmux-adw the
   *host's* GApplication is the default. Fix: a module-level
   `embed_instance` global consulted first; set by the shim at init.
   One-line-ish patch, no behavior change for standalone ghostty.
2. **The tick pump.** `core_app.tick(rt_app)` is only called inside
   `Application.run`'s hand-rolled loop; `wakeup()` just wakes the main
   context. In a foreign loop nothing drains the mailbox → nothing
   renders. Fix: in embed mode, `wakeup()` schedules a coalesced
   `g_idle` tick (pending-flag + `g_main_context_invoke`); the shim also
   ticks once after surface creation. Renderer wakeups → mailbox →
   wakeup → idle tick → app-thread draw (`must_draw_from_app_thread`).
3. **Build gates.** (a) `src/apprt.zig:42-49`: `.lib` artifact
   unconditionally selects apprt=embedded → branch on
   `build_config.app_runtime` instead. (b) `src/build/SharedDeps.zig:530`:
   `if (step.kind != .lib)` withholds glad + GTK deps + gresources from
   lib builds → relax for app_runtime==gtk. (c) do NOT reuse
   `src/main_c.zig` (asserts apprt==embedded); new shim root.

Soft issues, handled or deferred:
- `startup()` (style manager, app action map, `app.present-surface`)
  never runs in embed mode. CSS provider attach happens there → cosmetic
  overlay styling may be missing in increment 1; selectively invoke the
  CSS setup from shim init in increment 2.
- `desktop_notification` action calls `gio.Application.sendNotification`
  on ghostty's (unregistered) Application → would fail; cmux wants these
  events itself anyway. Fix: embed action hook (below) intercepts.
- Container actions (`win.*`, `tab.*`, `split-tree.*`) from the context
  menu bubble to nothing and are silently dropped — acceptable; cmux owns
  splits/tabs.
- winproto has a `.none` fallback; fine under a foreign app.
- gresources (compiled blueprints) are registered by a C constructor in
  the glib-compile-resources output — linking the static lib is enough.

## Shim C API (increment 1 surface; grows per parity needs)

    // ghostty_gtk_embed.h  (new header, NOT ghostty.h)
    int  ghostty_embed_init(void);                 // CoreApp + Application.new + embed globals
    void ghostty_embed_set_action_cb(void* userdata,
         bool (*cb)(void* ud, void* surface_widget, ghostty_action_s action));
         // reuses ghostty.h's C action structs; return true = handled,
         // false = fall through to ghostty's default handling
    void* ghostty_embed_surface_new(const char* working_directory,
                                    const char* command);   // -> GtkWidget*
    void  ghostty_embed_surface_free(void* widget);         // drop strong ref
    char* ghostty_embed_surface_read_text(void* widget, uint32_t max_lines);
    void  ghostty_embed_surface_send_text(void* widget, const char* text);

Title/pwd/bell reach the host via GObject `notify::` signals on the
returned widget — no callback plumbing needed. The action hook covers
desktop_notification, child-exited/close-surface, and future needs
(progress reports, clipboard confirmation).

## Build integration

- Fork branch (submodule): new `-Demit-gtk-lib` option (pattern:
  `emit_*` fields, Config.zig:47-61) + `GhosttyLib.initStaticGtk/-Shared`
  variants rooted at the new shim file + `zig build lib-gtk` step.
  Invocation: `zig build lib-gtk -Dapp-runtime=gtk -Dversion-string=1.3.0-dev`
  (version-string needed: the fork's `xcframework-<sha>` tags break
  ghostty's git-describe version detection when HEAD sits on a tag).
- cmux side: `CGhosttyEmbed` system-library module in `linux/Sources/`,
  linker paths to `ghostty/zig-out/lib`. `GhosttySurfaceFactory` next to
  the VTE one behind `SurfaceRegistry`; selection via env/build flag
  first (`CMUX_TERM=ghostty`), flip the default once dogfood passes.
- License: ghostty MIT, cmux AGPL-3.0 — linking is fine.

## Submodule etiquette (reminder)

Work on a branch in `ghostty/` (`linux-gtk-embed`), push it to the fork
**before** committing a parent-repo pointer to it. NOTE: current
submodule HEAD `80d3fa0` is itself unreachable from any remote branch
(pre-existing orphan from the macOS side); pushing our branch rescues it.
Push access to manaflow-ai/ghostty from this machine is unverified —
resolve at the first submodule push (may need a hiasihaho fork +
.gitmodules discussion with the manaflow folks).

## Increments

1. ✅ **Skeleton + smoke test** (shipped 2026-07-16, ghostty `eb3fac7`) —
   build gates, `Application.default()` embed global, idle tick pump,
   `ghostty_embed_init` + `ghostty_embed_surface_new`, C harness
   (`linux/tests/ghostty-embed-smoke.c`). Human-verified: typing,
   execution, rendering, OSC title flow.
2. ✅ **cmux integration** (shipped 2026-07-17, ghostty `1131dbb` + cmux
   `7c02f2de9`) — per-surface working-directory/env via a cloned config
   (shim v2 signature below), `CGhosttyEmbed` Swift module gated on
   `CMUX_GHOSTTY=1`, `GhosttySurfaceFactory` with the CMUX_* identity
   env, `notify::title`/`notify::bell-ringing`/focus wired into the tab
   model, registry third surface kind with property-backed title/pwd.
   Verified: titles (visible + background→selected + cwd round-trip),
   session restore, splits. Launch via `linux/scripts/start.sh dev
   --ghostty`.
3. ✅ **Verb parity** (shipped 2026-07-17, ghostty `29abd52`/`df6a4f4` +
   cmux `e45317e6e`..`5d09f1bad`) — send/read verbs (dogfood cycle 6
   passed), shell-integration resources, dbus CRITICAL gate, window
   autoresize via the SurfaceScrolledWindow container export,
   close-request → pane auto-close.
4. ✅ **Default flip** (shipped 2026-07-17 after the resize-freeze fix,
   ghostty `ae8ba5f0a`) — shim-linked builds default to Ghostty
   terminals; `CMUX_TERM=vte` is the fallback; `start.sh` grew `--vte`
   and reports `ghostty(default)` in status. Leftovers:
   - `surface.send_text` / `send_key` / `read_text` for ghostty panes:
     shim exports over `core_surface` (`textCallback`, key events,
     `dumpTextLocked`; the embedded apprt's CAPI shows the pattern).
     This gates any ghostty-mode dogfood cycle — agents can't drive
     panes without them.
   - Eager background spawn: shells in never-shown workspaces don't
     start until the GLArea first maps (VTE pre-sizes 80×24 and spawns
     immediately). Needs offscreen realization or eager PTY sizing.
   - `GHOSTTY_RESOURCES_DIR` (zig-out share dir) so shell integration
     activates; CSS-provider attach from shim init (skipped `startup()`);
     gate the harmless `g_application_get_dbus_connection` CRITICAL at
     surface spawn (gtk_post_fork systemd scope path).
   - Watch for the one unreproduced title-flake from the first dev run
     (PROGRESS 2026-07-17); then ghostty-mode dogfood cycle, PARITY rows,
     default flip (keep VTE as fallback initially).

Current shim C API (`include/ghostty_gtk_embed.h`, branch
`linux-gtk-embed`):

    int   ghostty_embed_init(void);
    void* ghostty_embed_surface_new(const char* working_directory,
                                    const char** env_keys,
                                    const char** env_values,
                                    size_t env_len);   // -> GtkWidget* (floating)

Build: `zig build lib-gtk -Dapp-runtime=gtk -Dversion-string=1.3.0-dev`
→ `zig-out/lib/libghostty-gtk.so` + header; consumed by
`CMUX_GHOSTTY=1 swift build` in `linux/`.
