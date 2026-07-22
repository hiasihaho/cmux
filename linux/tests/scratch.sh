#!/usr/bin/env bash
# Ad-hoc scratch cmux instances for interactive/agent verification — the
# wrapper for what suites do via lib.sh, minus assertions. Encodes every
# lesson the hand-rolled versions kept re-learning: env-scrubbed launch,
# private Xvfb, kill-by-environ (never pkill by name), per-session paths,
# and cleanup that actually removes the artifacts (a leaked /tmp-session
# scratch instance corrupted a day of suite runs on 2026-07-22).
#
#   scratch.sh start <name> [--vte]   # Xvfb + instance; prints how to talk to it
#   scratch.sh cx <name> <cmd...>     # scrubbed CLI against that instance
#   scratch.sh v2 <name> '<json>'     # raw v2 line against its socket
#   scratch.sh log <name> [n]         # tail its log (default 20 lines)
#   scratch.sh stop <name>            # kill instance + Xvfb, remove artifacts
#   scratch.sh list                   # every scratch instance still alive
#
# Instances are ghostty-backed by default (the daily config's backend);
# --vte forces the VTE backend. Always `stop` what you `start`.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CLI="$ROOT/.build/debug/cmux"
APP="$ROOT/.build/debug/cmux-adw"

usage() { sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; }

cmd="${1:-}"; shift || true
case "$cmd" in
    -h|--help|"") usage; exit 0 ;;
    list)
        found=0
        for pid in $(pgrep -x cmux-adw 2>/dev/null); do
            id=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                | grep '^CMUX_APP_ID=com.manaflow.cmux.scratch-' | cut -d= -f2)
            [ -n "$id" ] || continue
            found=1
            echo "${id#com.manaflow.cmux.scratch-}  (pid $pid, socket /tmp/cmux-scratch-${id#com.manaflow.cmux.scratch-}.sock)"
        done
        [ "$found" = 0 ] && echo "no scratch instances running"
        exit 0
        ;;
esac

NAME="${1:?scratch.sh $cmd needs an instance name}"; shift || true
case "$NAME" in
    *[!a-z0-9-]*) echo "scratch.sh: name must be lowercase alnum/dashes" >&2; exit 2 ;;
esac
APP_ID="com.manaflow.cmux.scratch-$NAME"
SOCK="/tmp/cmux-scratch-$NAME.sock"
SESSION="/tmp/cmux-scratch-$NAME-session.json"
LOG="/tmp/cmux-scratch-$NAME.log"
# Stable per-name display, clear of the suites' :90-:115 range.
XDISPLAY=":$(( 140 + ($(printf '%s' "$NAME" | cksum | cut -d' ' -f1) % 40) ))"

kill_by_appid() {
    local pid killed=1
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
            | grep -q "^CMUX_APP_ID=$APP_ID$" && kill "$pid" 2>/dev/null && killed=0
    done
    return $killed
}

scrubbed_cx() {
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_SOCKET \
        CMUX_QUIET=1 CMUX_SOCKET_PATH="$SOCK" "$CLI" "$@"
}

case "$cmd" in
    start)
        backend="ghostty"
        [ "${1:-}" = "--vte" ] && backend="vte"
        [ -x "$APP" ] || { echo "scratch.sh: no binary — cd linux && CMUX_GHOSTTY=1 swift build" >&2; exit 2; }
        if scrubbed_cx ping >/dev/null 2>&1; then
            echo "scratch.sh: '$NAME' already running (socket $SOCK)" >&2; exit 1
        fi
        kill_by_appid; rm -f "$SOCK"
        pgrep -f "Xvfb $XDISPLAY" >/dev/null 2>&1 || {
            Xvfb "$XDISPLAY" -screen 0 1400x900x24 >/dev/null 2>&1 &
            sleep 1
        }
        env -u WAYLAND_DISPLAY -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
            DISPLAY="$XDISPLAY" GDK_BACKEND=x11 \
            CMUX_APP_ID="$APP_ID" CMUX_SOCKET_PATH="$SOCK" \
            CMUX_SESSION_PATH="$SESSION" CMUX_TERM="$backend" \
            nohup "$APP" >"$LOG" 2>&1 &
        for _ in $(seq 1 40); do
            scrubbed_cx ping >/dev/null 2>&1 && {
                echo "scratch '$NAME' up ($backend, display $XDISPLAY)"
                echo "  talk:  linux/tests/scratch.sh cx $NAME <command>"
                echo "  stop:  linux/tests/scratch.sh stop $NAME"
                exit 0
            }
            sleep 0.5
        done
        echo "scratch.sh: '$NAME' did not come up — see $LOG" >&2
        exit 2
        ;;
    cx)
        scrubbed_cx "$@"
        ;;
    v2)
        python3 - "$SOCK" "${1:?v2 needs a JSON line}" <<'PY'
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(15)
s.connect(sys.argv[1])
s.sendall((sys.argv[2] + "\n").encode())
data = b""
while not data.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
print(data.decode().strip())
PY
        ;;
    log)
        tail -n "${1:-20}" "$LOG"
        ;;
    stop)
        kill_by_appid && echo "stopped $NAME" || echo "no instance for $NAME"
        pgrep -f "Xvfb $XDISPLAY" >/dev/null 2>&1 && pkill -f "Xvfb $XDISPLAY"
        rm -f "$SOCK" "$SESSION" "$LOG"
        rm -rf "/tmp/cmux-scratch-$NAME-session-scrollback"
        ;;
    *)
        echo "scratch.sh: unknown command '$cmd'" >&2; usage >&2; exit 2
        ;;
esac
