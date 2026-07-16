#!/usr/bin/env bash
# Launcher for the cmux Linux port (see docs/linux-port/INSIDE-CMUX.md).
#
#   start.sh [daily]            start the daily instance (default socket/session)
#   start.sh daily --ghostty    daily with experimental Ghostty terminals
#   start.sh dev [--ghostty]    start the isolated dev instance
#   start.sh stop-dev           stop ONLY the dev instance (never the daily)
#   start.sh status             show which instances are running
#
# Ghostty mode needs a shim-linked binary:
#   cd linux && CMUX_GHOSTTY=1 swift build
# (plus the shim lib: cd ghostty && zig build lib-gtk -Dapp-runtime=gtk \
#  -Dversion-string=1.3.0-dev)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/linux/.build/debug/cmux-adw"
CLI="$ROOT/linux/.build/debug/cmux"
DEV_APP_ID=com.manaflow.cmux.dev
DEV_SOCKET=/tmp/cmux-dev.sock
DEV_SESSION=/tmp/cmux-dev-session.json
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cmux"
mkdir -p "$LOG_DIR"

cmd="${1:-daily}"
shift || true
ghostty=false
for arg in "$@"; do
    [ "$arg" = "--ghostty" ] && ghostty=true
done

require_binary() {
    if [ ! -x "$BIN" ]; then
        echo "error: $BIN not built — run: cd $ROOT/linux && swift build" >&2
        exit 1
    fi
    if $ghostty && ! ldd "$BIN" 2>/dev/null | grep -q libghostty-gtk; then
        echo "error: binary lacks the Ghostty shim. Build it with:" >&2
        echo "  cd $ROOT/linux && CMUX_GHOSTTY=1 swift build" >&2
        exit 1
    fi
}

ping_daily() {
    # Default socket resolution lives in the CLI; strip pane identity so
    # this works from inside a cmux terminal too.
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_SOCKET_PATH \
        "$CLI" ping 2>/dev/null | grep -q PONG
}

ping_dev() {
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
        CMUX_SOCKET_PATH="$DEV_SOCKET" "$CLI" ping 2>/dev/null | grep -q PONG
}

# Print "<pid> <app-id-or-daily>" for every running cmux-adw.
instances() {
    for pid in $(pgrep -x cmux-adw); do
        local app_id
        app_id=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null \
            | sed -n 's/^CMUX_APP_ID=//p')
        echo "$pid ${app_id:-daily}"
    done
}

case "$cmd" in
daily)
    require_binary
    if ping_daily; then
        echo "daily instance already running — refusing a second one" >&2
        echo "(its socket would be hijacked; close it first if you mean to restart)" >&2
        exit 1
    fi
    log="$LOG_DIR/daily.log"
    term_env=()
    $ghostty && term_env=(CMUX_TERM=ghostty)
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_SOCKET_PATH \
        "${term_env[@]}" \
        setsid nohup "$BIN" >>"$log" 2>&1 &
    disown
    echo "daily instance started (pid $!, terminals: $($ghostty && echo ghostty || echo vte))"
    echo "log: $log"
    ;;
dev)
    require_binary
    if ping_dev; then
        echo "dev instance already running on $DEV_SOCKET" >&2
        exit 1
    fi
    rm -f "$DEV_SOCKET" "$DEV_SESSION"
    log="$LOG_DIR/dev.log"
    term_env=()
    $ghostty && term_env=(CMUX_TERM=ghostty)
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
        CMUX_APP_ID="$DEV_APP_ID" \
        CMUX_SOCKET_PATH="$DEV_SOCKET" \
        CMUX_SESSION_PATH="$DEV_SESSION" \
        "${term_env[@]}" \
        setsid nohup "$BIN" >>"$log" 2>&1 &
    disown
    echo "dev instance started (pid $!, terminals: $($ghostty && echo ghostty || echo vte))"
    echo "log: $log"
    echo "talk to it: CMUX_SOCKET_PATH=$DEV_SOCKET cmux ping"
    ;;
stop-dev)
    # Kill strictly by CMUX_APP_ID match — never the daily instance.
    stopped=false
    while read -r pid app_id; do
        if [ "$app_id" = "$DEV_APP_ID" ]; then
            kill "$pid" && echo "stopped dev instance (pid $pid)"
            stopped=true
        fi
    done < <(instances)
    $stopped || echo "no dev instance running"
    rm -f "$DEV_SOCKET" "$DEV_SESSION"
    ;;
status)
    found=false
    while read -r pid app_id; do
        found=true
        term=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null \
            | sed -n 's/^CMUX_TERM=//p')
        echo "pid $pid  $app_id  terminals=${term:-vte}"
    done < <(instances)
    $found || echo "no cmux-adw running"
    if ping_daily; then echo "daily socket: responding"; fi
    if ping_dev; then echo "dev socket:   responding ($DEV_SOCKET)"; fi
    ;;
*)
    echo "usage: start.sh [daily|dev|stop-dev|status] [--ghostty]" >&2
    exit 2
    ;;
esac
