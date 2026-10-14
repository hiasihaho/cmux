# `cmux omx` stale-dead session pointer — analysis (banked for later pickup)

Status: **analysis only, not implemented.** Requested by qmp-vision (via qmp-51),
relayed on hias' request, 2026-10. Repro env: Fedora kernel 7.1.0 fc43, Node
v22.21.1, OMX v0.21.0, Codex CLI 0.154.0.

## Repro

- `cmux omx --yolo` aborted:
  `[omx] session pointer launch aborted: session_pointer_unusable` /
  `Error: Selected session pointer is stale-dead and is preserved.`
- Cause: OMX's selected pointer `<cwd>/.omx/state/session.json` pointed at a
  verified-dead session (~2 weeks old, pid gone). OMX correctly detected it
  stale-dead and **refused to clobber it** (good, conservative).
- OMX's own recovery is broken here: `omx session pointer recover --cwd <path>`
  → `{"status":"unsupported","recovered":false,"reason":"Atomic no-replace
  recovery rename is unsupported on this platform."}`. So OMX cannot self-recover
  and `cmux omx` is wedged. Manual fix: move `session.json` aside (a prior
  `.stale-` backup already existed → a human hit this before), then relaunch.

## Boundary: what `cmux omx` is

`cmux omx` is a sibling-team **launcher** (like `cmux omc`, `cmux codex-teams`):
resolves the omx binary, writes a tmux-compat shim, spawns OMX as a teammate
split. This repo has OMX-HUD plumbing (`.omx/hud-config.json`) but **no code
touching `.omx/state/session.json` / "session pointer" / "stale-dead"** — that
whole mechanism lives inside OMX (external). The abort happens inside the
spawned omx process; `cmux omx` only sees it exit.

## Q1 — wrapper concern or OMX-upstream bug? Both, two layers

- **The real bug is OMX-upstream:** OMX correctly refuses to clobber a
  verified-dead pointer, but its recovery is broken on this platform, leaving
  the user wedged. Flag upstream.
- **Narrow wrapper safety-net (labeled robustness, not a fix of OMX):**
  `cmux omx` could recognise the exact signature (`session_pointer_unusable` +
  "stale-dead … preserved" + `recover` returning `unsupported`) and either
  (a) surface the precise one-liner, or (b) perform the move-aside+relaunch
  itself. Safe in THIS signature because OMX already did the verified-dead
  check; preserved only because its rename is broken. Prefer **(a) surface**
  first; (b) should re-verify dead-ness (pid gone) itself, not trust the parse.
  Must NOT blindly clobber in the general case — OMX preserves on purpose.

## Q2 — why "unsupported on this platform" on Linux + Node v22?

Runtime gap, **not** the OS. The kernel (7.1.0) has had
`renameat2(RENAME_NOREPLACE)` since 3.15, but **Node exposes no binding for it**
— `fs.rename`/`renameSync` map to POSIX `rename(2)`, which **overwrites**; Node
has no `RENAME_NOREPLACE`. Almost certainly OMX tries to rename the stale
pointer to a **fixed** backup name *without overwriting an existing one*, a
`.stale-` backup already existed, a plain rename would clobber it, OMX refuses,
and — lacking a no-replace primitive in Node — declares "unsupported on this
platform." The wording is misleading (it's Node, not Linux/overlayfs; Node
couldn't call `renameat2` regardless of the filesystem).

## Q3 — the proper generic recovery (portable, lock-guarded)

The atomic-no-replace requirement is **self-inflicted** (it only exists because
the design reuses a *fixed* backup filename). Dissolve it:

1. **Lock the critical section** — portable `fs.open(lockPath, 'wx')`
   (O_CREAT|O_EXCL) or `flock`, with stale-lock stealing (steal if the lock's
   recorded pid is dead or it's older than a timeout). Serialises concurrent
   launches so two don't both move-aside/relaunch and race.
2. **Re-verify dead under the lock** — confirm the referenced pid is gone;
   never recover a live session.
3. **Move aside to a UNIQUE name** — `session.json → session.<ISO-ts>.stale.json`.
   Renaming to a guaranteed-nonexistent name is atomic AND portable with plain
   `fs.rename` — no `renameat2`, no overwrite risk, never collides with a prior
   backup. (If a *fixed* no-replace name is truly needed, `fs.link(old,backup)`
   + `fs.unlink(old)` gives portable EEXIST-on-collision via POSIX `link`.)
4. **Relaunch** (fresh pointer / let OMX recreate it), then release the lock.

So: **verified-dead → lock → unique-timestamped move-aside (plain rename) →
relaunch → unlock.** Durable home is OMX-upstream (it owns the pointer and the
dead-check); the `cmux omx` wrapper's honest scope is the Q1 safety-net.

## Pickup checklist

- [ ] Flag OMX-upstream: broken recovery + misleading "platform" wording
      (root cause: Node lacks `renameat2` + a fixed backup name).
- [ ] Decide `cmux omx` wrapper scope: surface the one-liner (low risk) vs
      signature-gated auto move-aside (re-verify dead first).
- [ ] If implemented in cmux: red-first, labeled robustness, GAPS + PROGRESS.
