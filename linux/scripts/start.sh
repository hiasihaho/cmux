#!/usr/bin/env bash
# Launcher for the cmux Linux port (see docs/linux-port/INSIDE-CMUX.md).
#
#   start.sh [daily]            start the daily instance (default socket/session)
#   start.sh dev [--vte]        start the isolated dev instance
#   start.sh dev2 [--vte]       second isolated slot (when dev hosts a session)
#   start.sh stop-dev[2]        stop ONLY that dev instance (never the daily)
#   start.sh status             show which instances are running
#
# Terminal backend: shim-linked binaries (CMUX_GHOSTTY=1 swift build)
# default to GHOSTTY terminals; pass --vte to force the VTE fallback.
# VTE-only binaries always use VTE. --ghostty is accepted for
# backward compatibility (explicit CMUX_TERM=ghostty).
# Shim build: cd ghostty && zig build lib-gtk -Dapp-runtime=gtk \
#   -Dversion-string=1.3.0-dev
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/linux/.build/debug/cmux-adw"
CLI="$ROOT/linux/.build/debug/cmux"
LOG_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/cmux"
mkdir -p "$LOG_DIR"

cmd="${1:-daily}"
shift || true
ghostty=false
vte=false
for arg in "$@"; do
    [ "$arg" = "--ghostty" ] && ghostty=true
    [ "$arg" = "--vte" ] && vte=true
done

linked_ghostty() { ldd "$BIN" 2>/dev/null | grep -q libghostty-gtk; }

term_label() {
    if $vte; then echo vte
    elif $ghostty; then echo ghostty
    elif linked_ghostty; then echo "ghostty(default)"
    else echo vte
    fi
}

require_binary() {
    if [ ! -x "$BIN" ]; then
        echo "error: $BIN not built — run: cd $ROOT/linux && swift build" >&2
        exit 1
    fi
    if $ghostty && ! linked_ghostty; then
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

ping_dev() { # $1 = slot (dev|dev2)
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
        CMUX_SOCKET_PATH="/tmp/cmux-$1.sock" "$CLI" ping 2>/dev/null | grep -q PONG
}

# Terminal-backend env: ghostty is the default in shim-linked binaries.
ghostty_env() {
    if $vte; then
        echo "CMUX_TERM=vte"
        return
    fi
    $ghostty && echo "CMUX_TERM=ghostty"
    if linked_ghostty; then
        local res="$ROOT/ghostty/zig-out/share/ghostty"
        [ -d "$res" ] && echo "GHOSTTY_RESOURCES_DIR=$res"
    fi
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
    mapfile -t term_env < <(ghostty_env)
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID -u CMUX_SOCKET_PATH \
        "${term_env[@]}" \
        setsid nohup "$BIN" >>"$log" 2>&1 &
    disown
    echo "daily instance started (pid $!, terminals: $(term_label))"
    echo "log: $log"
    ;;
dev | dev2)
    slot="$cmd"
    require_binary
    if ping_dev "$slot"; then
        echo "$slot instance already running on /tmp/cmux-$slot.sock" >&2
        exit 1
    fi
    rm -f "/tmp/cmux-$slot.sock" "/tmp/cmux-$slot-session.json"
    log="$LOG_DIR/$slot.log"
    mapfile -t term_env < <(ghostty_env)
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
        CMUX_APP_ID="com.manaflow.cmux.$slot" \
        CMUX_SOCKET_PATH="/tmp/cmux-$slot.sock" \
        CMUX_SESSION_PATH="/tmp/cmux-$slot-session.json" \
        "${term_env[@]}" \
        setsid nohup "$BIN" >>"$log" 2>&1 &
    disown
    echo "$slot instance started (pid $!, terminals: $(term_label))"
    echo "log: $log"
    echo "talk to it: CMUX_SOCKET_PATH=/tmp/cmux-$slot.sock cmux ping"
    ;;
stop-dev | stop-dev2)
    slot="${cmd#stop-}"
    # Kill strictly by CMUX_APP_ID match — never the daily instance.
    stopped=false
    while read -r pid app_id; do
        if [ "$app_id" = "com.manaflow.cmux.$slot" ]; then
            kill "$pid" && echo "stopped $slot instance (pid $pid)"
            stopped=true
        fi
    done < <(instances)
    $stopped || echo "no $slot instance running"
    rm -f "/tmp/cmux-$slot.sock" "/tmp/cmux-$slot-session.json"
    ;;
status)
    found=false
    while read -r pid app_id; do
        found=true
        term=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null \
            | sed -n 's/^CMUX_TERM=//p')
        if [ -z "$term" ]; then
            # No explicit override: shim-linked binaries default to ghostty.
            if ldd "$(readlink /proc/$pid/exe)" 2>/dev/null | grep -q libghostty-gtk; then
                term="ghostty(default)"
            else
                term=vte
            fi
        fi
        echo "pid $pid  $app_id  terminals=$term"
    done < <(instances)
    $found || echo "no cmux-adw running"
    if ping_daily; then echo "daily socket: responding"; fi
    if ping_dev dev; then echo "dev socket:   responding (/tmp/cmux-dev.sock)"; fi
    if ping_dev dev2; then echo "dev2 socket:  responding (/tmp/cmux-dev2.sock)"; fi
    ;;
*)
    echo "usage: start.sh [daily|dev|dev2|stop-dev|stop-dev2|status] [--vte|--ghostty]" >&2
    exit 2
    ;;
esac
