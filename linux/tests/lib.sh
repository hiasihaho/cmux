#!/usr/bin/env bash
# Shared harness for the Linux-port suites.
#
# A suite sets a few variables and sources this file:
#
#   SUITE_NAME="browser-find-smoke"
#   APP_ID_SUFFIX="findtest"
#   PAGE_PORT=8416
#   source "$(dirname "$0")/lib.sh"
#
# and then gets: an isolated cmux instance on a private X display, a `cx`
# wrapper that talks to it, fixture-server helpers, assertions that
# distinguish skips from failures, and cleanup that actually cleans up.
#
# Each lesson that cost a debugging round lives here once instead of in
# six copies:
#
#  - **Pre-flight cleanup is mandatory.** A previous `--keep` run holds
#    ports and leaves an instance; the next run then fails several
#    assertions for unrelated-looking reasons.
#  - **Background a server directly, not behind `cd X && …`** — `$!` would
#    be the wrapper subshell's pid, cleanup would orphan the real process,
#    and the leak stays invisible because pre-flight frees the port next
#    run. `--directory` avoids the subshell.
#  - **Kill by exact name.** `pkill -f <pattern>` matches the agent's own
#    command line and has killed the running shell more than once.
#  - **Poll, don't sleep.** A fixed sleep is a latent flake that fails
#    looking like a product bug. And poll for COMPLETENESS, not first
#    evidence: wait for ALL markers (and force the state change you
#    wait on — force_save), or a half-captured snapshot fails a later
#    assertion with a misleading name.
#  - **Run on a private X display.** A Ghostty surface spawns its shell on
#    first *map*, so on a real desktop terminal assertions depend on
#    whether the window happens to be visible. Xvfb removes that variable
#    and makes screenshots possible.

set -uo pipefail

: "${SUITE_NAME:?lib.sh: set SUITE_NAME before sourcing}"
: "${APP_ID_SUFFIX:?lib.sh: set APP_ID_SUFFIX before sourcing}"
: "${PAGE_PORT:=0}"

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CLI="$ROOT/.build/debug/cmux"
APP="$ROOT/.build/debug/cmux-adw"
APP_ID="com.manaflow.cmux.$APP_ID_SUFFIX"
SOCK="/tmp/cmux-$APP_ID_SUFFIX.sock"
SESSION="/tmp/cmux-$APP_ID_SUFFIX-session.json"
# Per-session scrollback dir, matching ScrollbackStore.directory
# (<session-stem>-scrollback beside the session file). Suites must not
# hand-derive it: the old shared dirname/scrollback is exactly the
# cross-instance corruption the app moved away from.
SBDIR="/tmp/cmux-$APP_ID_SUFFIX-session-scrollback"
LOG="/tmp/cmux-$APP_ID_SUFFIX.log"

# A stale binary silently tests yesterday's code and every verdict lies.
# Warn, never fail — deliberately testing an old binary is legitimate
# (a bisect, say). run-all.sh checks once itself and suppresses this
# per-suite copy. `find -L` follows the CmuxCLI/CLI symlink, so the
# shared CLI sources count too.
warn_if_stale_binary() {
    [ "${CMUX_TEST_NO_FRESHNESS_WARN:-0}" = "1" ] && return 0
    local bin missing=0
    for bin in "$APP" "$CLI"; do
        [ -x "$bin" ] || { echo "  WARN  $(basename "$bin") missing — cd linux && CMUX_GHOSTTY=1 swift build" >&2; missing=1; }
    done
    [ "$missing" = 1 ] && return 0
    # Compare sources against the NEWEST binary only: SwiftPM
    # legitimately skips relinking a product a change doesn't reach (a
    # CmuxAdw edit never relinks the CLI), so per-binary comparison
    # cries wolf forever. The newest binary's mtime is "when the last
    # build ran" — sources newer than THAT mean no build ran at all.
    local newest="$APP" newer
    [ "$CLI" -nt "$APP" ] && newest="$CLI"
    newer=$(find -L "$ROOT/Sources" -name '*.swift' -newer "$newest" -print -quit 2>/dev/null)
    [ -n "$newer" ] && echo "  WARN  binaries predate $(basename "$newer") — this run tests STALE code; cd linux && CMUX_GHOSTTY=1 swift build" >&2
    return 0
}
warn_if_stale_binary

# A leaked /tmp-session instance corrupted a day of suite runs on
# 2026-07-22 (pre-per-session-dir binaries pruned the SHARED
# /tmp/scrollback on every save). Per-session dirs fixed the sharing,
# but a leaked instance is still trouble — an OLD binary still prunes
# the legacy dir, and stray instances hold ports and skew load. Warn;
# killing someone else's instance is not the harness's call.
warn_if_foreign_tmp_instance() {
    local pid path
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        path=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
            | grep '^CMUX_SESSION_PATH=/tmp/' | cut -d= -f2)
        [ -n "$path" ] || continue
        [ "$path" = "$SESSION" ] && continue
        case "$path" in /tmp/cmux-scratch-*) continue ;; esac
        echo "  WARN  foreign cmux-adw (pid $pid, session $path) — a leaked instance; stop it (scratch.sh stop / kill by CMUX_APP_ID) before trusting this run" >&2
    done
    return 0
}
warn_if_foreign_tmp_instance

# A private display per suite so several can run without colliding; derived
# from the fixture port, which is already unique per suite.
XDISPLAY=":$(( 90 + (PAGE_PORT % 50) ))"
USE_XVFB="${CMUX_TEST_XVFB:-1}"

KEEP=0
[ "${1:-}" = "--keep" ] && KEEP=1

PASS=0; FAIL=0; SKIP=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
# A skip is not a pass. Suites use it when a precondition is missing, so a
# missing precondition can never masquerade as a product failure — or as
# success.
skip() { echo "  SKIP  $1 — $2"; SKIP=$((SKIP+1)); }
info() { echo "== $1"; }
expect() { [ "$3" = "$2" ] && ok "$1" || bad "$1" "expected '$2', got '$3'"; }

require_tools() {
    local missing=()
    for t in "$@"; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
    [ ${#missing[@]} -eq 0 ] && return 0
    echo "$SUITE_NAME: missing required tools: ${missing[*]}" >&2
    echo "  see docs/linux-port/DEPENDENCIES.md" >&2
    exit 2
}

free_port() {
    [ "${1:-0}" -gt 0 ] 2>/dev/null || return 0
    local pids
    pids=$(ss -lptnH "sport = :$1" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
    [ -n "$pids" ] && kill $pids 2>/dev/null
    return 0
}

kill_instance() {
    # By CMUX_APP_ID in /proc/<pid>/environ, never by pattern: `pkill -f`
    # matches the caller's own command line.
    local pid
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
            | grep -q "CMUX_APP_ID=$APP_ID" && kill "$pid" 2>/dev/null
    done
    sleep 1
    return 0
}

start_xvfb() {
    [ "$USE_XVFB" = "1" ] || return 0
    command -v Xvfb >/dev/null 2>&1 || { USE_XVFB=0; return 0; }
    Xvfb "$XDISPLAY" -screen 0 1400x900x24 >/dev/null 2>&1 &
    XVFB_PID=$!
    sleep 2
}

stop_xvfb() {
    [ -n "${XVFB_PID:-}" ] && kill "$XVFB_PID" 2>/dev/null
    return 0
}

# Starts (or restarts) the suite's cmux instance and waits for its socket.
# A suite can set INSTANCE_ENV=(FOO=1 BAR=2) for extra environment — the
# WebDriver suite needs CMUX_WEBDRIVER and an inspector server.
start_instance() {
    # An unset array must expand to NOTHING, not to one empty word —
    # "${arr[@]:-}" yields "" and `env "" nohup …` fails with
    # "env: '': No such file or directory".
    local extra=()
    [ -n "${INSTANCE_ENV+x}" ] && extra=("${INSTANCE_ENV[@]}")
    if [ "$USE_XVFB" = "1" ]; then
        env -u WAYLAND_DISPLAY DISPLAY="$XDISPLAY" GDK_BACKEND=x11 \
            CMUX_APP_ID=$APP_ID CMUX_SOCKET_PATH=$SOCK CMUX_SESSION_PATH=$SESSION \
            "${extra[@]}" nohup "$APP" >"$LOG" 2>&1 &
    else
        env CMUX_APP_ID=$APP_ID CMUX_SOCKET_PATH=$SOCK CMUX_SESSION_PATH=$SESSION \
            "${extra[@]}" nohup "$APP" >"$LOG" 2>&1 &
    fi
    local _
    for _ in $(seq 1 40); do
        CMUX_SOCKET_PATH=$SOCK "$CLI" ping >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    echo "$SUITE_NAME: instance did not come up (see $LOG)" >&2
    return 1
}

# Talks to this suite's instance, with the agent's own pane identity
# scrubbed so a command never targets the human's session by accident.
# CMUX_QUIET silences the merged CLI's legacy-alias notices, which would
# otherwise pollute captured output.
cx() { env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_QUIET=1 CMUX_SOCKET_PATH=$SOCK "$CLI" "$@"; }

# Sends one raw v2 JSON line to this suite's instance and prints the
# reply — for verbs the CLI has no subcommand for yet.
v2() {
    python3 - "$SOCK" "$1" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(15)
try:
    s.connect(sys.argv[1])
    s.sendall((sys.argv[2] + "\n").encode())
    data = b""
    while not data.endswith(b"\n"):
        chunk = s.recv(65536)
        if not chunk:
            break
        data += chunk
    print(data.decode().strip())
except Exception as e:
    print('{"error":"%s"}' % e)
    sys.exit(1)
PY
}

# Forces a session save (same call promote.sh uses — no CLI subcommand).
# Returns 0 when the server reports saved.
force_save() { v2 '{"id":1,"method":"session.save"}' | grep -q '"saved"'; }

# Capture verification must only trust files written AFTER the leg
# began: /tmp/scrollback is shared by every /tmp-session instance, the
# app prunes it on each save, and a stale file from a previous run
# satisfies a marker grep instantly — breaking the verification poll
# before this run's capture completed (2026-07-22, the bg-split leg).
mark_capture_epoch() {
    CAPTURE_STAMP="/tmp/cmux-$APP_ID_SUFFIX-capture-stamp"
    touch "$CAPTURE_STAMP"
}
# fresh_marker_files <dir> <pattern>: count post-epoch files holding pattern.
fresh_marker_files() {
    find "$1" -name '*.txt' -newer "$CAPTURE_STAMP" -exec grep -l "$2" {} + 2>/dev/null | wc -l
}

# Serves $1 on PAGE_PORT. `--directory` rather than `cd X && …`: with the
# latter, $! is the wrapper subshell and cleanup orphans the real server.
start_fixture_server() {
    python3 -m http.server "$PAGE_PORT" --directory "$1" >/dev/null 2>&1 &
    PAGE_PID=$!
    local _
    for _ in $(seq 1 20); do
        curl -s -m 1 "http://127.0.0.1:$PAGE_PORT/" >/dev/null 2>&1 && return 0
        sleep 0.3
    done
    return 0
}

# Polls until a surface's shell answers. Ghostty spawns on first map, so
# this can legitimately never succeed without a mapped window — callers
# check the return value and `skip` rather than `bad`.
wait_for_shell() {
    local ref="$1" tries="${2:-40}" _
    for _ in $(seq 1 "$tries"); do
        cx read-screen --surface "$ref" >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    return 1
}

# Captures the app window. Only meaningful under Xvfb; returns non-zero
# otherwise so a caller can skip instead of asserting on a missing file.
screenshot() {
    [ "$USE_XVFB" = "1" ] || return 1
    command -v import >/dev/null 2>&1 || return 1
    DISPLAY="$XDISPLAY" import -window root "$1" 2>/dev/null
}

# First surface ref of a workspace's first pane. Asks the protocol rather
# than deriving `surface:N` from `pane:N` — those stop matching as soon as
# a pane holds tabs.
first_surface_ref() {
    cx --json list-panes --workspace "$1" 2>/dev/null | python3 -c '
import json,sys
print(json.load(sys.stdin)["panes"][0]["surface_refs"][0])' 2>/dev/null
}

cleanup() {
    if [ "$KEEP" = "1" ]; then
        echo "== --keep: socket $SOCK, display $XDISPLAY, fixture port $PAGE_PORT"
        return
    fi
    # Suites with extra resources (a driver process, more ports) define
    # suite_cleanup; it runs before the shared teardown.
    declare -F suite_cleanup >/dev/null && suite_cleanup
    [ -n "${PAGE_PID:-}" ] && kill "$PAGE_PID" 2>/dev/null
    free_port "$PAGE_PORT"
    kill_instance
    stop_xvfb
    rm -f "$SESSION"
}
trap cleanup EXIT

# Pre-flight: a previous --keep run leaves the port and instance held.
free_port "$PAGE_PORT"
kill_instance
rm -f "$SESSION"

[ -x "$CLI" ] || { echo "$SUITE_NAME: missing $CLI — build with: cd linux && CMUX_GHOSTTY=1 swift build" >&2; exit 2; }
[ -x "$APP" ] || { echo "$SUITE_NAME: missing $APP" >&2; exit 2; }
require_tools python3 curl ss

# Reports the tally. Skips are printed but never counted as passes, and
# never fail the run — a missing precondition is not a broken product.
finish() {
    echo
    local line="== $SUITE_NAME: $PASS passed, $FAIL failed"
    [ "$SKIP" -gt 0 ] && line="$line, $SKIP skipped"
    echo "$line"
    [ "$FAIL" = "0" ] || exit 1
    exit 0
}
