#!/usr/bin/env bash
# Gate suite for CXF slice 2a: the vault-seam EXPORT (docs/linux-port/
# PASSKEYS.md §0 "CXF-core brief", pk3 lane; green-lit in
# announce-cmux-desk 2026-09-03 with the scrypt correction folded in).
#
#   linux/tests/webauthn-cxf-export-smoke.sh [--keep]
#
# Covers: the consent gate (no consent -> no file), the encrypted-by-
# default envelope (scrypt params recorded IN the envelope; decrypted and
# field-checked by python carrying its OWN KDF+AEAD — never the code
# under test), --plaintext validated by CXFCodec itself (a swiftc driver
# over WebAuthnCXF.swift: the format layer validates the seam's output),
# 0600 + refuse-existing-path/--force, format named in CLI output and in
# the typed completion notification, typed refusals on undecryptable and
# empty vaults, and the grep-leg proving no export symbol is reachable
# from the page bridge. Dialog TEXT is reasoned, not headless-tested
# (said in PROGRESS).
#
# Suite identity: APP_ID wafxtest. NO fixture port, NO page — export is
# vault-level. Runs on an ISOLATED instance; the daily is never touched.
SUITE_NAME="webauthn-cxf-export-smoke"
APP_ID_SUFFIX="wafxtest"
source "$(dirname "$0")/lib.sh"

VAULT="/tmp/cmux-$APP_ID_SUFFIX-vault.json"
OUT_E="/tmp/cmux-$APP_ID_SUFFIX-export.enc.json"
OUT_P="/tmp/cmux-$APP_ID_SUFFIX-export.plain.json"
suite_cleanup() {
    rm -f "$VAULT" "$VAULT".v1.bak "$VAULT".undecryptable-*.bak "$OUT_E" "$OUT_P"
    return 0
}
require_tools python3
python3 -c "import cryptography" 2>/dev/null \
    || { echo "$SUITE_NAME: python3-cryptography required (envelope decryption legs)" >&2; exit 2; }

WORK=$(mktemp -d)
KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true
rm -f "$VAULT" "$VAULT".v1.bak "$OUT_E" "$OUT_P"

PASS=0; FAIL=0
ok()   { echo "  PASS  $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL  $1 — $2"; FAIL=$((FAIL+1)); }
info() { echo "== $1"; }

kill_suite_instances() {
    for pid in $(pgrep -x cmux-adw 2>/dev/null); do
        app=$(tr '\0' '\n' </proc/"$pid"/environ 2>/dev/null | sed -n 's/^CMUX_APP_ID=//p')
        [ "$app" = "$APP_ID" ] && kill "$pid" 2>/dev/null
    done
    sleep 1
}
kill_suite_instances

# Seeded v1 vault: two credentials, PADDED base64 (the P1b migration trap
# — Foundation's strict Data strategy refuses unpadded). privateKeys are
# valid P-256 scalars (non-zero, below the group order).
python3 - "$VAULT" <<'PY'
import base64, json, sys
b64 = lambda b: base64.b64encode(b).decode()
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

PASSPHRASE="suite-passphrase-2a"

# The CXFCodec acceptance driver for the --plaintext leg: compiles the
# format layer standalone (slice-1 pattern) and decodes argv[1],
# printing the total passkey count. The driver carries its own nothing —
# CXFCodec IS the thing being asked to accept the seam's output.
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
guard CommandLine.arguments.count > 1,
      let data = try? Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])) else {
    print("driver: cannot read input"); exit(2)
}
do {
    let doc = try CXFCodec.decode(data)
    let n = doc.accounts.flatMap(\.items).reduce(0) { $0 + $1.credentials.count }
    print("decoded \(n)")
} catch {
    print("driver: decode failed: \(error)")
    exit(1)
}
SWIFT
if ! swiftc -swift-version 5 -o "$WORK/cxf-decode" \
        "$ROOT/Sources/CmuxAdw/WebAuthnCXF.swift" "$WORK/main.swift" 2> "$WORK/compile.log"; then
    echo "$SUITE_NAME: format-layer driver compile failed" >&2
    sed 's/^/  CC  /' "$WORK/compile.log" >&2
    exit 2
fi

# ------------------------------------------------ phase A: consent gate
info "phase A: no consent -> no file (autoapprove UNSET)"
start_xvfb
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=host
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1

PENDING=$(printf '%s' "$PASSPHRASE" | cx --json browser webauthn export --out "$OUT_E" --passphrase-stdin 2>/dev/null)
PSTATUS=$(echo "$PENDING" | python3 -c "import json,sys; print(json.load(sys.stdin).get('status'))" 2>/dev/null)
PCOUNT=$(echo "$PENDING" | python3 -c "import json,sys; print(json.load(sys.stdin).get('credential_count'))" 2>/dev/null)
PFORMAT=$(echo "$PENDING" | python3 -c "import json,sys; print(json.load(sys.stdin).get('format'))" 2>/dev/null)
if [ "$PSTATUS" = "consent_pending" ] && [ "$PCOUNT" = "2" ] && [ "$PFORMAT" = "cmux-cxf-encrypted" ]; then
    ok "consent gate: verb answers consent_pending naming count + format"
    # The dialog now stands on the Xvfb display with nobody to click it.
    sleep 4
    [ ! -f "$OUT_E" ] \
        && ok "consent gate: no consent, no file" \
        || bad "consent gate" "file appeared WITHOUT consent"
else
    bad "consent gate: pending reply" "got '$PENDING'"
    bad "consent gate: no file" "no pending reply, so 'no file' proves nothing"
fi
kill_suite_instances

# -------------------------------------- phase B: consented export (hatch)
info "phase B: consented exports via CMUX_WEBAUTHN_EXPORT_AUTOAPPROVE"
rm -f "$SESSION"
INSTANCE_ENV=(
    CMUX_WEBAUTHN=1
    CMUX_WEBAUTHN_AUTOAPPROVE=1
    CMUX_WEBAUTHN_EXPORT_AUTOAPPROVE=1
    CMUX_WEBAUTHN_VAULT="$VAULT"
    CMUX_WEBAUTHN_KEY_BACKEND=host
    GHOSTTY_RESOURCES_DIR="$ROOT/ghostty/zig-out/share/ghostty"
)
start_instance || exit 2
sleep 1

printf '%s' "$PASSPHRASE" | cx browser webauthn export --out "$OUT_E" --passphrase-stdin >/dev/null 2>&1
for _ in $(seq 1 10); do [ -f "$OUT_E" ] && break; sleep 1; done
if [ -f "$OUT_E" ]; then
    PERMS=$(stat -c %a "$OUT_E")
    [ "$PERMS" = "600" ] && ok "export file written, mode 0600" || bad "export permissions" "$PERMS"
else
    bad "encrypted export" "no file at $OUT_E"
fi

if [ -f "$OUT_E" ]; then
    python3 - "$OUT_E" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
kdf = d.get("kdf", {})
ok = (d.get("version") == 1 and d.get("format") == "cmux-cxf-encrypted"
      and kdf.get("name") == "scrypt"
      and all(isinstance(kdf.get(k), int) for k in ("n", "r", "p"))
      and isinstance(kdf.get("salt"), str)
      and isinstance(d.get("nonce"), str) and isinstance(d.get("ciphertext"), str))
sys.exit(0 if ok else 1)
PY
    [ $? -eq 0 ] && ok "envelope: cmux-cxf-encrypted v1, scrypt params recorded in the file" \
        || bad "envelope shape" "$(head -c 200 "$OUT_E")"
    grep -q "example.com\|webauthn.io" "$OUT_E" 2>/dev/null \
        && bad "envelope secrecy" "rpId readable in the encrypted export" \
        || ok "envelope: no readable rpId in the encrypted export"
else
    bad "envelope shape" "no file to inspect"
    bad "envelope secrecy" "no file to inspect"
fi

# python carries its OWN scrypt + AES-GCM (hashlib/cryptography) — the
# decryption check never runs the code under test.
python3 - "$OUT_E" "$PASSPHRASE" > "$WORK/decrypt.out" 2>&1 <<'PY'
import base64, hashlib, json, sys
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

env = json.load(open(sys.argv[1]))
pw = sys.argv[2].encode()
kdf = env["kdf"]

def derive(p):
    return hashlib.scrypt(p, salt=base64.b64decode(kdf["salt"]),
                          n=kdf["n"], r=kdf["r"], p=kdf["p"], dklen=32,
                          maxmem=1024 * 1024 * 1024)

def open_box(key):
    nonce = base64.b64decode(env["nonce"])
    return AESGCM(key).decrypt(nonce, base64.b64decode(env["ciphertext"]), None)

try:
    open_box(derive(b"wrong-passphrase"))
    print("WRONGPASS-DECRYPTED")
    sys.exit(1)
except Exception:
    print("wrong-passphrase refused")

doc = json.loads(open_box(derive(pw)))
creds = [c for a in doc["accounts"] for i in a["items"] for c in i["credentials"]]
assert len(creds) == 2, f"expected 2 credentials, got {len(creds)}"
by_rp = {c["rpId"]: c for c in creds}
assert set(by_rp) == {"example.com", "webauthn.io"}, by_rp.keys()

def b64url(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))

def scalar_of(der):
    # Minimal TLV walk: PrivateKeyInfo > OCTET STRING > SEQUENCE >
    # OCTET STRING (the scalar). Independent of the Swift reader.
    def tlv(d, pos):
        tag, ln = d[pos], d[pos + 1]; pos += 2
        if ln & 0x80:
            n = ln & 0x7F
            ln = int.from_bytes(d[pos:pos + n], "big"); pos += n
        return tag, d[pos:pos + ln], pos + ln
    tag, info, _ = tlv(der, 0)
    assert tag == 0x30
    pos = 0
    tag, _, pos = tlv(info, pos)          # version INTEGER
    tag, _, pos = tlv(info, pos)          # algorithm SEQUENCE
    tag, priv, pos = tlv(info, pos)       # privateKey OCTET STRING
    assert tag == 0x04
    tag, ec, _ = tlv(priv, 0)
    assert tag == 0x30
    tag, _, pos = tlv(ec, 0)              # version INTEGER
    tag, scalar, pos = tlv(ec, 0)         # scalar OCTET STRING
    assert tag == 0x04
    return scalar

one = by_rp["example.com"]
assert b64url(one["credentialId"]) == bytes(range(32)), "credentialId"
assert b64url(one["userHandle"]) == b"\x07" * 16, "userHandle"
assert scalar_of(b64url(one["key"])) == b"\x11" * 32, "scalar"
two = by_rp["webauthn.io"]
assert scalar_of(b64url(two["key"])) == b"\x22" * 32, "scalar 2"
print("payload field-checks pass")
PY
case $? in
    0)
        grep -q "wrong-passphrase refused" "$WORK/decrypt.out" \
            && ok "envelope: wrong passphrase does NOT decrypt" \
            || bad "wrong passphrase" "$(cat "$WORK/decrypt.out")"
        grep -q "payload field-checks pass" "$WORK/decrypt.out" \
            && ok "envelope decrypts to CXF with the exact credentials (ids, handles, scalars)" \
            || bad "envelope payload" "$(cat "$WORK/decrypt.out")"
        ;;
    *)  bad "envelope decryption" "$(cat "$WORK/decrypt.out")"
        bad "envelope payload" "decryption failed" ;;
esac

# Typed completion in the notification store (exported, naming format).
NOTIF=""
for _ in $(seq 1 10); do
    NOTIF=$(cx --json list-notifications 2>/dev/null | python3 -c "
import json, sys
try: items = json.load(sys.stdin)
except Exception: items = []
if isinstance(items, dict): items = items.get('notifications', [])
for n in items:
    text = json.dumps(n)
    if 'passkey' in text.lower() and 'export' in text.lower():
        print(text); break" 2>/dev/null)
    [ -n "$NOTIF" ] && break
    sleep 1
done
if echo "$NOTIF" | grep -qi "exported" && echo "$NOTIF" | grep -q "cmux-cxf-encrypted\|cmux-encrypted"; then
    ok "typed completion: 'exported' notification names the format"
else
    bad "completion notification" "got '$NOTIF'"
fi

# File hygiene: refuse an existing path, --force overrides.
AGAIN=$(printf '%s' "$PASSPHRASE" | cx --json browser webauthn export --out "$OUT_E" --passphrase-stdin 2>&1)
if echo "$AGAIN" | grep -qi "exist\|force"; then
    ok "refuse-existing-path without --force"
else
    bad "existing path" "expected a refusal, got '$AGAIN'"
fi
rm -f "$OUT_E"; printf '%s' "$PASSPHRASE" | cx browser webauthn export --out "$OUT_E" --passphrase-stdin >/dev/null 2>&1
sleep 2
FORCE=$(printf '%s' "$PASSPHRASE" | cx --json browser webauthn export --out "$OUT_E" --force --passphrase-stdin 2>/dev/null)
echo "$FORCE" | python3 -c "import json,sys; d=json.load(sys.stdin); sys.exit(0 if d.get('status')=='consent_pending' else 1)" 2>/dev/null \
    && ok "--force re-exports over an existing path" \
    || bad "--force export" "got '$FORCE'"

# --plaintext: the format layer itself validates the seam's output.
printf '%s' "$PASSPHRASE" | cx browser webauthn export --out "$OUT_P" --plaintext --passphrase-stdin >/dev/null 2>&1
for _ in $(seq 1 10); do [ -f "$OUT_P" ] && break; sleep 1; done
if [ -f "$OUT_P" ]; then
    DECODED=$("$WORK/cxf-decode" "$OUT_P" 2>&1)
    [ "$DECODED" = "decoded 2" ] \
        && ok "--plaintext export decodes through CXFCodec (format layer validates the seam)" \
        || bad "plaintext CXF decode" "$DECODED"
else
    bad "--plaintext export" "no file at $OUT_P"
fi

# CLI output names the format (sharpening 3).
HUMAN=$(printf '%s' "$PASSPHRASE" | cx browser webauthn export --out /tmp/cmux-$APP_ID_SUFFIX-export2.enc.json --force --passphrase-stdin 2>&1)
echo "$HUMAN" | grep -q "cmux-encrypted CXF" \
    && ok "CLI output names 'cmux-encrypted CXF (only cmux can read this)'" \
    || bad "CLI format naming" "got '$HUMAN'"

# ----------------------------- phase C: typed refusals + bridge hygiene
info "phase C: undecryptable + empty vaults refuse with typed errors"
kill_suite_instances
rm -f "$SESSION"
# Fabricate an undecryptable envelope (valid v2 shape, throwaway key —
# the webauthn-smoke guard pattern).
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
start_instance || exit 2
sleep 1
UND=$(printf '%s' "$PASSPHRASE" | cx --json browser webauthn export --out /tmp/cmux-$APP_ID_SUFFIX-never.json --force --passphrase-stdin 2>&1)
# One leg, two conditions — split, the "no file" half would pass
# vacuously whenever the verb is missing entirely (the red state).
if echo "$UND" | grep -qi "unavailable\|undecryptable" && [ ! -f /tmp/cmux-$APP_ID_SUFFIX-never.json ]; then
    ok "undecryptable vault: typed refusal AND no file written"
else
    bad "undecryptable export" "reply '$UND', file exists: $([ -f /tmp/cmux-$APP_ID_SUFFIX-never.json ] && echo yes || echo no)"
fi

kill_suite_instances
rm -f "$SESSION" "$VAULT"
start_instance || exit 2
sleep 1
EMPTY=$(printf '%s' "$PASSPHRASE" | cx --json browser webauthn export --out /tmp/cmux-$APP_ID_SUFFIX-never2.json --passphrase-stdin 2>&1)
echo "$EMPTY" | grep -qi "no credentials\|empty\|invalid_state" \
    && ok "empty vault: typed refusal" \
    || bad "empty-vault export" "got '$EMPTY'"

# The page-bridge rule, at the file level: no export symbol may be
# referenced from the bridge. (Guard leg — passes red and green.)
if grep -q "CXFExport\|CXFCodec" "$ROOT/Sources/CmuxAdw/BrowserWebAuthn.swift"; then
    bad "page-bridge hygiene" "BrowserWebAuthn.swift references the export path"
else
    ok "no export symbol reachable from BrowserWebAuthn.swift (grep-leg)"
fi

echo
echo "== $SUITE_NAME: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
