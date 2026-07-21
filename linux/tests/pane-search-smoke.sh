#!/usr/bin/env bash
# Regression test for `cmux search` — text search across every pane.
#
#   pane-search-smoke.sh          # run all assertions, clean up
#   pane-search-smoke.sh --keep   # leave the instance up for poking
#
# Exit: 0 all passed, 1 an assertion failed, 2 setup problem.
#
# Uses a LOCAL fixture page (no network) so the browser side is
# deterministic: an earlier manual run "failed" only because the test
# string was on a different page than the one loaded.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CLI="$ROOT/.build/debug/cmux"
APP="$ROOT/.build/debug/cmux-adw"
APP_ID="com.manaflow.cmux.searchtest"
SOCK="/tmp/cmux-searchtest.sock"
SESSION="/tmp/cmux-searchtest-session.json"
LOG="/tmp/cmux-searchtest.log"
PAGE_PORT=8414
KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

free_port() {
    local pids
    pids=$(ss -lptnH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    [ -n "$pids" ] && kill $pids 2>/dev/null
    return 0
}
kill_instance() {
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
            | grep -q "CMUX_APP_ID=$APP_ID" && kill "$pid" 2>/dev/null
    done
    return 0
}
cleanup() {
    [ "$KEEP" = "1" ] && { echo "== --keep: instance on $SOCK, fixture on $PAGE_PORT"; return; }
    [ -n "${PAGE_PID:-}" ] && kill "$PAGE_PID" 2>/dev/null
    free_port $PAGE_PORT
    kill_instance
    rm -f "$SESSION"
}
trap cleanup EXIT

free_port $PAGE_PORT
kill_instance
sleep 0.5

[ -x "$CLI" ] || { echo "missing $CLI — build with: cd linux && CMUX_GHOSTTY=1 swift build" >&2; exit 2; }
[ -x "$APP" ] || { echo "missing $APP" >&2; exit 2; }

WORK=$(mktemp -d)
cat > "$WORK/index.html" <<'HTML'
<!doctype html><title>search fixture</title><body>
<h1>BROWSERONLYNEEDLE</h1>
<p>SHAREDNEEDLE appears in both kinds of pane.</p>
<p>MixedCaseNeedle for case tests.</p>
<script>var invisible = "SCRIPTBODYNEEDLE";</script>
<div style="display:none">HIDDENNEEDLE</div>
</body>
HTML
python3 -m http.server $PAGE_PORT --directory "$WORK" >/dev/null 2>&1 &
PAGE_PID=$!
for _ in $(seq 1 20); do
    curl -s -m 1 "http://127.0.0.1:$PAGE_PORT/index.html" >/dev/null 2>&1 && break
    sleep 0.3
done

info "starting isolated cmux"
CMUX_APP_ID=$APP_ID CMUX_SOCKET_PATH=$SOCK CMUX_SESSION_PATH=$SESSION \
    nohup "$APP" >"$LOG" 2>&1 &
for _ in $(seq 1 40); do
    CMUX_SOCKET_PATH=$SOCK "$CLI" ping >/dev/null 2>&1 && break
    sleep 0.5
done
cx() { env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_SOCKET_PATH=$SOCK "$CLI" "$@"; }
cx ping >/dev/null 2>&1 || { echo "instance did not come up (see $LOG)" >&2; exit 2; }

WS=$(cx new-workspace --cwd /tmp --background | grep -oE 'workspace:[0-9]+')
cx browser open "http://127.0.0.1:$PAGE_PORT/index.html" --workspace "$WS" >/dev/null
# Ghostty panes spawn their shell on first map, so the workspace has to be
# selected once before the terminal side exists at all.
cx select-workspace --workspace "$WS" >/dev/null
# Poll, don't sleep: a Ghostty surface spawns its shell on first map, and
# under load that takes longer than any fixed wait. A 4s sleep here made
# the terminal assertions fail on a busy machine — which reads exactly
# like a product bug ("search finds nothing in terminals").
TERMINAL_READY=0
for _ in $(seq 1 40); do
    cx read-screen --surface "$(cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
print(json.load(sys.stdin)["panes"][0]["surface_refs"][0])' 2>/dev/null)" >/dev/null 2>&1 \
        && { TERMINAL_READY=1; break; }
    sleep 0.5
done

# The terminal surface is the workspace's first pane; target it explicitly.
# `--workspace` alone would hit the FOCUSED surface, which is the browser —
# that mistake made an earlier manual run look like a product bug.
TERM_REF=$(cx --json list-panes --workspace "$WS" 2>/dev/null | python3 -c '
import json,sys
print(json.load(sys.stdin)["panes"][0]["surface_refs"][0])')
cx send --surface "$TERM_REF" 'echo TERMONLYNEEDLE; echo SHAREDNEEDLE\n' >/dev/null 2>&1
sleep 2

hits() { cx --json search "$@" 2>/dev/null | python3 -c 'import json,sys; print(json.load(sys.stdin).get("total_matches",0))'; }
kinds() { cx --json search "$@" 2>/dev/null | python3 -c 'import json,sys; print(",".join(sorted({r["kind"] for r in json.load(sys.stdin).get("results",[])})))'; }

# --- 1/2. each pane kind is reachable.
#
# ENVIRONMENTAL PRECONDITION: a Ghostty surface spawns its shell on first
# *map*, so the terminal assertions need this instance's window to actually
# be on screen. When the window opens occluded or the session is headless,
# the shell never starts and these two checks would report "search finds
# nothing in terminals" — a product failure that is really a missing
# precondition. Skipped loudly instead of failed quietly; the browser
# assertions do not need a mapped window and still run.
if [ "$TERMINAL_READY" != "1" ]; then
    echo "  SKIP  terminal assertions — the shell never started, so this"
    echo "        instance's window is not mapped (Ghostty spawns on first map)."
    echo "        Run with a visible desktop session to exercise them."
else
[ "$(kinds TERMONLYNEEDLE)" = "terminal" ] && ok "terminal-only string found in the terminal pane" \
    || bad "terminal search" "kinds=$(kinds TERMONLYNEEDLE)"

# --- 3. one query spans both kinds — the whole point of the verb.
[ "$(kinds SHAREDNEEDLE)" = "browser,terminal" ] && ok "one query spans terminal and browser panes" \
    || bad "cross-kind search" "kinds=$(kinds SHAREDNEEDLE)"
fi
[ "$(kinds BROWSERONLYNEEDLE)" = "browser" ] && ok "browser-only string found in the browser pane" \
    || bad "browser search" "kinds=$(kinds BROWSERONLYNEEDLE)"

# --- 4. --kind narrows the scope.
[ "$(kinds SHAREDNEEDLE --kind browser)" = "browser" ] && ok "--kind filters the scope" \
    || bad "--kind" "kinds=$(kinds SHAREDNEEDLE --kind browser)"

# --- 5. case-insensitive by default, case-sensitive on request.
[ "$(hits mixedcaseneedle)" -gt 0 ] && ok "case-insensitive by default" \
    || bad "default case" "no hits for lowercased needle"
[ "$(hits mixedcaseneedle --case-sensitive)" = "0" ] && ok "--case-sensitive respected" \
    || bad "--case-sensitive" "still matched a differently-cased needle"

# --- 6. regex mode.
[ "$(hits --regex 'BROWSER[A-Z]+NEEDLE')" -gt 0 ] && ok "regex search matches" \
    || bad "regex" "no hits"
cx --json search --regex '[' >/dev/null 2>&1 && bad "invalid regex" "should have failed" \
    || ok "invalid regex reports an error instead of silently finding nothing"

# --- 7. innerText semantics: script bodies and display:none must NOT match,
# or the verb reports text no human can see on screen.
[ "$(hits SCRIPTBODYNEEDLE)" = "0" ] && ok "script bodies are not searched (innerText, not textContent)" \
    || bad "script body" "matched text inside <script>"
[ "$(hits HIDDENNEEDLE)" = "0" ] && ok "display:none text is not searched" \
    || bad "hidden text" "matched invisible content"

# --- 8. structured output carries what an agent needs to act on a hit.
missing=$(cx --json search SHAREDNEEDLE 2>/dev/null | python3 -c '
import json,sys
r = json.load(sys.stdin)["results"][0]
need = {"surface_ref","workspace_ref","pane_ref","kind","match_count","matches"}
print(",".join(sorted(need - set(r))))')
[ -z "$missing" ] && ok "JSON hit carries surface/workspace/pane refs for chaining" \
    || bad "JSON shape" "missing keys: $missing"

cx close-workspace --workspace "$WS" >/dev/null 2>&1
echo
echo "== pane-search-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
