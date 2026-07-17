## Problem

The anti-flash change that re-presents the last completed frame during
resize (`renderer/generic.zig`, introduced with the stale-frame-replay
work) permanently freezes terminal surfaces on Linux/GTK after the first
window resize: the surface keeps compositing its stale, old-size frame
while input still reaches the PTY, so the terminal *looks* dead.

Reproduction (Linux, any GTK build of this fork): open a window, resize
it, type — output never appears; the content stays at the pre-resize
size. Upstream ghostty at the same vintage does not exhibit this.

## Root cause

Both replay guards early-return from `drawFrame` when a synchronous draw
coincides with a size change, on the assumption that async display-link
draws will soon deliver the new frame ("let the normal render loop catch
up on the next tick"). That holds on macOS (CoreAnimation display link),
but on GTK **every** draw is synchronous — `drawFrame(true)` from the
GLArea render callback — so the guard latches after the first resize and
every subsequent draw re-presents the stale frame.

## Fix

Wrap both guards in `comptime builtin.target.os.tag.isDarwin()`:

- macOS compiles the identical code as before this patch — the
  anti-flash behavior is fully preserved.
- Non-Darwin targets get the pre-patch draw path back.

## Verification

- Linux standalone GTK build of this fork: froze before, survives
  aggressive resize/type cycles after (Debug and ReleaseFast).
- Embedded GTK build (cmux Linux port hosts GhosttySurface widgets):
  same before/after result.
- macOS: no behavioral change possible by construction (comptime gate).
