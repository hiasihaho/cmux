#!/usr/bin/env bash
# Gate suite for the vault-key ISOLATION fix (PASSKEYS.md §0; the
# data-safety defect that destroyed hias' two dogfood passkeys
# 2026-09-10). Three layers, all in WebAuthnVaultKeyProvider.swift:
#   (1) the host keyring key was GLOBAL (service=cmux,
#       purpose=webauthn-vault-key, no vault scoping), so every isolated
#       test instance read and could OVERWRITE the key protecting the
#       developer's real vault;
#   (2) a lookup miss SILENTLY minted a replacement, orphaning whatever
#       the old key encrypted;
#   (3) the envelope could not name its key, which made (2) silent.
#
# This suite covers layer (1)'s closure: a gated FILE key backend that
# takes tests OFF the real Secret Service entirely. It must NEVER touch
# the host keyring, so — unlike the sibling suites before this fix — it
# is safe to run on a machine whose passkeys matter. B and C (never
# re-key silently; key_id in a v3 envelope) are covered in
# webauthn-smoke's vault phases.
#
#   linux/tests/webauthn-keyisolation-smoke.sh [--keep]
#
# Runs on ISOLATED instances; the daily is never touched, and neither is
# the developer's keyring.
SUITE_NAME="webauthn-keyisolation-smoke"
APP_ID_SUFFIX="wkitest"
PAGE_PORT=8448
source "$(dirname "$0")/lib.sh"

VAULT="/tmp/cmux-$APP_ID_SUFFIX-vault.json"
KEYFILE="$VAULT.key"        # the file backend stores the key beside the vault
suite_cleanup() {
    rm -f "$VAULT" "$VAULT".* "$KEYFILE"
    return 0
}
require_tools python3

KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true
WORK=$(mktemp -d)
rm -f "$VAULT" "$VAULT".* "$KEYFILE"

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1

jget() { python3 -c "
import json,sys
d = json.load(sys.stdin)
cur = d
for k in sys.argv[1:]:
    cur = cur.get(k) if isinstance(cur, dict) else None
print(json.dumps(cur) if isinstance(cur,(dict,list)) else cur)" "$@"; }

# The load-bearing safety check: record the developer keyring's cmux item
# state BEFORE anything runs, so we can prove the suite never wrote it.
# READ-ONLY: we look the item up, we never store or delete it.
keyring_fingerprint() {
    secret-tool lookup service cmux purpose webauthn-vault-key 2>/dev/null | sha256sum | cut -d' ' -f1
}
KEYRING_BEFORE=$(keyring_fingerprint)

start_xvfb

# A seeded v1 plaintext vault: one `status` call then triggers
# load() -> migrate -> resolve the key backend -> write a v2 envelope,
# which is the whole key path with no browser ceremony (the portal
# suite's instrument). PADDED base64 (the Foundation-strict trap).
seed_v1() {
    python3 - "$1" <<'PY'
import base64, json, sys
b64 = lambda b: base64.b64encode(b).decode()
json.dump({"version": 1, "credentials": [
    {"id": b64(bytes(range(32))), "rpId": "example.com",
     "userHandle": b64(b"\x07"*16), "userName": "iso@example.com",
     "userDisplayName": "Iso", "privateKey": b64(b"\x11"*32),
     "createdAtMs": 1000}]}, open(sys.argv[1], "w"))
PY
    chmod 600 "$1"
}

# ------------------------------------------------ file backend resolves
info "the file backend encrypts without touching the keyring"
rm -f "$SESSION" "$VAULT" "$KEYFILE"
seed_v1 "$VAULT"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=async
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=file
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1
ST=$(cx --json browser webauthn status 2>/dev/null)
[ "$(echo "$ST" | jget vault_backend 2>/dev/null)" = "file" ] \
    && ok "vault_backend is 'file' when CMUX_WEBAUTHN_KEY_BACKEND=file + redirected vault" \
    || bad "file backend" "got '$ST'"
[ -f "$KEYFILE" ] \
    && ok "the key lives in a file beside the redirected vault" \
    || bad "key file" "no key file at $KEYFILE"
if [ -f "$KEYFILE" ]; then
    PERMS=$(stat -c %a "$KEYFILE")
    [ "$PERMS" = "600" ] && ok "key file is 0600" || bad "key file perms" "$PERMS"
fi

# ---------------------------------------- the gate: file needs a redirect
info "the file backend refuses the DEFAULT vault (S3 gate)"
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION"
: > "$LOG"
# No CMUX_WEBAUTHN_VAULT: the default vault (under a throwaway
# XDG_DATA_HOME so the real one is untouched). A file backend here would
# be a new way to key the real vault off an attacker-plantable file, so
# it must refuse and say so — exactly like the UV test backend. Seed a
# v1 vault at the DEFAULT path so a status call forces the migration that
# resolves (and refuses) the backend.
mkdir -p "$WORK/xdgdata-default/cmux"
seed_v1 "$WORK/xdgdata-default/cmux/webauthn-credentials.json"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_KEY_BACKEND=file
    XDG_DATA_HOME="$WORK/xdgdata-default"
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1
cx --json browser webauthn status >/dev/null 2>&1   # force load()->migrate->resolve
grep -q "file key backend ignored" "$LOG" \
    && ok "file backend refuses a default vault, and logs why" \
    || bad "file gate" "no 'file key backend ignored' line — the file backend would key a real vault"

# ------------------------------------- the whole point: keyring untouched
info "no test instance touched the developer keyring"
KEYRING_AFTER=$(keyring_fingerprint)
[ "$KEYRING_BEFORE" = "$KEYRING_AFTER" ] \
    && ok "the real 'cmux WebAuthn vault key' item is byte-identical before and after" \
    || bad "KEYRING MUTATED" "the suite changed the developer's real vault key — the exact defect"

echo
echo "== webauthn-keyisolation-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
