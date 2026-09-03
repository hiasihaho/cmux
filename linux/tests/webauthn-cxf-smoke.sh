#!/usr/bin/env bash
# Suite for CXF-core slice 1: the FIDO Credential Exchange Format layer
# (docs/linux-port/PASSKEYS.md §0 "CXF-core brief"). Implements FIDO CXF
# v1.0 Proposed Standard 2025-08-14 with errata 2026-03-09
# (cxf-v1.0-ps-errata-20260309).
#
#   linux/tests/webauthn-cxf-smoke.sh [--keep]
#
# Unlike every sibling suite this one starts NO cmux instance: slice 1 is
# a pure format layer with no runtime surface (verbs are the passkey
# desk's lane), so the suite compiles WebAuthnCXF.swift standalone with
# swiftc and runs a driver against it. No APP_ID, no port, no X display —
# no suite-identity collision with webauthn-verbs-smoke (wavtest/8446).
#
# Coverage: header/version emission, wire field encoding (b64url,
# PKCS#8 key), full round-trip, and the rejection legs — malformed JSON,
# missing version, foreign major version, truncated key, wrong-curve key,
# padded+unpadded b64url (the strict-Foundation trap from P1b review
# finding 3, here as a first-class leg), unknown credential types skipped
# and unknown fields ignored (§3.1.1 extensibility).
SUITE_NAME="webauthn-cxf-smoke"
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"
CXF_SRC="$ROOT/Sources/CmuxAdw/WebAuthnCXF.swift"

command -v swiftc >/dev/null 2>&1 || { echo "$SUITE_NAME: swiftc not found"; exit 2; }
[ -f "$CXF_SRC" ] || { echo "$SUITE_NAME: $CXF_SRC missing"; exit 2; }

WORK=$(mktemp -d)
KEEP=false
[ "${1:-}" = "--keep" ] && KEEP=true
cleanup() { $KEEP || rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------- driver
# The fixture key material is hand-rolled PKCS#8 DER (fixed short-form
# lengths), precomputed offline — scalar bytes 01..20, the 31-byte
# truncation, and the secp384r1 wrong-curve variant (OID 1.3.132.0.34).
cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passCount = 0
var failCount = 0
func ok(_ m: String) { print("  PASS  \(m)"); passCount += 1 }
func bad(_ m: String, _ r: String) { print("  FAIL  \(m) — \(r)"); failCount += 1 }

// The driver's OWN b64url decode — structural assertions must not reuse
// the codec under test.
func b64urlDecode(_ s: String) -> Data? {
    var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while t.count % 4 != 0 { t += "=" }
    return Data(base64Encoded: t)
}
func b64urlEncode(_ d: Data) -> String {
    Data(d).base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .trimmingCharacters(in: CharacterSet(charactersIn: "="))
}

let scalar = Data(1...32)
let credId = Data(repeating: 0xAA, count: 24)
let userHandle = Data(repeating: 0x07, count: 16)
let itemId = Data(0x10...0x23)
let accountId = Data(repeating: 0x55, count: 16)

let passkey = CXFPasskey(credentialId: credId, rpId: "localhost",
                         username: "probe@example.com", userDisplayName: "Probe",
                         userHandle: userHandle, key: scalar)
let item = CXFItem(id: itemId, creationAt: 1756900000, modifiedAt: 1756990000,
                   title: "localhost passkey", subtitle: nil,
                   credentials: [passkey], skippedCredentialCount: 0)
let account = CXFAccount(id: accountId, username: "probe",
                         email: "probe@example.com", fullName: "Probe User",
                         items: [item])
let doc = CXFDocument(version: CXFCodec.formatVersion, exporterRpId: "cmux.local",
                      exporterDisplayName: "cmux", timestamp: 1757000000,
                      accounts: [account])

// Canonical fixture JSON; parameters carry their own commas when non-empty.
let validKey = "MEECAQAwEwYHKoZIzj0CAQYIKoZIzj0DAQcEJzAlAgEBBCABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIA"
func fixtureDoc(key: String = "MEECAQAwEwYHKoZIzj0CAQYIKoZIzj0DAQcEJzAlAgEBBCABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIA",
                userHandle uh: String = "BwcHBwcHBwcHBwcHBwcHBw",
                version: String = #"{"major":1,"minor":0}"#,
                extraCredentials: String = "",
                topExtras: String = "",
                itemExtras: String = "") -> String {
    #"{"version":"# + version + #","exporterRpId":"cmux.local","exporterDisplayName":"cmux","timestamp":1757000000,"# +
    topExtras +
    #""accounts":[{"id":"VVVVVVVVVVVVVVVVVVVVVQ","username":"probe","email":"probe@example.com","fullName":"Probe User","collections":[],"items":[{"id":"EBESExQVFhcYGRobHB0eHyAhIiM","creationAt":1756900000,"modifiedAt":1756990000,"title":"localhost passkey","# +
    itemExtras +
    #""credentials":[""# + extraCredentials +
    #"{"type":"passkey","credentialId":"qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq","rpId":"localhost","username":"probe@example.com","userDisplayName":"Probe","userHandle":""# + uh +
    #"","key":""# + key + #""}]}]}]}"#
}

// ---------------------------------------------------------- encode legs
do {
    let wire = try CXFCodec.encode(doc)
    guard let root = try JSONSerialization.jsonObject(with: wire) as? [String: Any] else {
        throw CXFError.malformedDocument("encoded output is not a JSON object")
    }
    if let v = root["version"] as? [String: Any],
       v["major"] as? Int == 1, v["minor"] as? Int == 0 {
        ok("encode emits version {major:1, minor:0} (§3.1.1)")
    } else {
        bad("encode version", "got \(root["version"] ?? "missing")")
    }
    if root["exporterRpId"] as? String == "cmux.local",
       root["exporterDisplayName"] as? String == "cmux",
       root["timestamp"] as? Int == 1757000000,
       (root["accounts"] as? [[String: Any]])?.count == 1 {
        ok("encode emits header fields + one account (§3.1)")
    } else {
        bad("encode header", "exporterRpId=\(root["exporterRpId"] ?? "missing") timestamp=\(root["timestamp"] ?? "missing")")
    }
    let cred = (((root["accounts"] as? [[String: Any]])?.first?["items"] as? [[String: Any]])?.first?["credentials"] as? [[String: Any]])?.first
    if let cred,
       cred["type"] as? String == "passkey",
       cred["credentialId"] as? String == b64urlEncode(credId),
       cred["userHandle"] as? String == b64urlEncode(userHandle),
       cred["rpId"] as? String == "localhost",
       cred["username"] as? String == "probe@example.com",
       cred["userDisplayName"] as? String == "Probe" {
        ok("passkey fields on the wire are b64url/tstr per §3.3.12")
    } else {
        bad("passkey wire fields", "credential=\(cred ?? [:])")
    }
    if let keyString = cred?["key"] as? String,
       let der = b64urlDecode(keyString),
       der.range(of: Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])) != nil,       // ecPublicKey OID
       der.range(of: Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])) != nil, // prime256v1 OID
       der.range(of: scalar) != nil {
        ok("key on the wire is PKCS#8 DER carrying the P-256 OIDs + scalar (§3.3.12)")
    } else {
        bad("key wire encoding", "not the expected PKCS#8/P-256 DER")
    }
} catch {
    bad("encode legs (1-4)", "encode threw \(error)")
    bad("encode legs (1-4)", "encode threw \(error)")
    bad("encode legs (1-4)", "encode threw \(error)")
    bad("encode legs (1-4)", "encode threw \(error)")
}

// ----------------------------------------------------------- round trip
do {
    let back = try CXFCodec.decode(try CXFCodec.encode(doc))
    if back == doc {
        ok("round trip: decode(encode(doc)) is field-equal to doc")
    } else {
        bad("round trip", "decoded document differs: \(back)")
    }
} catch {
    bad("round trip", "threw \(error)")
}

// -------------------------------------------------------- rejection legs
func expectError(_ leg: String, _ json: String, _ matches: (CXFError) -> Bool) {
    do {
        _ = try CXFCodec.decode(Data(json.utf8))
        bad(leg, "decoded without error")
    } catch let e as CXFError {
        if matches(e) { ok(leg) } else { bad(leg, "wrong error: \(e)") }
    } catch {
        bad(leg, "non-CXF error: \(error)")
    }
}

expectError("malformed (truncated) JSON is rejected as malformedDocument",
            String(fixtureDoc().prefix(120)))
{ if case .malformedDocument = $0 { return true }; return false }

expectError("a document with no version member is rejected",
            #"{"exporterRpId":"cmux.local","exporterDisplayName":"cmux","timestamp":1,"accounts":[]}"#)
{ if case .malformedDocument = $0 { return true }; return false }

expectError("a foreign major version (2) is rejected, not ignored (§3.1.1)",
            fixtureDoc(version: #"{"major":2,"minor":0}"#))
{ if case .unsupportedMajorVersion(2) = $0 { return true }; return false }

expectError("a truncated (31-byte) scalar in the PKCS#8 key is rejected",
            fixtureDoc(key: "MEACAQAwEwYHKoZIzj0CAQYIKoZIzj0DAQcEJjAkAgEBBB8BAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4f"))
{ if case .invalidKeyEncoding = $0 { return true }; return false }

expectError("a secp384r1 (wrong-curve) key is rejected",
            fixtureDoc(key: "MD4CAQAwEAYHKoZIzj0CAQYFK4EEACIEJzAlAgEBBCABAgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fIA"))
{ if case .invalidKeyEncoding = $0 { return true }; return false }

// ------------------------------------------------ b64url + extensibility
do {
    let padded = try CXFCodec.decode(Data(fixtureDoc(userHandle: "BwcHBwcHBwcHBwcHBwcHBw==").utf8))
    let unpadded = try CXFCodec.decode(Data(fixtureDoc(userHandle: "BwcHBwcHBwcHBwcHBwcHBw").utf8))
    let p = padded.accounts[0].items[0].credentials[0].userHandle
    let u = unpadded.accounts[0].items[0].credentials[0].userHandle
    if p == userHandle && u == userHandle {
        ok("b64url decodes padded AND unpadded (the P1b strict-Foundation trap, as a leg)")
    } else {
        bad("b64url padding tolerance", "padded=\(p as NSData) unpadded=\(u as NSData)")
    }
} catch {
    bad("b64url padding tolerance", "threw \(error)")
}

do {
    let foreign = #"{"type":"basic-auth","username":"u","password":"p"},"#
    let mixed = try CXFCodec.decode(Data(fixtureDoc(extraCredentials: foreign).utf8))
    let it = mixed.accounts[0].items[0]
    if it.credentials.count == 1 && it.credentials[0].rpId == "localhost"
        && it.skippedCredentialCount == 1 {
        ok("unknown credential type (basic-auth) is skipped and counted, passkey survives (§3.1.1)")
    } else {
        bad("unknown credential type", "credentials=\(it.credentials.count) skipped=\(it.skippedCredentialCount)")
    }
} catch {
    bad("unknown credential type", "threw \(error)")
}

do {
    let noisy = try CXFCodec.decode(Data(fixtureDoc(topExtras: #""unknownTop":true,"#,
                                                    itemExtras: #""unknownItem":{"x":1},"#).utf8))
    if noisy == doc {
        ok("unknown top-level/item fields are ignored, document decodes field-equal (§3.1.1)")
    } else {
        bad("unknown fields ignored", "decoded document differs")
    }
} catch {
    bad("unknown fields ignored", "threw \(error)")
}

print("DRIVER-RESULT \(passCount) \(failCount)")
exit(failCount == 0 ? 0 : 1)
SWIFT

# ------------------------------------------------------------------ run
echo "== compiling WebAuthnCXF.swift standalone (swiftc -swift-version 5)"
if ! swiftc -swift-version 5 -o "$WORK/cxf-driver" "$CXF_SRC" "$WORK/main.swift" 2> "$WORK/compile.log"; then
    echo "$SUITE_NAME: compile failed — the format file must build standalone AND inside the app" >&2
    sed 's/^/  CC  /' "$WORK/compile.log" >&2
    exit 2
fi

OUT=$("$WORK/cxf-driver" 2>&1); RC=$?
echo "$OUT" | grep -E '^  (PASS|FAIL)' || echo "$OUT"
PASS=$(echo "$OUT" | grep -c '^  PASS' || true)
FAIL=$(echo "$OUT" | grep -c '^  FAIL' || true)

echo
echo "== $SUITE_NAME: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$RC" -eq 0 ]
