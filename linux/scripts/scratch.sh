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
#   linux/scripts/scratch.sh watch <tag>      # live view in a pane: x11vnc+noVNC (ADR-0010)
#   linux/scripts/scratch.sh watch-status <tag>   # verify the watch pipeline end-to-end
#   linux/scripts/scratch.sh point <tag> <out.png> # human's pointer: coords + marked shot
#   linux/scripts/scratch.sh unwatch <tag>
#   linux/scripts/scratch.sh stop <tag>       # also unwatches
#   linux/scripts/scratch.sh list
#
# Guarantees: a FREE display in :140-:159 (never the suites' range), an
# isolated CMUX_APP_ID (kills strictly by env match, never by name), a
# session under ~/.local/state/cmux/scratch/<tag>/ (NEVER /tmp — the
# scrollback-pruning lesson), and idempotent stop.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# CMUX_TEST_BUILD_DIR points at a `swift build --scratch-path` output, so a
# probe can run a binary built against an alternate shim WITHOUT rebuilding
# .build — which the daily instance promotes from (2026-09-01: the shim had
# to be built to a side prefix because the running daily has the canonical
# libghostty-gtk.so MAPPED, and overwriting it can SIGBUS a live instance).
APP="${CMUX_TEST_BUILD_DIR:-$ROOT/linux/.build}/debug/cmux-adw"
CLI="${CMUX_TEST_BUILD_DIR:-$ROOT/linux/.build}/debug/cmux"

cmd="${1:-help}"
tag="${2:-}"

info_file()  { echo "/tmp/cmux-scratch-$1.info"; }
sock_path()  { echo "/tmp/cmux-scratch-$1.sock"; }
app_id()     { echo "com.manaflow.cmux.scratch-$1"; }
watch_file() { echo "/tmp/cmux-scratch-$1.watch"; }

running_display() {
    sed -n 's/^display=//p' "$(info_file "$1")" 2>/dev/null
}

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
watch)
    # ADR-0010 option B: live view of the tag's Xvfb display in a browser
    # pane. Interactive on purpose — the human can click/point inside the
    # agent's display, then the agent reads the pointer with `point`.
    require_tag
    display=$(running_display "$tag")
    [ -n "$display" ] || { echo "scratch.sh: '$tag' is not running" >&2; exit 2; }
    wf="$(watch_file "$tag")"
    if [ -e "$wf" ] && grep -q x11vnc "/proc/$(sed -n 's/^x11vnc_pid=//p' "$wf")/cmdline" 2>/dev/null; then
        echo "watch '$tag' already up: $(sed -n 's/^url=//p' "$wf")"
        exit 0
    fi
    for dep in x11vnc websockify; do
        command -v "$dep" >/dev/null || { echo "scratch.sh: $dep not installed (sudo dnf install x11vnc novnc)" >&2; exit 2; }
    done
    n="${display#:}"
    rfb_port=$((5900 + n)); web_port=$((6900 + n))
    state_dir="$HOME/.local/state/cmux/scratch/$tag"
    mkdir -p "$state_dir"
    # x11vnc exits on sight of WAYLAND_DISPLAY before trying the X display
    # (0.9.17) — scrub the session vars, the target is our Xvfb.
    env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE nohup x11vnc -display "$display" \
        -localhost -rfbport "$rfb_port" -shared -forever -nopw -quiet \
        >>"$state_dir/x11vnc.log" 2>&1 &
    x11vnc_pid=$!
    nohup websockify --web /usr/share/novnc "127.0.0.1:$web_port" "localhost:$rfb_port" \
        >>"$state_dir/websockify.log" 2>&1 &
    websockify_pid=$!
    url="http://127.0.0.1:$web_port/vnc.html?autoconnect=true&resize=scale"
    for _ in $(seq 1 20); do
        curl -sf -o /dev/null "http://127.0.0.1:$web_port/vnc.html" && break
        sleep 0.5
    done
    if ! curl -sf -o /dev/null "http://127.0.0.1:$web_port/vnc.html"; then
        kill "$x11vnc_pid" "$websockify_pid" 2>/dev/null || true
        echo "scratch.sh: noVNC did not come up — see $state_dir/websockify.log" >&2
        exit 1
    fi
    # A pane in the CALLER's instance (background workspace, no focus theft).
    # Outside cmux / socket down: skip the pane, the URL still works anywhere.
    workspace_ref=""; surface_ref=""
    if CMUX_QUIET=1 "$CLI" ping 2>/dev/null | grep -q PONG; then
        workspace_ref=$(env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_QUIET=1 \
            "$CLI" new-workspace --name "watch-$tag" --focus false 2>/dev/null \
            | grep -o 'workspace:[0-9]*' | head -1)
        if [ -n "$workspace_ref" ]; then
            surface_ref=$(env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_QUIET=1 \
                "$CLI" --json new-surface --type browser --workspace "$workspace_ref" \
                --url "$url" --focus false 2>/dev/null \
                | grep -o 'surface:[0-9]*' | head -1)
        fi
    fi
    {
        printf 'display=%s\nrfb_port=%s\nweb_port=%s\n' "$display" "$rfb_port" "$web_port"
        printf 'x11vnc_pid=%s\nwebsockify_pid=%s\n' "$x11vnc_pid" "$websockify_pid"
        printf 'workspace_ref=%s\nsurface_ref=%s\nurl=%s\n' "$workspace_ref" "$surface_ref" "$url"
    } > "$wf"
    if [ -n "$surface_ref" ]; then
        echo "watch '$tag' up: $url -> $surface_ref in $workspace_ref (background)"
    else
        echo "watch '$tag' up: $url (no cmux instance reachable; open the URL yourself)"
    fi
    ;;
watch-status)
    require_tag
    wf="$(watch_file "$tag")"
    [ -e "$wf" ] || { echo "watch-status: no watch for '$tag'" >&2; exit 1; }
    ok=0
    for name in x11vnc websockify; do
        pid=$(sed -n "s/^${name}_pid=//p" "$wf")
        if ! grep -q "$name" "/proc/$pid/cmdline" 2>/dev/null; then
            echo "watch-status: $name (pid ${pid:-?}) not running" >&2; ok=1
        fi
    done
    web_port=$(sed -n 's/^web_port=//p' "$wf")
    if ! curl -sf -o /dev/null "http://127.0.0.1:$web_port/vnc.html"; then
        echo "watch-status: noVNC not serving on :$web_port" >&2; ok=1
    fi
    surface_ref=$(sed -n 's/^surface_ref=//p' "$wf")
    if [ -n "$surface_ref" ] && CMUX_QUIET=1 "$CLI" ping 2>/dev/null | grep -q PONG; then
        state=$(CMUX_QUIET=1 "$CLI" browser --surface "$surface_ref" eval \
            "document.documentElement.className" 2>/dev/null || true)
        case "$state" in
            *noVNC_connected*) ;;
            *) echo "watch-status: pane $surface_ref not connected ($state)" >&2; ok=1 ;;
        esac
    fi
    if [ "$ok" = 0 ]; then
        echo "watch '$tag' healthy${surface_ref:+ (pane $surface_ref connected)}"
    fi
    exit "$ok"
    ;;
point)
    # ADR-0010's pointing channel: the human clicks/hovers in the watch
    # pane (VNC injects the pointer into our Xvfb); this reads where the
    # pointer sits and emits a shot with a red crosshair at that spot.
    require_tag
    out="${3:-}"
    [ -n "$out" ] || { echo "scratch.sh: point needs an output path" >&2; exit 2; }
    display=$(running_display "$tag")
    [ -n "$display" ] || { echo "scratch.sh: '$tag' is not running" >&2; exit 2; }
    eval "$(DISPLAY="$display" xdotool getmouselocation --shell 2>/dev/null)"
    [ -n "${X:-}" ] || { echo "scratch.sh: could not read pointer on $display" >&2; exit 1; }
    im=convert; command -v magick >/dev/null && im=magick
    DISPLAY="$display" import -window root png:- 2>/dev/null | \
        "$im" png:- -stroke red -strokewidth 3 -fill none \
            -draw "circle $X,$Y $((X+14)),$Y" \
            -draw "line $((X-26)),$Y $((X-10)),$Y" -draw "line $((X+10)),$Y $((X+26)),$Y" \
            -draw "line $X,$((Y-26)) $X,$((Y-10))" -draw "line $X,$((Y+10)) $X,$((Y+26))" \
            "$out"
    echo "x=$X y=$Y shot=$out"
    ;;
unwatch)
    require_tag
    wf="$(watch_file "$tag")"
    [ -e "$wf" ] || { echo "no watch for '$tag'"; exit 0; }
    for name in x11vnc websockify; do
        pid=$(sed -n "s/^${name}_pid=//p" "$wf")
        # kill strictly by recorded pid, and only if it is still that process
        if [ -n "$pid" ] && grep -q "$name" "/proc/$pid/cmdline" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    workspace_ref=$(sed -n 's/^workspace_ref=//p' "$wf")
    if [ -n "$workspace_ref" ] && CMUX_QUIET=1 "$CLI" ping 2>/dev/null | grep -q PONG; then
        CMUX_QUIET=1 "$CLI" close-workspace --workspace "$workspace_ref" >/dev/null 2>&1 || true
    fi
    rm -f "$wf"
    echo "watch '$tag' stopped"
    ;;
stop)
    require_tag
    "$0" unwatch "$tag" >/dev/null 2>&1 || true
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
    sed -n '2,24p' "$0"
    ;;
esac
