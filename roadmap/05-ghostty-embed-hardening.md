# Ghostty embed hardening — resource lifecycle & security

Deferred deep-dive, opened 2026-07-20 from the scroll-snappiness session.
Full evidence trail: `docs/linux-port/PROGRESS.md` (2026-07-20 entry).
This is **not blocking** — the daily driver is snappy and correct for
normal use and normal dogfooding — but it has a security dimension worth
a focused pass later.

## The finding (recap)

Under **fast surface churn** (create + close within the ~1–2 s GLArea
realize window), embedded Ghostty surfaces leak resources:

- Clean measurement, realized surfaces: fresh 35 threads → 61 after the
  first surface (one-time Mesa GL driver thread pool, not a leak) →
  **stable at 61 across close cycles** — fully-realized surfaces close
  with zero per-cycle leak.
- Fast churn (close before realize): **~1.5 threads/close, does not
  settle** (44 → 74 stable). Leaked threads are GL-driver (Mesa
  `gl`/`gdrv`/`traceq`) → GL contexts aren't reclaimed.
- Ghostty teardown split: core-surface `deinit` (renderer + IO thread
  join) runs in **finalize** (refcount → 0); GL release runs in
  **`glareaUnrealize` → `displayUnrealized`**, which has an explicit
  "OpenGL resources and memory likely leaked" bail-out if `makeCurrent`
  fails. A close mid-init races both paths.

The dogfood cycle-7 "P1/P2 ReleaseSafe regression" was this leak reached
via an artificial 122-cycles-in-115 s soak, then **misdiagnosed** as a
build-mode bug. ReleaseSafe is fine; the record is corrected in PROGRESS.

## Why it may be security-relevant

1. **Local DoS via the control socket.** Surface create/close is a
   socket verb (`new-split`/`new-surface`/`close-surface`). An automated
   agent — the whole point of cmux — drives these. A buggy, runaway, or
   adversarial agent (or a prompt-injected one) can churn surfaces far
   faster than realize and exhaust threads / FDs / GL contexts →
   unresponsive or crashing app, taking down the human's whole session
   and every other pane with it. The socket is `0600` per-user, so this
   is a **local availability** issue, not remote — but "the agent can
   crash the human's workspace" is a real trust-boundary concern for a
   tool whose job is hosting semi-trusted agents.

2. **Optimizer-exposed memory unsafety.** `-Doptimize=ReleaseFast` SEGVs
   inside `ghostty_embed_init` at first surface creation (coredump
   2026-07-20 16:45). ReleaseFast disables Zig's undefined-value/safety
   fills, so a clean Debug/ReleaseSafe run that crashes under ReleaseFast
   strongly implies **uninitialized-memory read or use-after-free**
   somewhere in the embed init path (shim or the fork's App/Application
   setup). That is a memory-safety bug independent of the leak, and the
   kind that can be a corruption primitive. Worth an ASan/UBSan/valgrind
   pass regardless of whether we ever ship ReleaseFast.

3. **Unreclaimed GL memory.** The "resources likely leaked" bail-out is
   an acknowledged partial-teardown path; under churn it accretes
   GPU/driver memory, a slower exhaustion vector than threads.

## Deeper-investigation plan (when we pick this up)

- **Deterministic repro + harness.** Script the sub-realize churn (create
  then close within N ms, loop) and assert thread/FD/GL-context count
  returns to baseline. Land it as a soak test.
- **Sanitizers.** Build the shim with Zig sanitizer options and/or run
  cmux-adw + shim under `valgrind --tool=memcheck` and `--tool=helgrind`
  (the init path is threaded) to catch the ReleaseFast UB and any UAF in
  the close-during-init race.
- **Fix the race at the source.** Two levers: (a) cmux-side — don't tear
  a surface down while its core init is in flight (defer close until
  realize, or cancel init cleanly before dispose); (b) ghostty-side —
  make `glareaUnrealize` robust when `makeCurrent` fails, and ensure
  finalize joins threads even for a never-realized surface. Prefer (a)
  first (host-owned, no fork churn).
- **Defense-in-depth.** Rate-limit / serialize surface create+close on
  the socket dispatcher so no client (agent) can churn faster than
  teardown completes — a cheap DoS backstop independent of the root fix.
- **Coordinate with UPSTREAM.md.** If the GL-release/finalize gaps are in
  the fork's shared code, fold fixes into the manaflow suggestions the
  same way the resize-freeze Darwin-gate was.

## Severity / priority

Low urgency for the **human daily** (normal pane cadence never triggers
it). Medium for **dogfooding robustness** (soaks and fast QA loops hit
it). The security framing (agent-drivable local DoS + a memory-unsafety
smell) is the reason to give it a proper, unhurried pass rather than a
band-aid — treat it as a hardening milestone, not a quick fix.
