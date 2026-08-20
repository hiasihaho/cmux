#!/usr/bin/env bash
# Does this binary satisfy the terminal backend the user actually wants?
#
#   shim-guard.sh <binary> [ghostty|vte|auto]     # default: auto
#
# exit 0 = fine, 1 = mismatch (message on stderr), 2 = usage.
#
# Why this exists (2026-08-20): `swift build` WITHOUT CMUX_GHOSTTY=1
# produces a VTE-only binary. An agent compile-check did exactly that,
# start.sh's silent VTE fallback started the daily on it, and because
# eager background spawn is Ghostty-only, agent auto-resume then missed
# every background workspace. Nothing in the chain said a word. This
# guard is the thing that says the word — callers: start.sh, promote.sh.
set -euo pipefail

bin="${1:-}"; want="${2:-auto}"
[ -n "$bin" ] || { echo "usage: shim-guard.sh <binary> [ghostty|vte|auto]" >&2; exit 2; }

links_shim() { ldd "$1" 2>/dev/null | grep -q libghostty-gtk; }

# auto = what the USER asked for: CMUX_TERM wins (same precedence the app
# uses), then cmux.json's linux.terminalBackend, else "any" — a fresh
# clone with no config must not be blocked from starting.
resolve() {
    if [ -n "${CMUX_TERM:-}" ]; then echo "${CMUX_TERM,,}"; return; fi
    local cfg="${CMUX_CONFIG_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/cmux/cmux.json}"
    [ -f "$cfg" ] || { echo any; return; }
    python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("linux", {}).get("terminalBackend", "")
except Exception:
    v = ""
print((v or "any").lower())' "$cfg" 2>/dev/null || echo any
}

[ "$want" = "auto" ] && want="$(resolve)"

case "$want" in
    ghostty)
        if links_shim "$bin"; then exit 0; fi
        cat >&2 <<MSG
shim-guard: $(basename "$bin") has NO Ghostty shim, but the configured
backend is "ghostty". Starting it would silently downgrade you to VTE
terminals — and Ghostty-only eager background spawn means agent
auto-resume would miss every background workspace.

Fix:  cd $(cd "$(dirname "$0")/.." && pwd) && CMUX_GHOSTTY=1 swift build
Or start VTE deliberately with --vte.
MSG
        exit 1 ;;
    *) exit 0 ;;
esac
