# Package report — <pkg-id>

Fill every field. The frame is fixed so N reports converge; the prose is
yours. The integrator reads this + your branch diff, nothing else.

- **status:** done | partial | blocked
- **branch:** pkg-<id>   **worktree:** <path>
- **declared scope:** <the paths you were allowed to touch>
- **files changed:** <list>   ⟵ must be ⊆ declared scope (the harness asserts this)

## What landed
<prose: what you implemented, the approach, any deviation from the task>

## Verification
- tests run: <suite + result line, e.g. "ui-commands-smoke: 49 passed, 0 failed">
- gate: <pass | fail | n/a>
- how you tested in isolation: <scratch instance tag / browser profile used>

## Docs (same-commit rule)
- PARITY.md: <updated? which row>
- GAPS.md: <row removed / added?>
- PROGRESS.md: <entry written?>
- other trackers (UX-PARITY, PARITY-DASHBOARD ledger): <as needed>

## New gaps discovered
<anything you found that isn't yours to fix — feeds GAPS / the survey ledger>

## Handoff
<the ONE thing the integrator must know before merging your branch>
