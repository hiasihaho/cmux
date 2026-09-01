import Crypto
import Foundation
import Glibc

// Software platform authenticator for the Linux port's WebAuthn client
// layer (docs/linux-port/PASSKEYS.md option C). WebKitGTK ships no
// WebAuthn (P0 probe, PROGRESS 2026-09-01), so the port supplies both
// halves: BrowserWebAuthn.swift is the client (origin truth, consent,
// bridge), this file is the authenticator (key custody, signing).
//
// Scope and honesty of v1:
//  - ES256 (P-256) only — the one algorithm WebAuthn requires; RPs that
//    offer only RS256 get NotSupportedError.
//  - Attestation is always "none", like every password-manager passkey
//    (Proton Pass, Bitwarden, iCloud Keychain in cross-platform mode).
//    We never fabricate hardware attestation.
//  - signCount stays 0 forever, matching Apple's platform authenticator;
//    a moving counter turns vault restores into RP clone-detection
//    lockouts.
//  - Vault: JSON file, 0600, atomic replace. Encryption-at-rest via
//    Secret Service is the next increment (PASSKEYS.md P1b) — the store
//    is isolated behind `WebAuthnVault` so only `load`/`save` change.

/// One resident credential. Codable == vault schema (version 1).
struct WebAuthnCredential: Codable {
    var id: Data              // credential id (32 random bytes)
    var rpId: String
    var userHandle: Data
    var userName: String
    var userDisplayName: String
    var privateKey: Data      // P-256 raw representation
    var createdAtMs: Int64
}

/// Ceremony failures mapped to WebAuthn DOMException names — the page
/// bridge rethrows them under these names, which RP javascript matches.
struct WebAuthnCeremonyError: Error {
    let name: String
    let message: String
    static func notAllowed(_ m: String) -> Self { .init(name: "NotAllowedError", message: m) }
    static func notSupported(_ m: String) -> Self { .init(name: "NotSupportedError", message: m) }
    static func invalidState(_ m: String) -> Self { .init(name: "InvalidStateError", message: m) }
    static func security(_ m: String) -> Self { .init(name: "SecurityError", message: m) }
    static func type(_ m: String) -> Self { .init(name: "TypeError", message: m) }
}

// MARK: - vault

/// Resident-credential store. Single file, versioned, 0600, written via
/// temp-file + rename so a crash never truncates the vault.
enum WebAuthnVault {
    private struct File: Codable {
        var version: Int
        var credentials: [WebAuthnCredential]
    }

    static var fileURL: URL {
        if let override = ProcessInfo.processInfo.environment["CMUX_WEBAUTHN_VAULT"],
           !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return SessionStore.fileURL
            .deletingLastPathComponent()
            .appendingPathComponent("webauthn-credentials.json")
    }

    static func load() -> [WebAuthnCredential] {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 1 else { return [] }
        return file.credentials
    }

    static func save(_ credentials: [WebAuthnCredential]) throws {
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(File(version: 1, credentials: credentials))
        let tmp = dir.appendingPathComponent(".webauthn-credentials.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        // rename(2): atomic, and unlike Foundation's replace/move it
        // neither requires nor rejects an existing destination.
        guard rename(tmp.path, fileURL.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw WebAuthnCeremonyError.notAllowed("The credential store is not writable.")
        }
    }
}

// MARK: - CBOR (encode-only, canonical, exactly what WebAuthn needs)

private enum CBOR {
    static func uint(_ v: UInt64) -> Data {
        head(major: 0, value: v)
    }
    /// Negative integer n (n < 0): encoded from -1 - n.
    static func negint(_ n: Int64) -> Data {
        head(major: 1, value: UInt64(-1 - n))
    }
    static func bytes(_ d: Data) -> Data {
        head(major: 2, value: UInt64(d.count)) + d
    }
    static func text(_ s: String) -> Data {
        let utf8 = Data(s.utf8)
        return head(major: 3, value: UInt64(utf8.count)) + utf8
    }
    /// Map from pre-encoded (key, value) pairs — caller supplies pairs in
    /// canonical order (RFC 8949 core deterministic: bytewise on the
    /// encoded key). Kept explicit so ordering is visible at call sites.
    static func map(_ pairs: [(Data, Data)]) -> Data {
        pairs.reduce(head(major: 5, value: UInt64(pairs.count))) { $0 + $1.0 + $1.1 }
    }
    private static func head(major: UInt8, value: UInt64) -> Data {
        let m = major << 5
        switch value {
        case 0..<24: return Data([m | UInt8(value)])
        case 24...0xFF: return Data([m | 24, UInt8(value)])
        case 0x100...0xFFFF:
            return Data([m | 25, UInt8(value >> 8), UInt8(value & 0xFF)])
        default:
            // WebAuthn structures never exceed 16-bit lengths here.
            var d = Data([m | 26])
            for shift in stride(from: 24, through: 0, by: -8) {
                d.append(UInt8((value >> UInt64(shift)) & 0xFF))
            }
            return d
        }
    }
}

// MARK: - request models (parsed from the bridge's serialized JSON)

struct WebAuthnCreateRequest {
    var challenge: Data
    var rpId: String?
    var rpName: String?
    var userId: Data
    var userName: String
    var userDisplayName: String
    var algorithms: [Int]
    var excludeCredentialIds: [Data]
}

struct WebAuthnGetRequest {
    var challenge: Data
    var rpId: String?
    var allowCredentialIds: [Data]
}

// MARK: - authenticator

enum WebAuthnSoftwareAuthenticator {
    /// Zero AAGUID: an anonymized software authenticator, consistent with
    /// attestation "none".
    private static let aaguid = Data(count: 16)

    /// UP | UV | AT — user presence and verification are asserted only
    /// after BrowserWebAuthn's consent gate actually obtained them.
    private static let createFlags: UInt8 = 0x45
    private static let getFlags: UInt8 = 0x05

    struct CreatedCredential {
        var credentialId: Data
        var attestationObject: Data
        var authenticatorData: Data
        var publicKeyDER: Data
    }

    struct Assertion {
        var credentialId: Data
        var authenticatorData: Data
        var signature: Data
        var userHandle: Data
    }

    /// Registration ceremony. `rpId` is the CLIENT-validated relying
    /// party id — this layer trusts it (BrowserWebAuthn owns origin
    /// truth and must never pass a page-controlled value unvalidated).
    static func create(rpId: String, request: WebAuthnCreateRequest) throws -> CreatedCredential {
        guard request.algorithms.contains(-7) else {
            throw WebAuthnCeremonyError.notSupported(
                "This authenticator supports only ES256 (alg -7).")
        }
        var vault = WebAuthnVault.load()
        let existingForRp = vault.filter { $0.rpId == rpId }
        for excluded in request.excludeCredentialIds
        where existingForRp.contains(where: { $0.id == excluded }) {
            throw WebAuthnCeremonyError.invalidState(
                "A passkey for this account already exists on this device.")
        }

        let key = P256.Signing.PrivateKey()
        // 32 random bytes via the crypto library's own CSPRNG.
        let credentialId = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }

        let cose = coseKey(for: key.publicKey)
        var authData = Data(SHA256.hash(data: Data(rpId.utf8)))
        authData.append(createFlags)
        authData.append(contentsOf: [0, 0, 0, 0])
        authData.append(aaguid)
        authData.append(contentsOf: [UInt8(credentialId.count >> 8), UInt8(credentialId.count & 0xFF)])
        authData.append(credentialId)
        authData.append(cose)

        let attestationObject = CBOR.map([
            (CBOR.text("fmt"), CBOR.text("none")),
            (CBOR.text("attStmt"), CBOR.map([])),
            (CBOR.text("authData"), CBOR.bytes(authData)),
        ])

        // One resident credential per (rpId, userHandle): a re-register
        // replaces, the way real platform authenticators behave.
        vault.removeAll { $0.rpId == rpId && $0.userHandle == request.userId }
        vault.append(WebAuthnCredential(
            id: credentialId,
            rpId: rpId,
            userHandle: request.userId,
            userName: request.userName,
            userDisplayName: request.userDisplayName,
            privateKey: key.rawRepresentation,
            createdAtMs: Int64(Date().timeIntervalSince1970 * 1000)
        ))
        try WebAuthnVault.save(vault)

        return CreatedCredential(
            credentialId: credentialId,
            attestationObject: attestationObject,
            authenticatorData: authData,
            publicKeyDER: key.publicKey.derRepresentation
        )
    }

    /// Assertion ceremony. Picks the newest matching resident credential;
    /// an account picker for multi-credential RPs is a later increment.
    static func assert(rpId: String, request: WebAuthnGetRequest,
                       clientDataJSON: Data) throws -> Assertion {
        let vault = WebAuthnVault.load()
        var candidates = vault.filter { $0.rpId == rpId }
        if !request.allowCredentialIds.isEmpty {
            candidates = candidates.filter { cred in
                request.allowCredentialIds.contains(cred.id)
            }
        }
        guard let credential = candidates.max(by: { $0.createdAtMs < $1.createdAtMs }) else {
            throw WebAuthnCeremonyError.notAllowed(
                "No passkey for \(rpId) is available on this device.")
        }
        let key = try P256.Signing.PrivateKey(rawRepresentation: credential.privateKey)

        var authData = Data(SHA256.hash(data: Data(rpId.utf8)))
        authData.append(getFlags)
        authData.append(contentsOf: [0, 0, 0, 0])

        let toSign = authData + Data(SHA256.hash(data: clientDataJSON))
        let signature = try key.signature(for: toSign)

        return Assertion(
            credentialId: credential.id,
            authenticatorData: authData,
            signature: signature.derRepresentation,
            userHandle: credential.userHandle
        )
    }

    /// COSE_Key (EC2, ES256): {1:2, 3:-7, -1:1, -2:x, -3:y} — pairs are
    /// listed in canonical (bytewise encoded-key) order.
    private static func coseKey(for publicKey: P256.Signing.PublicKey) -> Data {
        let x963 = publicKey.x963Representation   // 0x04 || x(32) || y(32)
        let x = x963.subdata(in: 1..<33)
        let y = x963.subdata(in: 33..<65)
        return CBOR.map([
            (CBOR.uint(1), CBOR.uint(2)),
            (CBOR.uint(3), CBOR.negint(-7)),
            (CBOR.negint(-1), CBOR.uint(1)),
            (CBOR.negint(-2), CBOR.bytes(x)),
            (CBOR.negint(-3), CBOR.bytes(y)),
        ])
    }
}
