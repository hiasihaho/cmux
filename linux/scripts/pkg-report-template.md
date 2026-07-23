# Package report — <pkg-id>

Fill every field. The frame is fixed so N reports converge; the prose is
yours. The integrator reads this + your branch diff, nothing else — so
anything important that *isn't* in a field is effectively invisible to the
main session. When in doubt, put it in **Findings** or **Escalations**.

- **status:** done | partial | blocked
- **branch:** pkg-<id>   **worktree:** <path>
- **surface:** <your $CMUX_SURFACE_ID — recorded to .pkg/<id>/surface as step 1>
- **declared scope:** <the paths you were allowed to touch>
- **files changed:** <list>   ⟵ must be ⊆ declared scope (the harness asserts this)

## What landed
<prose: what you implemented, the approach, any deviation from the task>

## Verification
- tests run: <suite + result line, e.g. "ui-commands-smoke: 49 passed, 0 failed">
- gate: <pass | fail | n/a>
- how you tested in isolation: <scratch instance tag / browser profile used>

## Findings
<anything you learned that the main session should know — corrected a
premise, discovered how something actually works, a non-obvious gotcha.
The most valuable outputs of a batch usually live here.>

## Product bugs discovered
<real defects in the code/product (not your package) — file, symptom,
suspected cause. These get escalated to GAPS/UPSTREAM.>

## Honest limitations / skips
<what you could NOT verify and why (missing binary, needs auth, env can't
reach it). A clear skip beats a fake pass.>

## Harness friction
<what made this harder than it needed to be — the harness itself is the
thing we improve from this. (This field produced the .build-symlink fix.)>

## Docs (same-commit rule) — for the integrator
<PARITY / GAPS / PROGRESS / other trackers you'd have the integrator
update; you don't touch shared trackers, the integrator does.>

## Escalations / handoff
<the ONE thing the integrator must know or decide before merging.>
