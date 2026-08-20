#!/usr/bin/env bash
# Promote the freshly built binary to the DAILY cmux instance.
#
#   linux/scripts/promote.sh [--no-build] [--test] [--vte|--ghostty]
#
# The daily instance runs the binary from linux/.build/debug, so `swift
# build` already put the new code on disk — promotion is "restart the
# daily instance without losing anything":
#
#   1. build (unless --no-build), optionally run the suite (--test)
#   2. ask the running daily to save its session (`session.save` — final-
#      save semantics, so scrollback is captured unthrottled)
#   3. stop the daily politely-enough (SIGTERM after the forced save)
#   4. start it again via start.sh; session restore brings every
#      workspace, pane, cwd and scrollback back
#
# SELF-HOSTING GUARD: a shell inside the daily instance dies with it —
# run this from a dev-instance pane or a plain terminal. The script
# refuses to run from inside the instance it is about to kill.
#
# After promotion, resume the Claude session in its restored pane with:
#   claude --continue
#
# --slot dev|dev2 promotes that dev slot instead (same code path against
# a disposable instance — how this script itself is tested).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLI="$ROOT/linux/.build/debug/cmux"
START="$ROOT/linux/scripts/start.sh"

build=true
test=false
slot="daily"
passthrough=()
while [ $# -gt 0 ]; do
    case "$1" in
        --no-build) build=false ;;
        --test) test=true ;;
        --slot) slot="$2"; shift ;;
        --vte | --ghostty) passthrough+=("$1") ;;
        *) echo "promote.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done

case "$slot" in daily | dev | dev2) ;; *)
    echo "promote.sh: --slot must be daily, dev or dev2" >&2; exit 2 ;;
esac

# The daily instance's socket, mirroring the app's own default resolution
# (ControlSocketServer.defaultSocketPath): XDG runtime dir, uid fallback.
daily_socket() {
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
        echo "$XDG_RUNTIME_DIR/cmux.sock"
    else
        echo "/tmp/cmux-$(id -u).sock"
    fi
}

if [ "$slot" = "daily" ]; then
    sock="$(daily_socket)"
    target_desc="daily instance"
else
    sock="/tmp/cmux-$slot.sock"
    target_desc="$slot instance"
fi

cx() {
    env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
        CMUX_SOCKET_PATH="$sock" "$CLI" "$@"
}

# Raw v2 for session.save (no CLI subcommand needed).
v2_session_save() {
    python3 - "$sock" <<'PY2'
import json, socket, sys
s = socket.socket(socket.AF_UNIX)
s.settimeout(15)
s.connect(sys.argv[1])
s.sendall(b'{"id":1,"method":"session.save"}\n')
data = b""
while not data.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk:
        break
    data += chunk
reply = json.loads(data.decode() or "{}")
sys.exit(0 if reply.get("result", {}).get("saved") else 1)
PY2
}

# ---- self-hosting guard -------------------------------------------------
# Identify which instance THIS shell lives in (if any) by its socket.
if [ -n "${CMUX_SURFACE_ID:-}" ]; then
    my_sock="${CMUX_SOCKET_PATH:-/tmp/cmux.sock}"
    case "$slot" in
        daily) danger=$([ "$my_sock" = "$(daily_socket)" ] && echo 1 || echo 0) ;;
        *) danger=$([ "$my_sock" = "/tmp/cmux-$slot.sock" ] && echo 1 || echo 0) ;;
    esac
    if [ "$danger" = "1" ]; then
        echo "promote.sh: this shell lives INSIDE the $target_desc — it would die mid-restart." >&2
        echo "Run this from a dev-instance pane or a plain terminal instead." >&2
        exit 1
    fi
fi

# ---- build & test -------------------------------------------------------
if $build; then
    echo "== building (CMUX_GHOSTTY=1 swift build)"
    (cd "$ROOT/linux" && CMUX_GHOSTTY=1 swift build 2>&1 | tail -1)
fi
# The build above uses CMUX_GHOSTTY=1, but a stale/foreign binary can
# still be sitting there with --no-build. Never promote a backend the
# user did not ask for (2026-08-20: the daily came up VTE-only).
want=auto
for arg in "${passthrough[@]+"${passthrough[@]}"}"; do
    [ "$arg" = "--vte" ] && want=vte
    [ "$arg" = "--ghostty" ] && want=ghostty
done
"$ROOT/linux/scripts/shim-guard.sh" "$ROOT/linux/.build/debug/cmux-adw" "$want" || {
    echo "promote.sh: refusing to promote a backend mismatch" >&2
    exit 1
}

if $test; then
    echo "== running the suite"
    "$ROOT/linux/tests/run-all.sh" || {
        echo "promote.sh: suite failed — not promoting a red build" >&2
        exit 1
    }
fi

# ---- save, stop, start --------------------------------------------------
if cx ping 2>/dev/null | grep -q PONG; then
    echo "== saving the $target_desc session (final-save semantics)"
    v2_session_save \
        || echo "   (session.save not in the running binary — periodic save covers all but the last seconds)"
    echo "== stopping the $target_desc"
    for pid in $(pgrep -x cmux-adw); do
        app_id=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
        case "$slot" in
            daily) [ -z "$app_id" ] && kill "$pid" ;;
            *) [ "$app_id" = "com.manaflow.cmux.$slot" ] && kill "$pid" ;;
        esac
    done
    for _ in $(seq 1 20); do
        cx ping 2>/dev/null | grep -q PONG || break
        sleep 0.5
    done
else
    echo "== $target_desc not running — starting fresh"
fi

echo "== starting the $target_desc on the new binary"
"$START" "$slot" "${passthrough[@]+"${passthrough[@]}"}"

# ---- stamp the promote manifest (ADR-0011) ------------------------------
# Records what this slot now runs: repo SHA at promotion plus the live
# instance's capabilities snapshot. The features board reads the daily
# manifest for its "daily" column. Best-effort — never fails a promote.
stamp_manifest() {
    local state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/cmux"
    mkdir -p "$state_dir"
    python3 - "$sock" "$slot" "$state_dir/promote-$slot.json" \
        "$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo unknown)" <<'PY3'
import json, socket, sys, time, datetime
sock_path, slot, out, sha = sys.argv[1:5]
for _ in range(20):                       # the instance may still be booting
    try:
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(5)
        s.connect(sock_path)
        s.sendall(b'{"id":1,"method":"system.capabilities"}\n')
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
        methods = json.loads(data)["result"]["methods"]
        json.dump({"slot": slot, "date": datetime.date.today().isoformat(),
                   "git_sha": sha, "methods": methods}, open(out, "w"), indent=1)
        print(f"   manifest: {out} ({len(methods)} methods @ {sha[:10]})")
        sys.exit(0)
    except OSError:
        time.sleep(0.5)
sys.exit(1)
PY3
}
stamp_manifest || echo "   (manifest stamp failed — features board daily column stays stale)"

echo
echo "Promoted. Session restore brings the layout back;"
echo "resume Claude in its pane with:  claude --continue"
