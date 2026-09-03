#!/usr/bin/env bash
# Gate suite for the `cmux browser webauthn` verb group (PASSKEYS.md §0,
# passkey-desk lane): status / list / rm over the P1b vault. A credential
# store nobody can inspect is a liability — these verbs make it operable.
#
#   linux/tests/webauthn-verbs-smoke.sh [--keep]
#
# Covers: status on a missing vault, list/rm against a seeded v1
# plaintext vault (no-backend mode), the no-private-key output guarantee,
# rm error on an unknown id, and the encrypted path (host backend:
# first verb triggers the P1b migration, then list decrypts).
#
# Runs on an ISOLATED instance; the human's daily is never touched.
# Seeded fixtures use PADDED standard base64 — Foundation's Data Codable
# strategy refuses unpadded input (the P1b migration trap, PROGRESS
# 2026-09-02).
SUITE_NAME="webauthn-verbs-smoke"
APP_ID_SUFFIX="wavtest"
PAGE_PORT=8446   # unique X display slot; no fixture server needed
source "$(dirname "$0")/lib.sh"

VAULT="/tmp/cmux-$APP_ID_SUFFIX-vault.json"
suite_cleanup() {
    rm -f "$VAULT" "$VAULT.v1.bak"
    return 0
}
require_tools python3

KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true
rm -f "$VAULT" "$VAULT.v1.bak"

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

# ----------------------------------------- phase A: no vault, flag on
info "phase A: status on a fresh instance (no vault file)"
start_xvfb
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_KEY_BACKEND=none
    CMUX_WEBAUTHN_VAULT="$VAULT"
)
start_instance || exit 2
sleep 1

ST=$(cx --json browser webauthn status 2>/dev/null)
[ "$(echo "$ST" | jget enabled 2>/dev/null)" = "True" ] \
    && ok "status: enabled true under CMUX_WEBAUTHN=1" \
    || bad "status enabled" "got '$ST'"
[ "$(echo "$ST" | jget credential_count 2>/dev/null)" = "0" ] \
    && ok "status: credential_count 0 with no vault" \
    || bad "status count" "got '$ST'"

# ------------------------------- phase B: seeded v1 vault, plaintext mode
info "phase B: list/rm against a seeded v1 vault (no backend)"
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION"
python3 - "$VAULT" <<'PY'
import base64, json, sys
b64 = lambda b: base64.b64encode(b).decode()          # padded, Codable-strict
vault = {"version": 1, "credentials": [
    {"id": b64(bytes(range(32))), "rpId": "example.com",
     "userHandle": b64(b"\x07" * 16), "userName": "one@example.com",
     "userDisplayName": "One", "privateKey": b64(b"\x11" * 32),
     "createdAtMs": 1000},
    {"id": b64(bytes(range(32, 64))), "rpId": "webauthn.io",
     "userHandle": b64(b"\x08" * 16), "userName": "two@example.com",
     "userDisplayName": "Two", "privateKey": b64(b"\x22" * 32),
     "createdAtMs": 2000},
]}
json.dump(vault, open(sys.argv[1], "w"))
PY
chmod 600 "$VAULT"
# b64url (unpadded) of the first credential id — the wire format.
RM_ID=$(python3 -c "import base64; print(base64.urlsafe_b64encode(bytes(range(32))).decode().rstrip('='))")

start_instance || exit 2
sleep 1

LIST=$(cx --json browser webauthn list 2>/dev/null)
COUNT=$(echo "$LIST" | jget credentials 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
[ "$COUNT" = "2" ] \
    && ok "list: both seeded credentials visible" \
    || bad "list count" "got '$COUNT' from '$LIST'"
echo "$LIST" | grep -q '"rp_id"' && echo "$LIST" | grep -q 'webauthn.io' \
    && ok "list: rp_id fields present" \
    || bad "list fields" "$LIST"
# Guarded against a vacuous pass: an empty/failed list must not count
# as "no secrets leaked".
if [ -z "$LIST" ]; then
    bad "list secrecy" "no list output to check"
elif echo "$LIST" | grep -qi 'privateKey\|private_key'; then
    bad "list secrecy" "private key material in list output"
else
    ok "list: no private-key material in output"
fi

RM=$(cx --json browser webauthn rm --id "$RM_ID" 2>/dev/null)
[ "$(echo "$RM" | jget removed 2>/dev/null)" = "1" ] \
    && ok "rm: removed the addressed credential" \
    || bad "rm" "got '$RM'"
COUNT2=$(cx --json browser webauthn list 2>/dev/null | jget credentials 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
[ "$COUNT2" = "1" ] \
    && ok "list: one credential after rm" \
    || bad "post-rm count" "got '$COUNT2'"
FILE_COUNT=$(python3 -c "import json; print(len(json.load(open('$VAULT'))['credentials']))" 2>/dev/null)
[ "$FILE_COUNT" = "1" ] \
    && ok "vault file reflects the removal" \
    || bad "vault persistence" "file count '$FILE_COUNT'"

RM2=$(cx --json browser webauthn rm --id "$RM_ID" 2>&1)
echo "$RM2" | grep -qi 'not_found\|not found' \
    && ok "rm: unknown id answers not_found" \
    || bad "rm unknown id" "got '$RM2'"

# --------------------------------- phase C: encrypted vault (host backend)
info "phase C: encrypted path — first verb migrates, list decrypts"
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_KEY_BACKEND=host
    CMUX_WEBAUTHN_VAULT="$VAULT"
)
start_instance || exit 2
sleep 1

LIST3=$(cx --json browser webauthn list 2>/dev/null)
COUNT3=$(echo "$LIST3" | jget credentials 2>/dev/null | python3 -c "import json,sys; print(len(json.load(sys.stdin)))" 2>/dev/null)
[ "$COUNT3" = "1" ] \
    && ok "list works against the encrypted vault (migration + decrypt)" \
    || bad "encrypted list" "got '$COUNT3' from '$LIST3'"
ST3=$(cx --json browser webauthn status 2>/dev/null)
[ "$(echo "$ST3" | jget vault_encrypted 2>/dev/null)" = "True" ] \
    && ok "status: vault_encrypted true after migration" \
    || bad "status encrypted" "got '$ST3'"
[ "$(echo "$ST3" | jget vault_backend 2>/dev/null)" = "host" ] \
    && ok "status: vault_backend host" \
    || bad "status backend" "got '$ST3'"

# ------------------- phase D: undecryptable is its own typed answer
# (verbs-review finding, pk3 2026-09-03): an encrypted vault whose key
# backend is unavailable must NOT masquerade as empty — status carries
# vault_undecryptable, list/rm answer a typed error, and nothing mutates.
info "phase D: undecryptable vault answers as undecryptable, not empty"
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_KEY_BACKEND=none
    CMUX_WEBAUTHN_VAULT="$VAULT"
)
start_instance || exit 2
sleep 1

ST_D=$(cx --json browser webauthn status 2>/dev/null)
[ "$(echo "$ST_D" | jget vault_undecryptable 2>/dev/null)" = "True" ] \
    && ok "status: vault_undecryptable true when the key backend is gone" \
    || bad "status undecryptable" "got '$ST_D'"
LIST_D=$(cx --json browser webauthn list 2>&1)
echo "$LIST_D" | grep -q 'vault_undecryptable' \
    && ok "list: typed vault_undecryptable error, not an empty list" \
    || bad "list undecryptable" "got '$LIST_D'"
RM_D=$(cx --json browser webauthn rm --id AAAA 2>&1)
echo "$RM_D" | grep -q 'vault_undecryptable' \
    && ok "rm: refuses with vault_undecryptable, not not_found" \
    || bad "rm undecryptable" "got '$RM_D'"

# Recovery: the key backend returns, everything reads normally again.
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_KEY_BACKEND=host
    CMUX_WEBAUTHN_VAULT="$VAULT"
)
start_instance || exit 2
sleep 1
ST_R=$(cx --json browser webauthn status 2>/dev/null)
[ "$(echo "$ST_R" | jget vault_undecryptable 2>/dev/null)" = "False" ] \
    && ok "recovery: vault_undecryptable false with the backend back" \
    || bad "recovery flag" "got '$ST_R'"
[ "$(echo "$ST_R" | jget credential_count 2>/dev/null)" = "1" ] \
    && ok "recovery: the credential is readable again (nothing was lost)" \
    || bad "recovery count" "got '$ST_R'"

echo
echo "== webauthn-verbs-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
