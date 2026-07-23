#!/usr/bin/env bash
# Parallel-dogfood harness: run several agents on DISJOINT work packages at
# once, each in its own git worktree + (optionally) its own scratch cmux
# instance + browser profile, then integrate their branches through a LOCAL
# BARE repo — without ever touching the human's live checkout or origin.
#
# The safety property is STATIC scope-disjointness: every package declares the
# files it may touch, and `check` refuses to proceed if two scopes overlap, so
# parallel branches merge conflict-free by construction. `collect` additionally
# asserts each branch changed only files within its declared scope.
#
#   pkg-harness.sh init [--from <repo|synthetic>]   # sandbox src + bare integration repo
#   pkg-harness.sh add <id> --scope "p1 p2 …"       # worktree + branch off base
#   pkg-harness.sh check                            # assert scopes pairwise-disjoint
#   pkg-harness.sh simulate <id> <marker>          # testbed: no-op in-scope work + report
#   pkg-harness.sh list                            # packages and status
#   pkg-harness.sh collect                         # reports + per-branch diffstat + scope compliance
#   pkg-harness.sh integrate                       # merge clean branches into base (via bare repo)
#   pkg-harness.sh verify-runtime <id> [<id> …]    # prove per-agent scratch instance + profile isolation
#   pkg-harness.sh teardown                         # worktrees + scratch instances + profiles + sandbox
#
# Sandbox root: $CMUX_PKG_SANDBOX (default ~/.local/state/cmux/pkg-sandbox).
# Nothing here runs in ~/cmux's git; the harness is self-contained under the sandbox.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="${CMUX_PKG_SANDBOX:-$HOME/.local/state/cmux/pkg-sandbox}"
SRC="$SANDBOX/src"
BARE="$SANDBOX/integration.git"
PKGDIR="$SANDBOX/.pkg"

cmd="${1:-help}"; shift || true

die() { echo "pkg-harness: $*" >&2; exit 1; }
say() { echo "▸ $*"; }
# The base branch packages fork from. `init` records it (the --from repo's
# current branch, so a real batch forks from linux-port, not a stale main);
# everything else reads it back. Falls back to main for old sandboxes.
BASE_REF="$(cat "$SANDBOX/.base" 2>/dev/null || echo main)"

# scope paths → normalized dir prefixes (trailing slash) or exact file paths.
_norm() { sed 's:/*$::' | sed 's:$:/:' ; }   # ensure trailing slash for prefix match

# Does file $1 fall under any of the newline-scope on stdin?
_in_scope() {
  local f="$1" p
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    p="${p%/}"
    [ "$f" = "$p" ] && return 0
    case "$f" in "$p"/*) return 0;; esac
  done
  return 1
}

# --- ADR-0013 (B): tags on the registry. Free-form labels per package,
# stored newline-separated in .pkg/<id>/tags, set by the orchestrator OR
# self-applied by an agent (append to its own tags file). They let you
# address and GROUP agents by tag rather than one-by-one by name.
_tags_of() { tr '\n' ' ' < "$PKGDIR/$1/tags" 2>/dev/null | sed 's/ *$//'; }
_has_tag() { grep -qxF "$2" "$PKGDIR/$1/tags" 2>/dev/null; }
# Emit package ids, optionally filtered by a leading `--tag <t>` in "$@".
_ids() {
  local want="" id
  # NB: `[ … ] && x=…` at statement level trips `set -e` when the test is
  # false — an `if` is the safe form (bit us on the no-filter path).
  if [ "${1:-}" = "--tag" ]; then want="${2:-}"; fi
  for id in $(ls "$PKGDIR" 2>/dev/null || true); do
    [ -z "$want" ] || _has_tag "$id" "$want" || continue
    echo "$id"
  done
}

# Reap ONE package's worktree + reserved profile + manifest entry. A live
# agent's own ad-hoc scratch instances are the agent's to clean (it made
# them with its own tags); the harness only owns the worktree it created.
_reap_one() {
  local id="$1" worktree branch
  [ -f "$PKGDIR/$id/meta" ] || { echo "  no such package: $id" >&2; return 1; }
  . "$PKGDIR/$id/meta"
  ( cd "$SRC" 2>/dev/null && git worktree remove --force "$worktree" 2>/dev/null ) || true
  rm -rf "$HOME/.local/share/cmux/profiles/$id" 2>/dev/null || true
  rm -rf "$PKGDIR/$id"
}

case "$cmd" in
init)
  from="synthetic"
  [ "${1:-}" = "--from" ] && from="$2"
  rm -rf "$SANDBOX"; mkdir -p "$SANDBOX" "$PKGDIR"
  # Base = the source repo's current branch (so a real batch forks from
  # whatever we're working on, e.g. linux-port), or main for the synthetic
  # testbed. Recorded for add/integrate to read back.
  if [ "$from" = "synthetic" ]; then BASE_REF="main"
  else BASE_REF="$(git -C "$from" symbolic-ref --short HEAD 2>/dev/null || echo main)"; fi
  echo "$BASE_REF" > "$SANDBOX/.base"
  if [ "$from" = "synthetic" ]; then
    # A tiny repo shaped like the port's parallel clusters, so the rehearsal
    # exercises real-looking disjoint scopes without touching real code.
    mkdir -p "$SRC"; ( cd "$SRC"
      git init -q; git config user.email harness@cmux; git config user.name pkg-harness
      mkdir -p browser keyboard sidebar tests
      echo "// browser subsystem" > browser/surfaces.txt
      echo "// keyboard subsystem" > keyboard/shortcuts.txt
      echo "// sidebar subsystem" > sidebar/views.txt
      echo "# tests" > tests/suite.txt
      echo "# shared — the collision hotspot (like CmuxApp.swift)" > SHARED.txt
      git add -A; git commit -qm "base: synthetic port-shaped repo"; git branch -M "$BASE_REF" )
  else
    [ -d "$from/.git" ] || die "--from $from is not a git repo"
    git clone -q "$from" "$SRC"; ( cd "$SRC"; git checkout -q "$BASE_REF" 2>/dev/null || true )
  fi
  git clone -q --bare "$SRC" "$BARE"
  ( cd "$SRC"; git remote add integration "$BARE" 2>/dev/null || true; git push -q integration "$BASE_REF" )
  say "sandbox ready: $SANDBOX (src + integration.git, base=$BASE_REF, from=$from)"
  ;;

add)
  id="${1:-}"; shift || true; [ -n "$id" ] || die "add needs an <id>"
  scope=""; want_build=0
  while [ $# -gt 0 ]; do case "$1" in
    --scope) scope="$2"; shift 2;;
    --build) want_build=1; shift;;    # code package: share shim + seed .build
    *) die "add: unknown arg $1";;
  esac; done
  [ -n "$scope" ] || die "add needs --scope \"p1 p2 …\""
  [ -d "$SRC" ] || die "run init first"
  wt="$SANDBOX/wt-$id"; br="pkg-$id"
  ( cd "$SRC"; git worktree add -q "$wt" -b "$br" "$BASE_REF" )
  if [ "$want_build" = 1 ]; then
    # Build-isolation (proven 2026-07-23): a code package's worktree needs
    # the ghostty shim + a Swift .build, but both can be SHARED cheaply so
    # the first build is incremental (~30s), not from-scratch (minutes):
    #   - shim: symlink to the main checkout's zig-out (identical on the
    #     same ghostty commit; no per-worktree zig build).
    #   - .build: btrfs reflink copy (~1s, copy-on-write — the worktree's
    #     build writes break extent sharing, so main's .build is untouched).
    # Only meaningful when --from was the real repo; a synthetic testbed
    # has neither, so guard on their presence.
    if [ -d "$ROOT/ghostty/zig-out" ] && [ -d "$wt/ghostty" -o ! -e "$wt/ghostty" ]; then
      mkdir -p "$wt/ghostty"; ln -sfn "$ROOT/ghostty/zig-out" "$wt/ghostty/zig-out" || true
    fi
    if [ -d "$wt/linux" ] && [ -d "$ROOT/linux/.build" ] && [ ! -e "$wt/linux/.build" ]; then
      cp -a --reflink=auto "$ROOT/linux/.build" "$wt/linux/.build" || true
    fi
  else
    # Build-free (tests/CLI) package: it never compiles, but lib.sh resolves
    # the CLI from the worktree's linux/.build, so a bare worktree left the
    # agent hand-symlinking it every time (batch-2 harness-friction note).
    # A symlink to the main build is right here — a tests-only package tests
    # the already-built main binary and never writes .build. Guard on the
    # worktree actually having a linux/ dir (a synthetic testbed does not),
    # or a failed ln aborts add under `set -e`.
    if [ -d "$wt/linux" ] && [ -d "$ROOT/linux/.build" ] && [ ! -e "$wt/linux/.build" ]; then
      ln -sfn "$ROOT/linux/.build" "$wt/linux/.build" || true
    fi
  fi
  mkdir -p "$PKGDIR/$id"
  printf '%s\n' $scope > "$PKGDIR/$id/scope"
  cat > "$PKGDIR/$id/meta" <<EOF
branch=$br
worktree=$wt
instance=pkg-$id
profile=pkg-$id
build=$want_build
status=open
EOF
  say "package '$id' → worktree $wt on branch $br$([ "$want_build" = 1 ] && echo ' (shim shared + .build seeded)')  (scope: $scope)"
  ;;

check)
  ids=$(ls "$PKGDIR" 2>/dev/null || true)
  [ -n "$ids" ] || die "no packages"
  overlap=0
  for a in $ids; do for b in $ids; do
    [ "$a" \< "$b" ] || continue
    while IFS= read -r pa; do [ -z "$pa" ] && continue; pa="${pa%/}"
      while IFS= read -r pb; do [ -z "$pb" ] && continue; pb="${pb%/}"
        if [ "$pa" = "$pb" ] || case "$pa/" in "$pb"/*) true;; *) false;; esac \
           || case "$pb/" in "$pa"/*) true;; *) false;; esac; then
          echo "  ✗ OVERLAP: '$a' ($pa) vs '$b' ($pb)"; overlap=1
        fi
      done < "$PKGDIR/$b/scope"
    done < "$PKGDIR/$a/scope"
  done; done
  [ "$overlap" = 0 ] && say "scopes are pairwise-disjoint — safe to dispatch in parallel" \
                     || die "scope overlap — resolve before dispatch (this is the guard working)"
  ;;

simulate)
  id="${1:-}"; marker="${2:-WORK}"; [ -n "$id" ] || die "simulate needs <id> <marker>"
  . "$PKGDIR/$id/meta"
  first=$(head -1 "$PKGDIR/$id/scope"); first="${first%/}"
  target="$worktree/$first"
  if [ -d "$target" ]; then target="$target/agent-note.txt"; else target="$worktree/$first"; fi
  echo "$marker by agent $id" >> "$target"
  ( cd "$worktree"; git add -A; git commit -qm "pkg-$id: $marker (in-scope: $first)"; git push -q integration "$branch" )
  sed -i "s/status=.*/status=done/" "$PKGDIR/$id/meta"
  # a minimal filled report (real agents fill the full template)
  cat > "$PKGDIR/$id/report.md" <<EOF
## pkg: $id    status: done
branch: $branch    files: $(cd "$worktree"; git diff --name-only "$BASE_REF"..HEAD | tr '\n' ' ')
what landed: simulated no-op ('$marker') within scope $first
tests: (testbed no-op)    gate: n/a
new gaps discovered: none
handoff: none
EOF
  say "simulated '$id': committed + pushed $branch"
  ;;

list)
  # list [--tag <t>] — optionally only packages carrying a tag.
  for id in $(_ids "$@"); do
    . "$PKGDIR/$id/meta"
    surf=$(cat "$PKGDIR/$id/surface" 2>/dev/null | awk '{print $1}')
    printf "  %-14s %-10s %s  pane=%s  tags=[%s]  scope=[%s]\n" "$id" "$status" "$branch" \
      "${surf:-?}" "$(_tags_of "$id")" "$(tr '\n' ' ' < "$PKGDIR/$id/scope")"
  done
  ;;

# --- ADR-0013 (B): tag management + tag-based addressing/grouping -------
tag)
  id="${1:-}"; shift || true
  [ -n "$id" ] && [ $# -gt 0 ] || die "tag needs <id> <tag>..."
  [ -d "$PKGDIR/$id" ] || die "no such package: $id"
  for t in "$@"; do grep -qxF "$t" "$PKGDIR/$id/tags" 2>/dev/null || echo "$t" >> "$PKGDIR/$id/tags"; done
  say "'$id' tags: [$(_tags_of "$id")]"
  ;;

untag)
  id="${1:-}"; shift || true
  [ -n "$id" ] && [ $# -gt 0 ] || die "untag needs <id> <tag>..."
  [ -f "$PKGDIR/$id/tags" ] || { say "'$id' has no tags"; exit 0; }
  for t in "$@"; do
    grep -vxF "$t" "$PKGDIR/$id/tags" > "$PKGDIR/$id/tags.tmp" 2>/dev/null || : > "$PKGDIR/$id/tags.tmp"
    mv "$PKGDIR/$id/tags.tmp" "$PKGDIR/$id/tags"
  done
  say "'$id' tags: [$(_tags_of "$id")]"
  ;;

tags)
  # tags            → every package and its tags
  # tags --tag <t>  → just the ids carrying <t> (the group), one per line
  if [ "${1:-}" = "--tag" ]; then
    _ids --tag "${2:-}"
  else
    for id in $(ls "$PKGDIR" 2>/dev/null || true); do
      printf "    %-16s [%s]\n" "$id" "$(_tags_of "$id")"
    done
  fi
  ;;

# --- ADR-0009: agent work visibility -----------------------------------
# Each agent records its own $CMUX_SURFACE_ID (from inside its pane, so it
# is authoritative) into .pkg/<id>/surface as step 1 of its task. These
# read it back so the orchestrator can find and review the right agent by
# name instead of walking the tree and guessing.
pane)
  id="${1:-}"; [ -n "$id" ] || die "pane needs an <id>"
  surf=$(cat "$PKGDIR/$id/surface" 2>/dev/null | awk '{print $1}')
  [ -n "$surf" ] || die "no surface recorded for '$id' (did the agent run the step-1 echo?)"
  echo "$surf"
  ;;

panes)
  # panes [--tag <t>] — the name→pane registry, optionally a tag's group.
  echo "  agent → pane (from each agent's recorded \$CMUX_SURFACE_ID):"
  for id in $(_ids "$@"); do
    surf=$(cat "$PKGDIR/$id/surface" 2>/dev/null | awk '{print $1}')
    printf "    %-16s %-40s tags=[%s]\n" "$id" "${surf:-<not recorded>}" "$(_tags_of "$id")"
  done
  ;;

review)
  # review <id> [lines]        → read one agent's live pane
  # review --tag <t> [lines]   → read EVERY pane in that tag group (the
  #                              ADR-0013 payoff: address a group at once)
  _review_one() {
    local id="$1" lines="${2:-40}"
    local surf; surf=$(cat "$PKGDIR/$id/surface" 2>/dev/null | awk '{print $1}')
    if [ -z "$surf" ]; then echo "── agent '$id' — no surface recorded (skip)"; return; fi
    echo "── agent '$id' pane ($surf) ─────────────────────────"
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_QUIET=1 \
      "$ROOT/linux/.build/debug/cmux" read-screen --surface "$surf" 2>&1 | tail -"$lines"
  }
  if [ "${1:-}" = "--tag" ]; then
    tag="${2:-}"; lines="${3:-40}"
    [ -n "$tag" ] || die "review --tag needs a <tag>"
    found=0
    for id in $(_ids --tag "$tag"); do found=1; _review_one "$id" "$lines"; echo; done
    [ "$found" = 1 ] || die "no agents tagged '$tag'"
  else
    id="${1:-}"; [ -n "$id" ] || die "review needs an <id> (or --tag <t>)"
    _review_one "$id" "${2:-40}"
  fi
  ;;

collect)
  fail=0
  for id in $(ls "$PKGDIR" 2>/dev/null || true); do
    . "$PKGDIR/$id/meta"
    echo "── $id ($status, $branch) ─────────────────────────"
    [ -f "$PKGDIR/$id/report.md" ] && sed 's/^/  /' "$PKGDIR/$id/report.md"
    changed=$(cd "$SRC"; git diff --name-only "$BASE_REF".."integration/$branch" 2>/dev/null || \
              git -C "$SANDBOX/wt-$id" diff --name-only "$BASE_REF"..HEAD)
    echo "  changed files:"; echo "$changed" | sed 's/^/    /'
    # scope compliance
    bad=""
    while IFS= read -r f; do [ -z "$f" ] && continue
      _in_scope "$f" < "$PKGDIR/$id/scope" || bad="$bad $f"
    done <<< "$changed"
    if [ -n "$bad" ]; then echo "  ✗ OUT-OF-SCOPE:$bad"; fail=1
    else echo "  ✓ all changes within declared scope"; fi
  done
  [ "$fail" = 0 ] && say "all packages scope-compliant" || die "scope violations above"
  ;;

integrate)
  ( cd "$SRC"; git fetch -q integration; git checkout -q "$BASE_REF"
    for id in $(ls "$PKGDIR" 2>/dev/null || true); do
      . "$PKGDIR/$id/meta"; [ "$status" = done ] || continue
      if git merge -q --no-edit "integration/$branch" 2>/dev/null; then
        echo "  ✓ merged $branch"
      else
        echo "  ✗ CONFLICT merging $branch — leaving base clean"; git merge --abort
      fi
    done
    git push -q integration "$BASE_REF"
    echo "  integration base now at: $(git rev-parse --short HEAD)" )
  say "integrated onto $BASE_REF in the bare repo (src + integration.git)"
  ;;

verify-runtime)
  [ $# -ge 1 ] || die "verify-runtime needs at least one <id>"
  echo "  proving per-agent runtime isolation (scratch instance + browser profile):"
  declare -A socks; ok=1
  for id in "$@"; do
    tag="pkgrt-$id"
    "$ROOT/linux/scripts/scratch.sh" start "$tag" >/dev/null 2>&1 || { echo "    $id: scratch start failed"; ok=0; continue; }
    eval "$("$ROOT/linux/scripts/scratch.sh" env "$tag")"
    disp=$("$ROOT/linux/scripts/scratch.sh" list 2>/dev/null | grep "^$tag:" | grep -oE ':[0-9]+' | head -1)
    "$ROOT/linux/.build/debug/cmux" browser open "about:blank" --profile "$id" >/dev/null 2>&1 || true
    profdir="$HOME/.local/share/cmux/profiles/$id"
    echo "    $id: socket=$CMUX_SOCKET_PATH display=$disp profile=$id"
    [ -n "${socks[$CMUX_SOCKET_PATH]:-}" ] && { echo "    ✗ socket collision!"; ok=0; }
    socks[$CMUX_SOCKET_PATH]=1
  done
  for id in "$@"; do "$ROOT/linux/scripts/scratch.sh" stop "pkgrt-$id" >/dev/null 2>&1 || true; done
  [ "$ok" = 1 ] && say "each agent got a distinct instance + profile (no collisions)" \
               || die "runtime isolation check failed"
  ;;

release)
  # Per-agent cleanup: run when an agent is DISMISSED (not when its branch
  # merges). Integration reads the pushed branch, so a merged package's
  # worktree can — and should — stay until its agent is truly done.
  id="${1:-}"; [ -n "$id" ] || die "release needs an <id> (the dismissed agent's package)"
  _reap_one "$id" && say "released '$id' (worktree + profile reaped; branch is safe in the bare repo)"
  ;;

teardown)
  # Full sandbox reap. THIS IS AGENT-DISMISSAL-TIME, not merge-time: it
  # removes every worktree, so any still-live agent loses its working dir
  # (the 2026-07-23 bug). `integrate` never needs the worktrees — the
  # branches live in the bare repo — so integrate first, keep worktrees for
  # the agents' lifetime, and teardown only when the whole batch is wound
  # down. Refuses if packages remain, unless --force.
  remaining=$(ls "$PKGDIR" 2>/dev/null | wc -l)
  if [ "$remaining" -gt 0 ] && [ "${1:-}" != "--force" ]; then
    echo "pkg-harness: $remaining package(s) still registered — their worktrees may belong to LIVE agents:" >&2
    ls "$PKGDIR" 2>/dev/null | sed 's/^/    /' >&2
    echo "  Release each dismissed agent with 'pkg-harness release <id>', or force the whole reap with 'pkg-harness teardown --force'." >&2
    exit 1
  fi
  for id in $(ls "$PKGDIR" 2>/dev/null || true); do _reap_one "$id"; done
  rm -rf "$SANDBOX"
  say "torn down: worktrees, profiles, sandbox (agents' own scratch instances are theirs to stop)"
  ;;

*)
  sed -n '2,30p' "$0"
  ;;
esac
