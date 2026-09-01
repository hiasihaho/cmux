#!/usr/bin/env bash
# swap-shim.sh — the wrapper that installs a side-built Ghostty shim over
# the canonical one while an instance may be running against it.
#
# The property under test is the one that protects the human's daily:
# the installed file is moved ASIDE by rename, never overwritten, so the
# OLD inode survives under the backup name (a mapped .so whose bytes
# change SIGBUSes the process that maps it). Plus the guards that stop a
# bad shim from being installed at all.
#
# Runs entirely on fake libraries in a temp dir — no cmux instance, no X
# display, and the real ghostty/zig-out is never touched.
#
#   swap-shim-smoke.sh
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="swap-shim-smoke"
HERE="$(cd "$(dirname "$0")" && pwd)"
SWAP="$HERE/../scripts/swap-shim.sh"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1 — $2"; fail=$((fail + 1)); }
expect() { # name, want, got
    [ "$2" = "$3" ] && ok "$1" || bad "$1" "wanted '$2', got '$3'"
}

[ -x "$SWAP" ] || { echo "$SUITE_NAME: no $SWAP" >&2; exit 2; }
command -v gcc >/dev/null || { echo "$SUITE_NAME: gcc needed to build fixture libs" >&2; exit 2; }

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/zig-out/lib" "$TMP/zig-out/include" "$TMP/side/lib" "$TMP/side/include"
TARGET="$TMP/zig-out/lib/libghostty-gtk.so"
SOURCE="$TMP/side/lib/libghostty-gtk.so"

# Fixture shims. The real one exports ~13 ghostty_embed_* symbols; three
# is enough to exercise superset/subset logic.
mklib() { # out, extra-body
    printf 'void ghostty_embed_init(void){} void ghostty_embed_surface_new(void){} %s\n' "$2" \
        | gcc -shared -fPIC -x c - -o "$1" 2>/dev/null
}
mklib "$TMP/old.so"     'void ghostty_embed_legacy(void){}'
mklib "$TMP/newer.so"   'void ghostty_embed_legacy(void){} void ghostty_embed_surface_pid(void){}'
mklib "$TMP/regress.so" ''                       # drops ghostty_embed_legacy
# Links fine, dlopens NEVER: an undefined symbol resolved only at RTLD_NOW.
printf 'extern void definitely_not_here(void);\nvoid ghostty_embed_init(void){definitely_not_here();}\nvoid ghostty_embed_surface_new(void){}\nvoid ghostty_embed_legacy(void){}\n' \
    | gcc -shared -fPIC -x c - -o "$TMP/broken.so" 2>/dev/null
printf '// fixture header\n' > "$TMP/side/include/ghostty_gtk_embed.h"
printf '// OLD header\n'     > "$TMP/zig-out/include/ghostty_gtk_embed.h"

swap() { "$SWAP" --from "$TMP/side" --to "$TMP/zig-out" --no-promote --yes "$@"; }
install_fixture() { cp "$1" "$TARGET"; cp "$2" "$SOURCE" 2>/dev/null || true; }

# --- 1: nothing to install ----------------------------------------------
cp "$TMP/old.so" "$TARGET"
rm -f "$SOURCE"
swap >/dev/null 2>&1
expect "missing side shim is refused" "1" "$?"

# --- 2: a dry run changes nothing ---------------------------------------
install_fixture "$TMP/old.so" "$TMP/newer.so"
before=$(stat -c %i "$TARGET")
swap --dry-run >/dev/null 2>&1
rc=$?
expect "dry run exits 0" "0" "$rc"
expect "dry run leaves the installed shim alone" "$before" "$(stat -c %i "$TARGET")"
expect "dry run leaves the side shim alone" "yes" "$([ -f "$SOURCE" ] && echo yes || echo no)"

# --- 3: a shim that DROPS exports is refused ----------------------------
install_fixture "$TMP/old.so" "$TMP/regress.so"
before=$(stat -c %i "$TARGET")
out=$(swap 2>&1); rc=$?
expect "dropped exports refused" "1" "$rc"
expect "  … and names the lost symbol" "yes" \
    "$(echo "$out" | grep -q ghostty_embed_legacy && echo yes || echo no)"
expect "  … and installs nothing" "$before" "$(stat -c %i "$TARGET")"

# --- 4: --force is the documented override ------------------------------
install_fixture "$TMP/old.so" "$TMP/regress.so"
before=$(stat -c %i "$TARGET")
swap --force >/dev/null 2>&1
expect "--force installs the downgrade anyway" "changed" \
    "$([ "$(stat -c %i "$TARGET")" != "$before" ] && echo changed || echo unchanged)"

# --- 5: a shim that cannot dlopen is refused BEFORE the swap ------------
rm -f "$TMP"/zig-out/lib/*.pre-*
install_fixture "$TMP/old.so" "$TMP/broken.so"
before=$(stat -c %i "$TARGET")
out=$(swap 2>&1); rc=$?
expect "unloadable shim refused" "1" "$rc"
expect "  … before touching the installed one" "$before" "$(stat -c %i "$TARGET")"
expect "  … and says why" "yes" \
    "$(echo "$out" | grep -qi "dlopen failed\|failed verification" && echo yes || echo no)"

# --- 6: the happy path, and the inode property that protects the daily --
rm -f "$TMP"/zig-out/lib/*.pre-* "$TMP"/zig-out/include/*.pre-*
printf '// OLD header\n' > "$TMP/zig-out/include/ghostty_gtk_embed.h"
install_fixture "$TMP/old.so" "$TMP/newer.so"
old_inode=$(stat -c %i "$TARGET")
out=$(swap 2>&1); rc=$?
expect "swap succeeds" "0" "$rc"
expect "  … announces the gained symbol" "yes" \
    "$(echo "$out" | grep -q "ghostty_embed_surface_pid" && echo yes || echo no)"
expect "  … installs a different inode" "changed" \
    "$([ "$(stat -c %i "$TARGET")" != "$old_inode" ] && echo changed || echo unchanged)"
backup=$(ls -1 "$TMP"/zig-out/lib/libghostty-gtk.so.pre-* 2>/dev/null | head -1)
expect "  … keeps a backup" "yes" "$([ -n "$backup" ] && echo yes || echo no)"
# THE property: a process that mapped the old file still maps that inode.
expect "  … and the OLD inode survives under the backup name" "$old_inode" \
    "$(stat -c %i "$backup" 2>/dev/null)"
expect "  … consumes the side shim" "gone" \
    "$([ -f "$SOURCE" ] && echo present || echo gone)"
expect "  … installs the new header" "// fixture header" \
    "$(head -1 "$TMP/zig-out/include/ghostty_gtk_embed.h")"
expect "  … keeps the old header as a backup" "yes" \
    "$(ls "$TMP"/zig-out/include/ghostty_gtk_embed.h.pre-* >/dev/null 2>&1 && echo yes || echo no)"

# --- 7: rollback puts the previous shim back ----------------------------
out=$("$SWAP" --from "$TMP/side" --to "$TMP/zig-out" --no-promote --yes --rollback 2>&1)
expect "rollback exits 0" "0" "$?"
expect "  … restores the ORIGINAL inode" "$old_inode" "$(stat -c %i "$TARGET")"
expect "  … restores the old header" "// OLD header" \
    "$(head -1 "$TMP/zig-out/include/ghostty_gtk_embed.h")"
expect "  … keeps the superseded shim rather than deleting it" "yes" \
    "$(ls "$TMP"/zig-out/lib/libghostty-gtk.so.superseded-* >/dev/null 2>&1 && echo yes || echo no)"

# --- 8: unattended use must be explicit ---------------------------------
install_fixture "$TMP/old.so" "$TMP/newer.so"
"$SWAP" --from "$TMP/side" --to "$TMP/zig-out" --no-promote </dev/null >/dev/null 2>&1
expect "no tty and no --yes is refused" "1" "$?"

echo
echo "$SUITE_NAME: $pass passed, $fail failed"
[ "$fail" = 0 ]
