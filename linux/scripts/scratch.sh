#!/usr/bin/env bash
# Ad-hoc HEADLESS scratch instances — for dev probes, dogfood experiments,
# and screenshots that need an isolated cmux without touching the daily.
#
# The test suites already manage their own Xvfb (lib.sh start_xvfb,
# displays :90-:139 derived per suite). Hand-rolled probes used to
# hardcode :93 and collided with a running gate (2026-07-23: a
# screenshot instance on a suite's display produced a false-red full
# gate). This wrapper owns the ad-hoc case with its own display range:
#
#   linux/scripts/scratch.sh start <tag> [EXTRA_ENV=1 ...]
#   linux/scripts/scratch.sh env <tag>        # eval-able exports for the CLI
#   linux/scripts/scratch.sh shot <tag> <out.png>
#   linux/scripts/scratch.sh stop <tag>
#   linux/scripts/scratch.sh list
#
# Guarantees: a FREE display in :140-:159 (never the suites' range), an
# isolated CMUX_APP_ID (kills strictly by env match, never by name), a
# session under ~/.local/state/cmux/scratch/<tag>/ (NEVER /tmp — the
# scrollback-pruning lesson), and idempotent stop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
APP="$ROOT/linux/.build/debug/cmux-adw"
CLI="$ROOT/linux/.build/debug/cmux"

cmd="${1:-help}"
tag="${2:-}"

info_file() { echo "/tmp/cmux-scratch-$1.info"; }
sock_path() { echo "/tmp/cmux-scratch-$1.sock"; }
app_id()    { echo "com.manaflow.cmux.scratch-$1"; }

require_tag() {
    [ -n "$tag" ] || { echo "scratch.sh: tag required" >&2; exit 2; }
    case "$tag" in *[!a-z0-9-]*) echo "scratch.sh: tag must be [a-z0-9-]" >&2; exit 2 ;; esac
}

kill_by_app_id() {
    local wanted="$1" pid
    for pid in $(pgrep -x cmux-adw); do
        if tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -q "^CMUX_APP_ID=$wanted$"; then
            kill "$pid" 2>/dev/null || true
        fi
    done
}

case "$cmd" in
start)
    require_tag
    [ -x "$APP" ] || { echo "scratch.sh: build first (cd linux && swift build)" >&2; exit 2; }
    "$0" stop "$tag" >/dev/null 2>&1 || true
    display=""
    for d in $(seq 140 159); do
        [ -e "/tmp/.X11-unix/X$d" ] || { display=":$d"; break; }
    done
    [ -n "$display" ] || { echo "scratch.sh: no free display in :140-:159" >&2; exit 2; }
    Xvfb "$display" -screen 0 1280x800x24 >/dev/null 2>&1 &
    xvfb_pid=$!
    sleep 2
    state_dir="$HOME/.local/state/cmux/scratch/$tag"
    mkdir -p "$state_dir/confighome"
    shift 2
    # Hermetic config, like the suite harness: a user-level ghostty theme
    # typo pops a modal dialog over the window and eats pointer probes.
    # Pass XDG_CONFIG_HOME=... as an extra arg to override deliberately.
    env -u WAYLAND_DISPLAY DISPLAY="$display" GDK_BACKEND=x11 \
        CMUX_APP_ID="$(app_id "$tag")" \
        CMUX_SOCKET_PATH="$(sock_path "$tag")" \
        CMUX_SESSION_PATH="$state_dir/session.json" \
        XDG_CONFIG_HOME="$state_dir/confighome" \
        "$@" nohup "$APP" >"$state_dir/app.log" 2>&1 &
    printf 'display=%s\nxvfb_pid=%s\n' "$display" "$xvfb_pid" > "$(info_file "$tag")"
    for _ in $(seq 1 40); do
        CMUX_SOCKET_PATH="$(sock_path "$tag")" "$CLI" ping >/dev/null 2>&1 && break
        sleep 0.5
    done
    if CMUX_SOCKET_PATH="$(sock_path "$tag")" "$CLI" ping 2>/dev/null | grep -q PONG; then
        echo "scratch '$tag' up: socket=$(sock_path "$tag") display=$display log=$state_dir/app.log"
    else
        echo "scratch.sh: instance did not answer ping — see $state_dir/app.log" >&2
        exit 1
    fi
    ;;
env)
    require_tag
    echo "export CMUX_SOCKET_PATH=$(sock_path "$tag"); unset CMUX_WORKSPACE_ID CMUX_SURFACE_ID; export CMUX_QUIET=1"
    ;;
shot)
    require_tag
    out="${3:-}"
    [ -n "$out" ] || { echo "scratch.sh: shot needs an output path" >&2; exit 2; }
    display=$(sed -n 's/^display=//p' "$(info_file "$tag")" 2>/dev/null)
    [ -n "$display" ] || { echo "scratch.sh: '$tag' is not running" >&2; exit 2; }
    DISPLAY="$display" import -window root "$out" 2>/dev/null
    echo "$out"
    ;;
stop)
    require_tag
    kill_by_app_id "$(app_id "$tag")"
    xvfb_pid=$(sed -n 's/^xvfb_pid=//p' "$(info_file "$tag")" 2>/dev/null)
    [ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null || true
    rm -f "$(info_file "$tag")" "$(sock_path "$tag")"
    echo "scratch '$tag' stopped"
    ;;
list)
    found=0
    for f in /tmp/cmux-scratch-*.info; do
        [ -e "$f" ] || continue
        found=1
        t=$(basename "$f" .info); t="${t#cmux-scratch-}"
        if CMUX_SOCKET_PATH="$(sock_path "$t")" "$CLI" ping 2>/dev/null | grep -q PONG; then
            echo "$t: running ($(sed -n 's/^display=//p' "$f"))"
        else
            echo "$t: stale info file"
        fi
    done
    [ "$found" = "1" ] || echo "no scratch instances"
    ;;
*)
    sed -n '2,20p' "$0"
    ;;
esac
