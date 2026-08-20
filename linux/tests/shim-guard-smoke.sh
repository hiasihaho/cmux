#!/usr/bin/env bash
# Shim guard — the binary that gets STARTED must match the backend the
# user asked for. Regression cover for 2026-08-20: a plain `swift build`
# (agent compile-check) silently dropped the Ghostty shim, start.sh fell
# back to VTE without a word, and the daily came up VTE-only — which in
# turn broke agent auto-resume for every background workspace.
#
#   shim-guard-smoke.sh
#
# Exit: 0 all passed, 1 an assertion failed.
SUITE_NAME="shim-guard-smoke"
HERE="$(cd "$(dirname "$0")" && pwd)"
GUARD="$HERE/../scripts/shim-guard.sh"
BIN="$HERE/../.build/debug/cmux-adw"
pass=0; fail=0
ok()  { echo "  PASS  $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL  $1 — $2"; fail=$((fail + 1)); }
check() { # name, expected-exit, args...
    local name="$1" want="$2"; shift 2
    "$GUARD" "$@" >/dev/null 2>&1; local got=$?
    [ "$got" = "$want" ] && ok "$name" || bad "$name" "exit $got, wanted $want"
}

[ -x "$GUARD" ] || { echo "$SUITE_NAME: no $GUARD" >&2; exit 1; }
[ -x "$BIN" ] || { echo "$SUITE_NAME: build first (cd linux && swift build)" >&2; exit 1; }

# A shim-linked binary satisfies both ghostty and auto.
check "shim binary passes --backend ghostty" 0 "$BIN" ghostty
check "shim binary passes auto"              0 "$BIN" auto

# /bin/true stands in for a shim-less build: refused when ghostty is
# wanted, fine when the user explicitly asked for VTE.
check "shim-less binary REFUSED for ghostty" 1 /bin/true ghostty
check "shim-less binary allowed for vte"     0 /bin/true vte

# auto resolves from config: terminalBackend=ghostty must refuse a
# shim-less binary (the exact 2026-08-20 hole), vte must accept it.
cfg=$(mktemp); trap 'rm -f "$cfg"' EXIT
printf '{"linux":{"terminalBackend":"ghostty"}}' > "$cfg"
export CMUX_CONFIG_FILE="$cfg"
check "config ghostty + shim-less REFUSED" 1 /bin/true auto
printf '{"linux":{"terminalBackend":"vte"}}' > "$cfg"
check "config vte + shim-less allowed" 0 /bin/true auto
unset CMUX_CONFIG_FILE

echo "== $SUITE_NAME: $pass passed, $fail failed"
[ "$fail" = 0 ]
