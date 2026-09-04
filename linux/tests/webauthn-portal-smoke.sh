#!/usr/bin/env bash
# Gate suite for the P1b Secret-PORTAL key backend — the first time that
# code path EXECUTES anywhere (it only answers inside a sandbox; PASSKEYS
# §0 flatpak round, portal-over-talk-name decided in d998211c26).
#
#   linux/tests/webauthn-portal-smoke.sh [--keep]
#
# Drives the INSTALLED flatpak (app id com.manaflow.cmux), not a .build
# binary: launches it on a private X display with suite-named vault,
# session and socket (the user's per-app data is never touched), then
# uses the browser.webauthn verbs as the probe instrument — a seeded v1
# vault plus one `status` call exercises the ENTIRE portal path (gdbus
# fd-passing, pipe read, HKDF expansion, AES-GCM migration) with no UI.
# A relaunch leg proves the portal secret is stable across instances —
# the property the whole backend stands on.
#
# Exit 2 when the flatpak is not installed (build it first:
# linux/scripts/flatpak-build.sh install). Kills ONLY its own recorded
# pids — `flatpak kill <id>` would take down a user's running instance.
SUITE_NAME="webauthn-portal-smoke"
PAGE_PORT=8447   # display slot only (lib.sh formula), no fixture server
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
FLATPAK_APP=com.manaflow.cmux
XDISPLAY=":$(( 90 + (PAGE_PORT % 50) ))"
RUNTIME_APP_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/app/$FLATPAK_APP"
DATA_DIR="$HOME/.var/app/$FLATPAK_APP/data/cmux-flatpak"
VAULT="$DATA_DIR/portal-smoke-vault.json"
SESSION="$DATA_DIR/portal-smoke-session.json"
SOCKET="$RUNTIME_APP_DIR/portal-smoke.sock"
CLI="$ROOT/.build/debug/cmux"

KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

APP_PID=""
XVFB_PID=""
XAUTH_FILE=""
cleanup() {
    local pid
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null \
            | grep -q '^CMUX_APP_ID=com.manaflow.cmux.portalsmoke$' && kill "$pid" 2>/dev/null
    done
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
    [ -n "$XVFB_PID" ] && kill "$XVFB_PID" 2>/dev/null
    if ! $KEEP; then
        rm -f "$VAULT" "$VAULT.v1.bak" "$SESSION" "$SOCKET"
        rm -rf "$DATA_DIR/portal-smoke-session-scrollback"
        rm -f "$XAUTH_FILE"
    fi
}
trap cleanup EXIT

flatpak info --user "$FLATPAK_APP" >/dev/null 2>&1 \
    || { echo "$SUITE_NAME: $FLATPAK_APP not installed (flatpak-build.sh install)"; exit 2; }
[ -x "$CLI" ] || { echo "$SUITE_NAME: host CLI missing — cd linux && swift build"; exit 2; }
command -v Xvfb >/dev/null 2>&1 || { echo "$SUITE_NAME: Xvfb missing"; exit 2; }

# cx: the HOST CLI against the sandboxed instance's socket, identity
# scrubbed like every sibling suite.
cx() { env -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID CMUX_QUIET=1 CMUX_SOCKET_PATH="$SOCKET" "$CLI" "$@"; }
jget() { python3 -c "
import json,sys
d = json.load(sys.stdin)
cur = d
for k in sys.argv[1:]:
    cur = cur.get(k) if isinstance(cur, dict) else None
print(json.dumps(cur) if isinstance(cur,(dict,list)) else cur)" "$@"; }

launch_flatpak() {
    # flatpak run forwards the ambient env — scrub pane identity (the
    # build script's own lesson). Display plumbing, all three measured
    # 2026-09-04: (1) the manifest's fallback-x11 binds X only when
    # Wayland is ABSENT, so on a Wayland desktop the suite adds
    # --socket=x11 per-invocation (never to the manifest); (2) flatpak
    # binds exactly the HOST's $DISPLAY socket, so DISPLAY is set on the
    # flatpak run process, not via --env; (3) the cookie comes from
    # $XAUTHORITY — hence the minted Xvfb cookie above.
    env -u CMUX_SOCKET_PATH -u CMUX_SOCKET_PASSWORD \
        -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
        -u CMUX_TAB_ID -u CMUX_PANEL_ID -u CMUX_SESSION_PATH \
        DISPLAY="$XDISPLAY" XAUTHORITY="$XAUTH_FILE" \
        flatpak run --user \
        --socket=x11 --nosocket=wayland \
        --env=CMUX_APP_ID=com.manaflow.cmux.portalsmoke \
        --env=CMUX_SOCKET_PATH="$SOCKET" \
        --env=CMUX_SESSION_PATH="$SESSION" \
        --env=CMUX_WEBAUTHN=1 \
        --env=CMUX_WEBAUTHN_VAULT="$VAULT" \
        --env=GDK_BACKEND=x11 \
        "$FLATPAK_APP" >/dev/null 2>&1 &
    APP_PID=$!
    local _
    for _ in $(seq 1 30); do
        cx ping >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

stop_flatpak() {
    # Killing the `flatpak run` wrapper ORPHANS the bwrap'd app, which
    # then keeps the GApplication id + socket and turns the next launch
    # into a forward-and-exit. Kill the sandboxed cmux-adw itself, by
    # suite APP_ID env match only (house rule), then the wrapper.
    local pid _
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null \
            | grep -q '^CMUX_APP_ID=com.manaflow.cmux.portalsmoke$' && kill "$pid" 2>/dev/null
    done
    [ -n "$APP_PID" ] && kill "$APP_PID" 2>/dev/null
    for _ in $(seq 1 10); do
        pgrep -x cmux-adw 2>/dev/null | while read -r pid; do
            tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null \
                | grep -q portalsmoke && exit 1
        done && break
        sleep 1
    done
    APP_PID=""
    rm -f "$SOCKET"
}

# ---------------------------------------------------------------- setup
info "manifest: the portal needs NO secrets finish-arg (the decided design)"
if flatpak info --user --show-permissions "$FLATPAK_APP" 2>/dev/null | grep -q 'org.freedesktop.secrets'; then
    bad "zero-finish-arg" "a secrets talk-name crept into the manifest"
else
    ok "no org.freedesktop.secrets grant — portal is default-reachable"
fi

mkdir -p "$DATA_DIR"
rm -f "$VAULT" "$VAULT.v1.bak" "$SESSION"
# Seeded v1 vault: PADDED standard base64 (the Foundation-strict trap,
# thrice would be too many).
python3 - "$VAULT" <<'PY'
import base64, json, sys
b64 = lambda b: base64.b64encode(b).decode()
vault = {"version": 1, "credentials": [
    {"id": b64(bytes(range(32))), "rpId": "example.com",
     "userHandle": b64(b"\x07" * 16), "userName": "portal-one@example.com",
     "userDisplayName": "Portal One", "privateKey": b64(b"\x11" * 32),
     "createdAtMs": 1000},
    {"id": b64(bytes(range(32, 64))), "rpId": "webauthn.io",
     "userHandle": b64(b"\x08" * 16), "userName": "portal-two@example.com",
     "userDisplayName": "Portal Two", "privateKey": b64(b"\x22" * 32),
     "createdAtMs": 2000},
]}
json.dump(vault, open(sys.argv[1], "w"))
PY
chmod 600 "$VAULT"

# Flatpak's x11 socket setup transfers the xauth cookie for the HOST's
# $DISPLAY — a cookie-less Xvfb can never be bound ("Failed to open
# display" with no further hint). Mint a cookie the way xvfb-run does.
XAUTH_FILE=$(mktemp)
xauth -f "$XAUTH_FILE" add "$XDISPLAY" MIT-MAGIC-COOKIE-1 "$(mcookie)"
Xvfb "$XDISPLAY" -screen 0 1280x800x24 -auth "$XAUTH_FILE" >/dev/null 2>&1 &
XVFB_PID=$!
sleep 2

# ------------------------------------------- leg 1: portal key resolves
info "leg 1: in-sandbox launch, portal key resolution via migration"
launch_flatpak || { bad "launch" "sandboxed instance never answered ping on $SOCKET"; exit 1; }
ok "sandboxed instance answers ping over the shared runtime socket"

ST=$(cx --json browser webauthn status 2>/dev/null)
[ "$(echo "$ST" | jget vault_encrypted 2>/dev/null)" = "True" ] \
    && ok "v1 vault migrated to an encrypted envelope IN-SANDBOX" \
    || bad "portal encryption" "got '$ST'"
[ "$(echo "$ST" | jget vault_backend 2>/dev/null)" = "portal" ] \
    && ok "vault_backend is 'portal' — the Secret portal answered a real call" \
    || bad "portal backend" "got '$ST'"
[ "$(echo "$ST" | jget vault_undecryptable 2>/dev/null)" = "False" ] \
    && [ "$(echo "$ST" | jget credential_count 2>/dev/null)" = "2" ] \
    && ok "both credentials decrypt through the HKDF-derived key" \
    || bad "portal decrypt" "got '$ST'"

LIST=$(cx --json browser webauthn list 2>/dev/null)
if [ -z "$LIST" ]; then
    bad "list secrecy" "no list output to check"
elif echo "$LIST" | grep -qi 'privateKey\|private_key'; then
    bad "list secrecy" "private key material in list output"
else
    echo "$LIST" | grep -q 'webauthn.io' \
        && ok "list decrypts and carries metadata only" \
        || bad "list content" "$LIST"
fi

python3 -c "
import json, sys
d = json.load(open('$VAULT'))
sys.exit(0 if d.get('version') == 2 and d.get('backend') == 'portal' else 1)" \
    && ok "on-disk envelope records backend 'portal'" \
    || bad "envelope on disk" "$(head -c 120 "$VAULT")"

# --------------------------- leg 2: the portal secret is STABLE across
# launches — without this, every restart would orphan the vault.
info "leg 2: relaunch — same per-app secret, vault still decrypts"
stop_flatpak
launch_flatpak || { bad "relaunch" "second instance never answered ping"; exit 1; }
ST2=$(cx --json browser webauthn status 2>/dev/null)
[ "$(echo "$ST2" | jget credential_count 2>/dev/null)" = "2" ] \
    && [ "$(echo "$ST2" | jget vault_undecryptable 2>/dev/null)" = "False" ] \
    && ok "relaunch decrypts the same vault (portal secret is stable)" \
    || bad "portal stability" "got '$ST2'"
[ -f "$VAULT.v1.bak" ] \
    && bad "migration backup retirement" ".v1.bak still present after decrypt-reads" \
    || ok ".v1.bak retired after the first successful decrypt-read"

echo
echo "== webauthn-portal-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
