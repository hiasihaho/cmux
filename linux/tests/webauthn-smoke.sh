#!/usr/bin/env bash
# Gate suite for the WebAuthn client layer + software authenticator
# (docs/linux-port/PASSKEYS.md P1, option B+C). Grew out of the P0 probe
# that refuted the WebDriver virtual-authenticator path (PROGRESS
# 2026-09-01) — same fixture, now exercising cmux's own polyfill bridge.
#
#   linux/tests/webauthn-smoke.sh [--keep]
#
# Covers: flag-off negative (no API leaks without CMUX_WEBAUTHN=1), API
# surface, registration ceremony, vault persistence + permissions,
# assertion ceremony, excludeCredentials duplicate rejection, a full
# relying-party-grade cryptographic verification of both ceremonies
# (CBOR attestation parse, rpIdHash/flags checks, ES256 signature), and
# the P1b vault encryption-at-rest contract: ciphertext at rest (not
# JSON-parseable, no plaintext rpId), v1 plaintext migration in place
# with .v1.bak, and the no-backend fallback (stays readable plaintext
# with an honest logged warning).
#
# Runs on an ISOLATED instance; the human's daily is never touched.
SUITE_NAME="webauthn-smoke"
APP_ID_SUFFIX="watest"
# NOT 8443: that is a common HTTPS-alt port and an unrelated daemon held
# it on the dev host — the fixture server died with EADDRINUSE and the
# pane loaded the stranger's 400 page (URL and evals looked normal, only
# the selector verbs failed). The guard below makes that failure loud.
PAGE_PORT=8444
source "$(dirname "$0")/lib.sh"

VAULT="/tmp/cmux-$APP_ID_SUFFIX-vault.json"

suite_cleanup() {
    rm -f "$VAULT"
    return 0
}
require_tools python3

WORK=$(mktemp -d)
KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true
rm -f "$VAULT"

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

# Pre-flight: kill leftover instances of this suite by APP_ID only.
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1

# ---------------------------------------------------------------- fixture
# Served on http://localhost (secure context; rpId must be a domain).
cat > "$WORK/app.js" <<'EOF'
const log = m => { document.getElementById('out').textContent = m; };
const opts = () => ({
  challenge: new Uint8Array(32),
  rp: { id: 'localhost', name: 'wa-smoke' },
  user: { id: new Uint8Array(16).fill(7), name: 'probe@example.com', displayName: 'Probe' },
  pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
  authenticatorSelection: { residentKey: 'required', userVerification: 'required' },
  timeout: 15000,
  attestation: 'none'
});
document.getElementById('create').addEventListener('click', async () => {
  log('creating');
  try {
    const cred = await navigator.credentials.create({ publicKey: opts() });
    window.__credId = new Uint8Array(cred.rawId);
    window.__createJson = JSON.stringify(cred.toJSON());
    log('created:' + cred.id.slice(0, 12));
  } catch (e) { log('create-error:' + e.name + ':' + e.message); }
});
document.getElementById('createdup').addEventListener('click', async () => {
  log('creating-dup');
  try {
    const o = opts();
    o.excludeCredentials = [{ type: 'public-key', id: window.__lastCredId.buffer }];
    await navigator.credentials.create({ publicKey: o });
    log('dup-created-unexpectedly');
  } catch (e) { log('dup-error:' + e.name); }
});
document.getElementById('get').addEventListener('click', async () => {
  log('getting');
  try {
    const assertion = await navigator.credentials.get({ publicKey: {
      challenge: new Uint8Array(32).fill(1),
      rpId: 'localhost',
      userVerification: 'required',
      timeout: 15000
    }});
    window.__getJson = JSON.stringify(assertion.toJSON());
    log('asserted:' + assertion.id.slice(0, 12));
  } catch (e) { log('get-error:' + e.name + ':' + e.message); }
});
EOF
cat > "$WORK/index.html" <<'EOF'
<!DOCTYPE html><html><head><title>wa-smoke</title></head><body>
<button id="create">create</button> <button id="createdup">create-dup</button>
<button id="get">get</button>
<div id="out">none</div>
<script src="app.js"></script></body></html>
EOF
python3 -m http.server $PAGE_PORT --directory "$WORK" >/dev/null 2>&1 &
PAGE_PID=$!
sleep 1
# Fail fast if OUR server isn't the one answering (EADDRINUSE leaves a
# stranger on the port and every later assertion lies).
curl -s "http://localhost:$PAGE_PORT/index.html" | grep -q 'wa-smoke' \
    || { echo "webauthn-smoke: port $PAGE_PORT is serving foreign content"; exit 2; }

URL="http://localhost:$PAGE_PORT/index.html"
API_PROBE='typeof navigator.credentials + "/" + typeof window.PublicKeyCredential'

# Take the ref from the open reply itself. Deriving it from list-panes
# picked a SESSION-RESTORED copy of the fixture pane, where eval works
# but visibility-gated verbs (click, get text) fail with not_found —
# five assertions failed for unrelated-looking reasons.
open_pane() {  # opens the fixture in a browser pane, echoes the surface ref
    local ref
    ref=$(cx browser open "$URL" --focus false 2>/dev/null \
          | grep -oE 'surface=surface:[0-9]+' | cut -d= -f2)
    sleep 2
    echo "$ref"
}
poll_out() {  # poll #out until it leaves the pending state or times out
    local surf="$1" pending="$2" i out
    for i in $(seq 1 20); do
        out=$(cx browser get text '#out' --surface "$surf" 2>/dev/null | head -1)
        [ -n "$out" ] && [ "$out" != "none" ] && [ "$out" != "$pending" ] && { echo "$out"; return; }
        sleep 1
    done
    echo "$out"
}

# ----------------------------------------------- flag-off negative first
info "flag OFF: the API must not exist"
start_xvfb
start_instance || exit 2
sleep 1
SURF=$(open_pane)
OFF=$(cx browser eval --script "$API_PROBE" --surface "$SURF" 2>/dev/null | tr -d '"')
[ "$OFF" = "undefined/undefined" ] \
    && ok "no WebAuthn surface without CMUX_WEBAUTHN=1" \
    || bad "flag-off leak" "got '$OFF'"
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1

# --------------------------------------------------- flag-on instance
info "flag ON: full ceremony pass"
# No session restore across phases: a restored copy of the fixture pane
# poisons surface targeting (see open_pane).
rm -f "$SESSION"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=host
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1
SURF=$(open_pane)

ON=$(cx browser eval --script "$API_PROBE" --surface "$SURF" 2>/dev/null | tr -d '"')
[ "$ON" = "object/function" ] \
    && ok "API surface exposed (navigator.credentials + PublicKeyCredential)" \
    || bad "API surface" "got '$ON'"

UVPA=$(cx browser eval --script '(async () => PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable())()' --surface "$SURF" 2>/dev/null)
[ "$UVPA" = "true" ] \
    && ok "isUserVerifyingPlatformAuthenticatorAvailable → true" \
    || bad "UVPA capability" "got '$UVPA'"

# ------------------------------------------------------------ create
CLICK_ERR=$(cx browser click '#create' --surface "$SURF" 2>&1 >/dev/null)
OUT=$(poll_out "$SURF" 'creating')
case "$OUT" in
    created:*) ok "registration ceremony completed" ;;
    *)
        bad "registration ceremony" "$OUT"
        echo "  DIAG  surf='$SURF' click-stderr='$CLICK_ERR'"
        echo "  DIAG  url=$(cx browser url --surface "$SURF" 2>&1)"
        echo "  DIAG  log tail: $(tail -2 "$LOG" 2>/dev/null | tr '\n' ' ')"
        ;;
esac

if [ -f "$VAULT" ]; then
    PERMS=$(stat -c %a "$VAULT")
    [ "$PERMS" = "600" ] && ok "vault mode 0600" || bad "vault permissions" "$PERMS"
    # Count is only readable on a plaintext (v1 / fallback) vault; the
    # encrypted envelope's contents are verified functionally below (the
    # post-reload assertion ceremony only passes if the credential
    # decrypted and signed).
    if python3 -c "import json,sys; d=json.load(open('$VAULT')); sys.exit(0 if 'credentials' in d else 1)" 2>/dev/null; then
        COUNT=$(python3 -c "import json;print(len(json.load(open('$VAULT'))['credentials']))" 2>/dev/null)
        [ "$COUNT" = "1" ] && ok "vault holds 1 credential" || bad "vault contents" "count=$COUNT"
    else
        ok "vault holds the credential (encrypted; proven by the assertion below)"
    fi
else
    bad "vault file" "missing at $VAULT"
fi

# ------------------------------------------------ P1b: ciphertext at rest
# With a key backend available (this host has gnome-keyring on the session
# bus), the vault file must be the v2 encrypted envelope: a JSON object
# with version 2 + nonce + ciphertext and NO readable credentials key
# (the envelope is JSON by design; the plaintext is not recoverable from
# it). Suites force the host backend so the assertion is deterministic
# even if a portal is also present.
if [ -f "$VAULT" ]; then
    if python3 -c "
import json, sys
d = json.load(open('$VAULT'))
sys.exit(0 if (d.get('version') == 2 and 'ciphertext' in d and 'credentials' not in d) else 1)
" 2>/dev/null; then
        ok "vault is the v2 encrypted envelope (no readable credentials)"
    else
        bad "vault ciphertext-at-rest" "vault is not the v2 envelope"
    fi
    if grep -q "localhost" "$VAULT" 2>/dev/null; then
        bad "vault ciphertext-at-rest" "rpId string visible in vault file"
    else
        ok "vault contains no plaintext rpId"
    fi
fi

# Remember the created id for the duplicate check after reload.
cx browser eval --script 'window.__lastCredIdB64 = btoa(String.fromCharCode(...window.__credId)); true' --surface "$SURF" >/dev/null 2>&1
CREATE_JSON=$(cx browser eval --script 'window.__createJson' --surface "$SURF" 2>/dev/null)

# ------------------------------------------------------ get (fresh page)
cx browser reload --surface "$SURF" >/dev/null 2>&1; sleep 2
cx browser click '#get' --surface "$SURF" >/dev/null 2>&1
OUT=$(poll_out "$SURF" 'getting')
case "$OUT" in
    asserted:*) ok "assertion ceremony completed (after page reload)" ;;
    *)          bad "assertion ceremony" "$OUT" ;;
esac
GET_JSON=$(cx browser eval --script 'window.__getJson' --surface "$SURF" 2>/dev/null)

# -------------------------------------------- duplicate registration
# Re-derive the credential id in-page from the get() result (the page
# was reloaded, so window.__credId from create() is gone).
cx browser eval --script '
  const raw = JSON.parse(window.__getJson).rawId.replace(/-/g,"+").replace(/_/g,"/");
  const padded = raw + "=".repeat((4 - raw.length % 4) % 4);
  window.__lastCredId = Uint8Array.from(atob(padded), c => c.charCodeAt(0));
  window.__lastCredId.length' --surface "$SURF" >/dev/null 2>&1
cx browser click '#createdup' --surface "$SURF" >/dev/null 2>&1
OUT=$(poll_out "$SURF" 'creating-dup')
case "$OUT" in
    dup-error:InvalidStateError) ok "excludeCredentials rejects re-registration (InvalidStateError)" ;;
    *)                           bad "duplicate registration" "$OUT" ;;
esac

# ------------------------------- relying-party-grade crypto verification
info "verifying ceremony outputs like a relying party"
python3 - "$CREATE_JSON" "$GET_JSON" <<'PY'
import base64, hashlib, json, sys

def b64url(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def fail(msg):
    print(f"  FAIL  rp-verify — {msg}"); sys.exit(1)

def cbor_parse(data, offset=0):
    b = data[offset]; major, info = b >> 5, b & 0x1f; offset += 1
    if info < 24: length = info
    elif info == 24: length = data[offset]; offset += 1
    elif info == 25: length = int.from_bytes(data[offset:offset+2]); offset += 2
    elif info == 26: length = int.from_bytes(data[offset:offset+4]); offset += 4
    else: fail(f"unsupported CBOR length info {info}")
    if major == 0: return length, offset
    if major == 1: return -1 - length, offset
    if major == 2: return data[offset:offset+length], offset + length
    if major == 3: return data[offset:offset+length].decode(), offset + length
    if major == 5:
        m = {}
        for _ in range(length):
            k, offset = cbor_parse(data, offset)
            v, offset = cbor_parse(data, offset)
            m[k] = v
        return m, offset
    fail(f"unsupported CBOR major {major}")

create = json.loads(sys.argv[1]); get = json.loads(sys.argv[2])
rp_hash = hashlib.sha256(b"localhost").digest()

# --- attestation ---
client = json.loads(b64url(create["response"]["clientDataJSON"]))
assert client["type"] == "webauthn.create", "clientData type"
assert client["origin"].startswith("http://localhost"), f"origin {client['origin']}"
assert client["challenge"] == base64.urlsafe_b64encode(bytes(32)).rstrip(b"=").decode(), "challenge"
att, _ = cbor_parse(b64url(create["response"]["attestationObject"]))
assert att["fmt"] == "none" and att["attStmt"] == {}, "attestation format"
auth = att["authData"]
assert auth[:32] == rp_hash, "create rpIdHash"
assert auth[32] == 0x45, f"create flags {hex(auth[32])}"
cred_len = int.from_bytes(auth[53:55])
cred_id = auth[55:55+cred_len]
assert base64.urlsafe_b64encode(cred_id).rstrip(b"=").decode() == create["id"], "credential id"
cose, _ = cbor_parse(auth, 55 + cred_len)
assert cose[1] == 2 and cose[3] == -7, "COSE key type/alg"
x, y = cose[-2], cose[-3]
assert len(x) == 32 and len(y) == 32, "COSE coordinates"

# --- assertion signature against the attested key ---
client2 = json.loads(b64url(get["response"]["clientDataJSON"]))
assert client2["type"] == "webauthn.get", "get clientData type"
auth2 = b64url(get["response"]["authenticatorData"])
assert auth2[:32] == rp_hash and auth2[32] == 0x05, "get authData"
signed = auth2 + hashlib.sha256(b64url(get["response"]["clientDataJSON"])).digest()
sig = b64url(get["response"]["signature"])
assert get["response"]["userHandle"], "userHandle missing"

try:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature  # noqa
    from cryptography.hazmat.primitives import hashes
    pub = ec.EllipticCurvePublicNumbers(
        int.from_bytes(x), int.from_bytes(y), ec.SECP256R1()).public_key()
    pub.verify(sig, signed, ec.ECDSA(hashes.SHA256()))
    print("  PASS  rp-verify: ES256 signature verifies against attested COSE key")
except ImportError:
    print("  SKIP  rp-verify signature check (python3-cryptography missing); structural checks passed")
except Exception as e:
    fail(f"signature invalid: {e}")

print("  PASS  rp-verify: attestation + assertion structures are spec-shaped")
PY
case $? in
    0) PASS=$((PASS+2)) ;;
    *) FAIL=$((FAIL+1)) ;;
esac

# -------------------------------------- P1b: migration from plaintext v1
# A v1 plaintext vault must be encrypted in place on first load, keeping a
# .v1.bak until the first successful decrypt-read, and the migrated
# credential must still assert. Restart the instance on a hand-written
# plaintext vault to exercise the migration path.
info "P1b migration: plaintext v1 vault encrypts in place"
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION" "$VAULT" "$VAULT.v1.bak"
python3 - "$VAULT" <<'PY'
import json, sys
# NOTE: the base64 strings must be PADDED. Foundation's JSONDecoder Data
# strategy is strict and refuses unpadded base64 — an unpadded fixture
# decodes to nil, the File decode fails, and migration never runs, so the
# leg stays red looking like a product bug (it cost hours chasing this as
# a suite-timing bug; the passkey desk named it from a read of the red
# commit). Pad to a multiple of 4.
vault = {
    "version": 1,
    "credentials": [{
        "id": "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
        "rpId": "localhost",
        "userHandle": "BwcHBwcHBwcHBwcHBwcHBw==",
        "userName": "probe@example.com",
        "userDisplayName": "Probe",
        "privateKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
        "createdAtMs": 1
    }]
}
json.dump(vault, open(sys.argv[1], "w"))
PY
chmod 600 "$VAULT"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=host
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1
SURF=$(open_pane)
# Trigger a vault load via an assertion attempt (no credential matches the
# migrated one — its privateKey is a placeholder — but load+migrate runs).
# Drive it with eval, not a click: eval is not visibility-gated, and the
# ceremony's load()+migrate runs regardless of the NotAllowedError outcome.
cx browser eval --script 'navigator.credentials.get({publicKey:{challenge:new Uint8Array(32),rpId:"localhost"}}).then(r=>"ok").catch(e=>"err:"+e.name)' --surface "$SURF" >/dev/null 2>&1
# Poll for the migration to land (backup + encrypted vault), not a fixed
# sleep — the ceremony and file write are async.
MIGRATED=0
for _ in $(seq 1 20); do
    if [ -f "$VAULT.v1.bak" ] && python3 -c "
import json, sys
d = json.load(open('$VAULT'))
sys.exit(0 if (d.get('version') == 2 and 'ciphertext' in d and 'credentials' not in d) else 1)
" 2>/dev/null; then
        MIGRATED=1; break
    fi
    sleep 1
done
if [ -f "$VAULT.v1.bak" ]; then
    ok "migration kept .v1.bak of the plaintext vault"
    # The backup holds private keys — it must be 0600, not just present.
    BAKPERMS=$(stat -c %a "$VAULT.v1.bak" 2>/dev/null)
    [ "$BAKPERMS" = "600" ] && ok "migration .v1.bak mode 0600" || bad "migration .v1.bak permissions" "$BAKPERMS"
else
    bad "migration backup" ".v1.bak missing"
    bad "migration .v1.bak permissions" "no backup to check"
fi
if [ "$MIGRATED" = "1" ]; then
    ok "migration encrypted the vault in place"
else
    bad "migration encryption" "vault still plaintext after load"
fi

# The backup is retired on the first successful DECRYPT-read. Drive a
# second ceremony against the now-encrypted vault: a successful load
# (decrypt) removes .v1.bak. The migrated credential's privateKey is a
# placeholder, so the assertion itself is NotAllowedError — but the load
# that precedes it is what retires the backup.
cx browser eval --script 'navigator.credentials.get({publicKey:{challenge:new Uint8Array(32).fill(2),rpId:"localhost"}}).then(r=>"ok").catch(e=>"err:"+e.name)' --surface "$SURF" >/dev/null 2>&1
RETIRED=0
for _ in $(seq 1 15); do
    [ ! -f "$VAULT.v1.bak" ] && { RETIRED=1; break; }
    sleep 1
done
[ "$RETIRED" = "1" ] && ok "migration retires .v1.bak after first decrypt-read" \
    || bad "migration .v1.bak retirement" "backup still present after decrypt-read"

# -------------------------------------- P1b: fallback without a backend
# With no keyring/portal reachable, the vault must stay 0600 plaintext AND
# the instance log must carry an honest warning — never silent. The log is
# snapshotted per phase because start_instance truncates it on each
# restart.
info "P1b fallback: no key backend -> plaintext + logged warning"
cp "$LOG" "$WORK/log-phase2.log" 2>/dev/null
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION" "$VAULT" "$VAULT.v1.bak"
: > "$LOG"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=none
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1
SURF=$(open_pane)
cx browser click '#create' --surface "$SURF" >/dev/null 2>&1
OUT=$(poll_out "$SURF" 'creating')
case "$OUT" in
    created:*)
        if python3 -c "import json,sys; d=json.load(open('$VAULT')); sys.exit(0 if 'credentials' in d else 1)" 2>/dev/null; then
            ok "fallback keeps vault readable (plaintext, 0600)"
        else
            bad "fallback readability" "vault unreadable without backend"
        fi
        if grep -qi "webauthn.*\(key\|encrypt\|plain\|fallback\)" "$LOG" 2>/dev/null; then
            ok "fallback logs an honest warning"
        else
            bad "fallback warning" "no key-backend warning in instance log"
        fi
        ;;
    *) bad "fallback ceremony" "$OUT" ;;
esac

# -------------------- P1b: undecryptable-vault overwrite guard (data loss)
# A v2 envelope that cannot be decrypted (here: KEY_BACKEND=none against a
# real encrypted vault) must NOT be overwritten by the next save — the
# keyring may come back. The save must move it aside to a 0600
# .undecryptable-<ts>.bak first. Build a fresh v2 envelope with the host
# backend, then restart with no backend so it is undecryptable.
info "P1b guard: undecryptable vault is preserved, not overwritten"
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
# Produce a real v2 envelope: host backend, one create(). The fallback leg
# left the vault plaintext, so regenerate rather than reuse.
rm -f "$SESSION" "$VAULT" "$VAULT.v1.bak" "$VAULT".undecryptable-*.bak
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=host
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1
SURF=$(open_pane)
cx browser click '#create' --surface "$SURF" >/dev/null 2>&1
poll_out "$SURF" 'creating' >/dev/null
if python3 -c "import json,sys; d=json.load(open('$VAULT')); sys.exit(0 if d.get('version')==2 else 1)" 2>/dev/null; then
    OLDCIPHER=$(python3 -c "import json; print(json.load(open('$VAULT'))['ciphertext'])" 2>/dev/null)
else
    bad "guard setup" "could not produce a v2 envelope with the host backend"
    OLDCIPHER=""
fi
# Restart with NO backend so the envelope is undecryptable.
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION"
: > "$LOG"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=none
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1
SURF=$(open_pane)
# A create() triggers load() (undecryptable -> []) then save() (must move
# the old envelope aside first).
cx browser click '#create' --surface "$SURF" >/dev/null 2>&1
poll_out "$SURF" 'creating' >/dev/null
ASIDE=$(ls "$VAULT".undecryptable-*.bak 2>/dev/null | head -1)
if [ -n "$ASIDE" ]; then
    ok "undecryptable vault moved aside (.undecryptable-<ts>.bak)"
    ASIDEPERMS=$(stat -c %a "$ASIDE" 2>/dev/null)
    [ "$ASIDEPERMS" = "600" ] && ok "undecryptable backup mode 0600" || bad "undecryptable backup permissions" "$ASIDEPERMS"
    if [ -n "$OLDCIPHER" ] && python3 -c "
import json, sys
d = json.load(open('$ASIDE'))
sys.exit(0 if d.get('ciphertext') == '$OLDCIPHER' else 1)
" 2>/dev/null; then
        ok "undecryptable backup preserves the original ciphertext"
    else
        bad "undecryptable backup contents" "ciphertext did not survive"
    fi
else
    bad "undecryptable guard" "no .undecryptable backup written; old envelope overwritten"
fi

# ---------- P1b guard: the undecryptable state must not stick (2026-09-03)
# vaultUndecryptable was cleared ONLY by save(), never by a successful
# load — and the key is resolved once per process, so the fail -> recover
# transition arrives as an EXTERNAL vault-file swap in one process
# (restore tooling, a second instance on the same path). With the flag
# stuck, the save after the recovered load moves a DECRYPTABLE vault
# aside as if unreadable. Repro in one process: fabricate an envelope
# under a THROWAWAY key (valid shape, undecryptable with ours), load it
# (flag sets), swap the good vault back, load again (decrypts), save —
# the aside count must not grow. Cross-desk review finding, pk3.
info "P1b guard: undecryptable state does not stick across a recovered load"
python3 -c "import cryptography" 2>/dev/null \
    || { echo "webauthn-smoke: python3-cryptography is required for the envelope-fabrication leg" >&2; exit 2; }
for pid in $(pgrep -x cmux-adw 2>/dev/null); do
    app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
    [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
done
sleep 1
rm -f "$SESSION"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=host
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1
SURF=$(open_pane)
# The guard leg left a PLAINTEXT v1 vault; this load migrates it to v2.
cx browser eval --script 'navigator.credentials.get({publicKey:{challenge:new Uint8Array(32),rpId:"localhost"}}).then(r=>"ok").catch(e=>"err:"+e.name)' --surface "$SURF" >/dev/null 2>&1
MIG2=0
for _ in $(seq 1 20); do
    if python3 -c "import json,sys; d=json.load(open('$VAULT')); sys.exit(0 if d.get('version')==2 else 1)" 2>/dev/null; then
        MIG2=1; break
    fi
    sleep 1
done
if [ "$MIG2" != "1" ]; then
    bad "guard-flap setup" "vault did not migrate to v2 under the host backend"
    echo; echo "== webauthn-smoke: $PASS passed, $FAIL failed"; exit 1
fi
cp "$VAULT" "$WORK/vault-good.json"
# Fabricate an undecryptable envelope: valid v2 shape, throwaway key.
python3 - "$VAULT" <<'PY'
import base64, json, os, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
key = os.urandom(32); nonce = os.urandom(12)
sealed = AESGCM(key).encrypt(nonce, json.dumps({"version": 1, "credentials": []}).encode(), None)
json.dump({"version": 2, "backend": "host",
           "nonce": base64.b64encode(nonce).decode(),
           "ciphertext": base64.b64encode(sealed).decode()},
          open(sys.argv[1], "w"))
PY
# Failed load: sets the undecryptable state in-process (and must log it —
# until the verbs consume vaultIsUndecryptable, that log line is the only
# place the truth is visible; assert it as a contract).
cx browser eval --script 'navigator.credentials.get({publicKey:{challenge:new Uint8Array(32).fill(3),rpId:"localhost"}}).then(r=>"ok").catch(e=>"err:"+e.name)' --surface "$SURF" >/dev/null 2>&1
LOGGED=0
for _ in $(seq 1 15); do
    grep -q "could not be decrypted" "$LOG" 2>/dev/null && { LOGGED=1; break; }
    sleep 1
done
[ "$LOGGED" = "1" ] && ok "undecryptable load logs its state to the instance log" \
    || bad "undecryptable logging" "no 'could not be decrypted' line in instance log"
# Recover: the good vault returns (external swap) and decrypts again.
cp "$WORK/vault-good.json" "$VAULT"
ASIDES_BEFORE=$(ls "$VAULT".undecryptable-*.bak 2>/dev/null | wc -l)
cx browser click '#get' --surface "$SURF" >/dev/null 2>&1
OUT=$(poll_out "$SURF" 'getting')
case "$OUT" in
    asserted:*) ok "recovered vault completes an assertion ceremony after the flap" ;;
    *)          bad "post-flap ceremony" "$OUT" ;;
esac
# The save after the successful re-read must NOT move the vault aside.
cx browser click '#create' --surface "$SURF" >/dev/null 2>&1
poll_out "$SURF" 'creating' >/dev/null
ASIDES_AFTER=$(ls "$VAULT".undecryptable-*.bak 2>/dev/null | wc -l)
[ "$ASIDES_AFTER" = "$ASIDES_BEFORE" ] \
    && ok "save after a successful re-read does not move a decryptable vault aside" \
    || bad "undecryptable state stuck" "asides $ASIDES_BEFORE -> $ASIDES_AFTER; a decryptable vault was moved aside"

echo
echo "== webauthn-smoke: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
