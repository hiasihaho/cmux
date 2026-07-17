# Prepared upstream suggestions (manaflow-ai)

Material ready to send to the manaflow folks — the human decides when
and what. Prepared 2026-07-17 after the resize-freeze fix.

## 1. Renderer fix PR (ready to open)

Branch **`fix-stale-frame-replay-gtk`** on hiasihaho/ghostty: exactly
one commit (`91024ab`, cherry-picked from our `ae8ba5f0a`) on top of the
manaflow base `80d3fa0`. Zero macOS behavior change by construction
(`comptime isDarwin()` — Darwin compiles the identical code as before).

Open it with:

```sh
cd ghostty && gh pr create --repo manaflow-ai/ghostty \
  --base main --head hiasihaho:fix-stale-frame-replay-gtk \
  --title "renderer: Darwin-gate the stale-frame replay during resize" \
  --body-file ../docs/linux-port/upstream-pr-body.md
```

Draft body: [upstream-pr-body.md](upstream-pr-body.md).

## 2. Optional mentions for the same conversation

- **The Linux embedding work exists**: branch `linux-gtk-embed` on
  hiasihaho/ghostty carries a GTK embedding shim (`zig build lib-gtk` →
  `libghostty-gtk.so` + `ghostty_gtk_embed.h`) that lets a foreign
  GTK4/libadwaita app host GhosttySurface widgets — cmux's Linux port
  self-hosts on it. All embed behavior is gated so standalone ghostty is
  unchanged. If manaflow wants Linux support in their cmux, this is the
  foundation; happy to walk through it.
- **Submodule hygiene**: the cmux repo's recorded ghostty SHA `80d3fa0`
  was unreachable from any branch on manaflow-ai/ghostty (orphaned —
  fresh clones can't fetch it). Our fork now hosts it; pushing a branch
  containing it to the manaflow fork would fix that for everyone.

## 3. Longer-term

- The fork is a squashed graft of upstream (histories unrelated; a
  `git merge-base` against ghostty-org/ghostty fails). If manaflow ever
  wants regular upstream syncs, content-level diffs (`git diff
  <upstream-commit> <fork-commit> -- src/`) are the workable tool — that
  is exactly how this bug was isolated.
