#!/usr/bin/env bash
# Shared-CLI pre-socket behavior (roadmap/08 items 2 + 5): `cmux open`
# must parse file:// URLs into filesystem paths (not treat the scheme as
# a relative path) and fail nonzero; `cmux hooks opencode install` must
# find the bundled plugin from the Linux .build layout (the repo-fallback
# walk needs 5 hops there). No instance needed — everything here resolves
# before a socket connection.
#
#   cli-open-smoke.sh
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
SUITE_NAME="cli-open-smoke"
APP_ID_SUFFIX="cliopentest"
PAGE_PORT=8437   # unique X display only; no instance, no fixture server
source "$(dirname "$0")/lib.sh"

CLIENV=(env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_QUIET=1)

# --- file:// parsing -----------------------------------------------------
out=$(cd /tmp && "${CLIENV[@]}" "$CLI" open "file:///nonexistent/feedx.html" 2>&1)
rc=$?
case "$out" in
    *"Path does not exist: /nonexistent/feedx.html"*)
        ok "file:// URL decodes to its filesystem path" ;;
    *)  bad "file:// decode" "got: $out" ;;
esac
[ "$rc" -ne 0 ] && ok "open error exits nonzero" || bad "open exit code" "expected nonzero, got $rc"

out=$("${CLIENV[@]}" "$CLI" open "file://" 2>&1)
rc=$?
case "$out" in
    *"Invalid file:// URL"*) ok "empty file:// URL rejected" ;;
    *) bad "empty file:// URL" "got: $out (rc=$rc)" ;;
esac

# --- bundled-plugin repo fallback from the .build layout -----------------
FAKEHOME=$(mktemp -d /tmp/cmux-cliopentest-home.XXXXXX)
out=$(cd /tmp && "${CLIENV[@]}" HOME="$FAKEHOME" "$CLI" hooks opencode install 2>&1 | head -1)
case "$out" in
    *"bundled opencode-plugin.js not found"*)
        bad "plugin repo fallback" "walk still misses the repo root: $out" ;;
    *cmux*plugin*|*"Will write"*|*plugins/*)
        ok "hooks opencode install finds the bundled plugin from .build" ;;
    *)  bad "plugin repo fallback" "unexpected output: $out" ;;
esac
rm -rf "$FAKEHOME"

finish
