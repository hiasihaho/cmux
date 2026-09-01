#!/usr/bin/env bash
# Promote a side-built Ghostty shim to the canonical zig-out — safely,
# while an instance is RUNNING against the old one.
#
#   swap-shim.sh                # preflight → swap → verify → promote daily
#   swap-shim.sh --dry-run      # print the plan, change nothing
#   swap-shim.sh --no-promote   # swap + verify only, restart yourself later
#   swap-shim.sh --test         # also run system-top-smoke before promoting
#   swap-shim.sh --rollback     # put the previous shim back (and promote)
#   swap-shim.sh --build        # (re)build into the side prefix first
#
# WHY A WRAPPER AND NOT `mv`: a live cmux-adw has libghostty-gtk.so
# MAPPED. Rebuilding or copying over that path while it is mapped changes
# the bytes under the running process → SIGBUS, i.e. the human's daily
# instance dies mid-sentence. Every rule here exists so that cannot
# happen:
#
#   - the new shim is built to a SIDE prefix (default ghostty/zig-out-dev)
#   - the canonical file is moved ASIDE by rename(2), never overwritten,
#     so a running instance keeps its inode and its mapping stays valid
#   - only then is the new file renamed into the now-free path
#   - the result is verified (deps resolve, dlopen succeeds, no exported
#     symbol was lost) and rolled back AUTOMATICALLY if it is not
#
# Swapping the file is invisible to the running app: it takes effect at
# the next start. That restart is a user-approved checkpoint — promote.sh
# saves the daily's session, stops it, starts it on the new binary, and
# session restore brings layout, cwds and scrollback back (`claude
# --continue` resumes the agent in its pane).
#
# Exit: 0 done, 1 refused or a step failed, 2 usage/tooling.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FROM="$ROOT/ghostty/zig-out-dev"
TO="$ROOT/ghostty/zig-out"
LIB=libghostty-gtk.so
HEADER=ghostty_gtk_embed.h
# Proof that the .so is a real shim and that dlsym will find what cmux
# looks up at runtime. Keep this list to symbols cmux actually resolves.
REQUIRED_SYMBOLS=(ghostty_embed_init ghostty_embed_surface_new)

dry=false; promote=true; build=false; rollback=false; force=false
assume_yes=false; run_test=false; promote_args=()

while [ $# -gt 0 ]; do
    case "$1" in
        --from) FROM="$2"; shift ;;
        --to) TO="$2"; shift ;;
        --dry-run|-n) dry=true ;;
        --no-promote) promote=false ;;
        --test) run_test=true ;;
        --build) build=true ;;
        --rollback) rollback=true ;;
        --force) force=true ;;
        --yes|-y) assume_yes=true ;;
        --) shift; promote_args=("$@"); break ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "swap-shim: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
die()  { printf 'swap-shim: %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || { echo "missing tool: $1" >&2; exit 2; }; }
need nm; need ldd; need python3
run() { # echo, then execute unless --dry-run
    say "   \$ $*"
    $dry && return 0
    "$@"
}

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
cur_lib="$TO/lib/$LIB"
new_lib="$FROM/lib/$LIB"

# Exported text symbols, sorted — the basis of the regression guard.
exports() { nm -D --defined-only "$1" 2>/dev/null | awk '$2=="T"{print $3}' | sort; }

# dlopen the library in a THROWAWAY process (python3) and look up each
# symbol. Stronger than ldd: it resolves relocations the way the app's
# own dlopen will, and a crash here cannot hurt this script.
verify_loadable() {
    python3 - "$@" <<'PY'
import ctypes, sys
path, *syms = sys.argv[1:]
try:
    lib = ctypes.CDLL(path)          # ctypes adds RTLD_NOW: strict resolve
except OSError as exc:
    print("dlopen failed: %s" % exc); sys.exit(1)
for sym in syms:
    try:
        getattr(lib, sym)
    except AttributeError:
        print("symbol not found: %s" % sym); sys.exit(1)
sys.exit(0)
PY
}

# Which running processes map this exact path, and at which inode. They
# keep their old inode across the swap by construction — this is
# reported so the operator sees WHY a restart is the activating step.
mappers() {
    local path="$1" pid ino
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        grep -q " $path\$" /proc/"$pid"/maps 2>/dev/null || continue
        ino=$(awk -v p="$path" '$6==p {print $5; exit}' /proc/"$pid"/maps 2>/dev/null)
        echo "$pid $ino"
    done
}

# ---- self-hosting guard, BEFORE any mutation ----------------------------
# promote.sh has its own guard, but it would fire after the swap — the
# operator would be left half-done. Refuse up front instead.
if $promote && ! $dry && [ -n "${CMUX_SURFACE_ID:-}" ]; then
    my_sock="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
    daily_sock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/cmux.sock"
    if [ "$my_sock" = "$daily_sock" ]; then
        cat >&2 <<MSG
swap-shim: this shell lives INSIDE the daily instance, and promoting
restarts it — the shell (and this script) would die mid-restart.

Run it from a plain terminal (GNOME Terminal / Ghostty / a TTY), or from
a dev-instance pane, or swap now and restart later:

    linux/scripts/swap-shim.sh --no-promote
    # then, from outside the daily:  linux/scripts/promote.sh
MSG
        exit 1
    fi
fi

# ---- rollback -----------------------------------------------------------
if $rollback; then
    backup=$(ls -1t "$TO"/lib/"$LIB".pre-* 2>/dev/null | head -1) \
        || true
    [ -n "${backup:-}" ] || die "no backup to roll back to in $TO/lib (looked for $LIB.pre-*)"
    step "rolling back to $(basename "$backup")"
    run mv "$cur_lib" "$TO/lib/$LIB.superseded-$stamp"
    run mv "$backup" "$cur_lib"
    hdr_backup="$TO/include/$HEADER.pre-${backup##*.pre-}"
    if [ -f "$hdr_backup" ]; then
        run mv "$hdr_backup" "$TO/include/$HEADER"
    else
        say "   NOTE: no header backup for this stamp — $TO/include/$HEADER left as it is"
    fi
    $dry && { say "(dry run — nothing changed)"; exit 0; }
    say "   rolled back; the superseded shim is kept at $TO/lib/$LIB.superseded-$stamp"
    if $promote; then
        step "promoting the daily onto the rolled-back shim"
        exec "$ROOT/linux/scripts/promote.sh" "${promote_args[@]+"${promote_args[@]}"}"
    fi
    exit 0
fi

# ---- optional: build into the side prefix -------------------------------
# Never into $TO: that is the mapped path. The recipe is the documented
# one (PROGRESS 2026-09-01) — Debug, because ReleaseFast SIGSEGVs in
# ghostty_embed_init (2026-08-30).
if $build; then
    need zig
    step "building the shim into $FROM (side prefix — never the mapped one)"
    run env -C "$ROOT/ghostty" zig build lib-gtk -Dapp-runtime=gtk \
        -Dversion-string=1.3.0-dev --prefix "$FROM" \
        || die "shim build failed"
fi

# ---- preflight ----------------------------------------------------------
step "preflight"
[ -f "$new_lib" ] || die "no shim at $new_lib — build one first (--build), or point --from elsewhere"
[ -s "$new_lib" ] || die "$new_lib is empty"
[ -d "$TO/lib" ] || die "no canonical lib dir at $TO/lib"

if [ ! -f "$cur_lib" ]; then
    say "   no shim installed yet at $cur_lib — this is a first install"
    cur_exports=""
else
    cur_exports=$(exports "$cur_lib")
fi
new_exports=$(exports "$new_lib")
[ -n "$new_exports" ] || die "$new_lib exports no text symbols — not a usable shim"

# Same filesystem: a cross-device `mv` is copy+unlink, and copying ONTO a
# mapped path is exactly the SIGBUS we are avoiding. (We rename the old
# one away first, so the destination is free either way — but if these
# differ, something is not the layout this script was written for.)
if [ -f "$cur_lib" ] && [ "$(stat -c %d "$FROM/lib")" != "$(stat -c %d "$TO/lib")" ]; then
    $force || die "$FROM/lib and $TO/lib are on different filesystems — atomic rename impossible (--force to proceed anyway)"
    say "   WARNING: different filesystems — the move will be a copy (--force given)"
fi

# Symbol-regression guard: an incoming shim missing something the current
# one exports is a downgrade or a broken build, and the failure would
# surface much later as a runtime dlsym miss.
lost=$(comm -23 <(printf '%s\n' "$cur_exports") <(printf '%s\n' "$new_exports") | grep '^ghostty_' || true)
gained=$(comm -13 <(printf '%s\n' "$cur_exports") <(printf '%s\n' "$new_exports") | grep '^ghostty_' || true)
if [ -n "$lost" ]; then
    say "   incoming shim LOSES exports:"
    printf '     - %s\n' $lost
    $force || die "refusing a shim that drops exported symbols (--force to override)"
    say "   proceeding anyway (--force)"
fi
[ -n "$gained" ] && { say "   incoming shim GAINS:"; printf '     + %s\n' $gained; }
[ -z "$gained" ] && [ -z "$lost" ] && say "   exported symbols identical to the installed shim"

# An older side build is almost always a mistake (a stale prefix from a
# previous experiment).
if [ -f "$cur_lib" ] && [ "$cur_lib" -nt "$new_lib" ]; then
    $force || die "$new_lib is OLDER than the installed shim — stale side prefix? (--force to override)"
    say "   WARNING: installing an older shim (--force given)"
fi

say "   installed : $(stat -c '%s bytes  inode %i  %y' "$cur_lib" 2>/dev/null || echo none)"
say "   incoming  : $(stat -c '%s bytes  inode %i  %y' "$new_lib")"

# Verify the INCOMING shim before it goes anywhere near the canonical path.
if verify_loadable "$new_lib" "${REQUIRED_SYMBOLS[@]}"; then
    say "   incoming shim dlopens and exports ${REQUIRED_SYMBOLS[*]}"
else
    die "incoming shim failed verification — not swapping"
fi

# Resource tree drift: share/ghostty (shell integration, themes,
# terminfo) belongs to the same build as the .so. Warn rather than swap
# it: the daily resolves GHOSTTY_RESOURCES_DIR to $TO/share/ghostty, and
# a half-updated resources dir is its own class of confusion.
if [ -d "$FROM/share/ghostty" ] && [ -d "$TO/share/ghostty" ]; then
    drift=$(LC_ALL=C diff -rq "$TO/share/ghostty" "$FROM/share/ghostty" 2>/dev/null \
        | grep -v '^Only in .*: doc$' | head -5)
    if [ -n "$drift" ]; then
        say "   NOTE: share/ghostty differs between the prefixes:"
        printf '     %s\n' "$drift"
        say "     (shell integration/themes live there; copy by hand if the change matters)"
    fi
fi

# Who is running against the old file — informational, and the reason the
# restart is a separate, approved step.
while read -r pid ino; do
    [ -n "$pid" ] || continue
    say "   running: pid $pid maps this path at inode $ino (keeps it until restart)"
done < <(mappers "$cur_lib")

backups=$(ls -1 "$TO"/lib/"$LIB".pre-* 2>/dev/null | wc -l)
[ "$backups" -gt 0 ] && say "   $backups previous backup(s) already in $TO/lib — delete old ones when you trust the swap"

# ---- confirm ------------------------------------------------------------
say ""
say "Plan:"
say "  1. rename  $cur_lib  →  $LIB.pre-$stamp   (running instances keep this inode)"
say "  2. rename  $new_lib  →  $cur_lib"
say "  3. install $HEADER alongside it"
say "  4. verify (dlopen + symbols); auto-rollback on failure"
$run_test && say "  5. run system-top-smoke on an ISOLATED instance"
$promote  && say "  $($run_test && echo 6 || echo 5). promote.sh — save session, restart the daily, restore layout" \
          || say "  (not promoting: the swap takes effect at the next start)"
say ""

if $dry; then
    say "(dry run — nothing was changed)"
    exit 0
fi
if ! $assume_yes; then
    if [ -t 0 ]; then
        read -r -p "Proceed? [y/N] " answer
        case "$answer" in y|Y|yes|YES) ;; *) say "aborted"; exit 1 ;; esac
    else
        die "not a terminal and --yes not given — refusing to swap unattended"
    fi
fi

# ---- the swap -----------------------------------------------------------
step "swapping"
if [ -f "$cur_lib" ]; then
    run mv "$cur_lib" "$TO/lib/$LIB.pre-$stamp" || die "could not move the installed shim aside"
fi
run mv "$new_lib" "$cur_lib" || die "could not move the new shim into place"

# Header: the build-time half. cmux resolves the pid accessor by dlsym so
# a stale header does not break the build, but keeping them in step is
# what makes the next reader's `grep` tell the truth.
hdr_src="$FROM/include/$HEADER"
[ -f "$hdr_src" ] || hdr_src="$ROOT/ghostty/include/$HEADER"
if [ -f "$hdr_src" ]; then
    mkdir -p "$TO/include"
    [ -f "$TO/include/$HEADER" ] && run mv "$TO/include/$HEADER" "$TO/include/$HEADER.pre-$stamp"
    run cp "$hdr_src" "$TO/include/$HEADER"
    say "   header from $hdr_src"
else
    say "   NOTE: no $HEADER found to install (looked in $FROM/include and ghostty/include)"
fi

# ---- verify, or undo ----------------------------------------------------
step "verifying the installed shim"
missing_deps=$(ldd "$cur_lib" 2>/dev/null | grep "not found" || true)
if [ -n "$missing_deps" ] || ! verify_loadable "$cur_lib" "${REQUIRED_SYMBOLS[@]}"; then
    say "   FAILED:"
    [ -n "$missing_deps" ] && printf '     %s\n' "$missing_deps"
    step "rolling back automatically"
    mv "$cur_lib" "$FROM/lib/$LIB"
    [ -f "$TO/lib/$LIB.pre-$stamp" ] && mv "$TO/lib/$LIB.pre-$stamp" "$cur_lib"
    [ -f "$TO/include/$HEADER.pre-$stamp" ] && mv "$TO/include/$HEADER.pre-$stamp" "$TO/include/$HEADER"
    die "the new shim did not verify in place — restored the previous one, nothing else changed"
fi
say "   dlopen ok, deps resolve, inode now $(stat -c %i "$cur_lib")"
say "   previous shim kept at $TO/lib/$LIB.pre-$stamp"
say "   undo any time with:  linux/scripts/swap-shim.sh --rollback"

# ---- optional isolated proof -------------------------------------------
# Runs against its own instance on its own X display, so this proves the
# new shim works WITHOUT touching the daily.
if $run_test; then
    step "system-top-smoke (isolated instance — the daily is untouched)"
    if [ -x "$ROOT/linux/.build/debug/cmux-adw" ]; then
        "$ROOT/linux/tests/system-top-smoke.sh" || {
            say ""
            say "The suite failed. The swap is still in place; roll back with:"
            say "    linux/scripts/swap-shim.sh --rollback"
            exit 1
        }
    else
        say "   skipped: no binary at linux/.build/debug/cmux-adw (build first)"
    fi
fi

# ---- promote ------------------------------------------------------------
if ! $promote; then
    say ""
    say "Swap done. The running instance still maps the OLD inode — it picks"
    say "up the new shim at its next start:  linux/scripts/promote.sh"
    exit 0
fi

step "promoting the daily onto the new shim"
"$ROOT/linux/scripts/promote.sh" "${promote_args[@]+"${promote_args[@]}"}" || {
    say ""
    say "promote.sh failed. The shim swap itself is fine and reversible:"
    say "    linux/scripts/swap-shim.sh --rollback"
    exit 1
}

# ---- post-promote evidence ---------------------------------------------
step "checking what the restarted daily actually maps"
sleep 1
now_ino=$(stat -c %i "$cur_lib")
found=false
while read -r pid ino; do
    [ -n "$pid" ] || continue
    found=true
    if [ "$ino" = "$now_ino" ]; then
        say "   pid $pid maps the NEW shim (inode $ino) — active"
    else
        say "   pid $pid still maps inode $ino (old) — an instance that did not restart"
    fi
done < <(mappers "$cur_lib")
$found || say "   no running instance maps the shim yet (still starting?)"

cli="$ROOT/linux/.build/debug/cmux"
if [ -x "$cli" ]; then
    say ""
    say "Ghostty pid attribution should be live now — check with:"
    say "    $cli --json rpc system.top | python3 -m json.tool | grep -m3 top_level_pids -A2"
fi
