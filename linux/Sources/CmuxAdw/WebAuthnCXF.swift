import Foundation

// CXF — FIDO Credential Exchange Format, v1.0 Proposed Standard
// (2025-08-14) with errata applied (2026-03-09):
// https://fidoalliance.org/specs/cx/cxf-v1.0-ps-errata-20260309.html
// (§ references below are to that revision.)
//
// Slice 1 is the FORMAT layer only: encode passkey entries to a CXF
// document, parse one back, round-trip tested. No vault wiring, no
// export verb, no UI, no CXP transfer. The security line for the slices
// that DO touch the vault is in docs/linux-port/PASSKEYS.md §0
// ("CXF-core brief"): export writes private keys out of the vault P1b
// encrypted, so no export path may ever be reachable from the page
// bridge, export is human-consented naming what leaves, nothing
// plaintext on disk by default, and no standing ceremony grant implies
// an export grant.
//
// Wire notes from the spec:
// - b64url (§2): an RFC 4648 URL-safe base64 JSON string. We emit
//   unpadded (the JOSE/WebAuthn convention across FIDO specs) and accept
//   padded on decode — a strict unpadded refusal already cost this
//   project hours once (PASSKEYS.md §0, review finding 3).
// - Extensibility (§3.1.1): unknown fields and unknown enumeration
//   values MUST be ignored gracefully; a major version other than 1 is
//   an incompatible change and is REJECTED, not ignored.
// - Passkey.key (§3.3.12): the private key as PKCS#8 ASN.1 DER, b64url.
//   Our vault holds the P-256 raw scalar (32 bytes); encode wraps it in
//   PKCS#8, decode unwraps and validates curve + length.
// - Signature counters (§3.3.12 note): our authenticator keeps signCount
//   0 forever, so the "exclude non-zero-counter passkeys from export"
//   rule never excludes ours; importers zero counters regardless.

enum CXFError: Error, Equatable {
    case malformedDocument(String)
    case unsupportedMajorVersion(Int)
    case invalidBase64(field: String)
    case invalidKeyEncoding(String)
    case unimplemented // RED stub — the green commit removes this case
}

// MARK: - Model (§3)

struct CXFVersion: Equatable {
    var major: Int
    var minor: Int
}

/// §3.3.12 Passkey dictionary. `key` is the P-256 raw private scalar
/// (32 bytes, vault-shaped); on the wire it is PKCS#8 DER, b64url.
/// `fido2Extensions` is omitted: the software authenticator stores no
/// extension state (§3.3.12.2 is OPTIONAL).
struct CXFPasskey: Equatable {
    static let credentialType = "passkey"
    var credentialId: Data
    var rpId: String
    var username: String
    var userDisplayName: String
    var userHandle: Data
    var key: Data
}

/// §3.2.3 Item. Slice 1 models only what a passkey export carries:
/// favorite/scope/tags/extensions are omitted on encode and ignored on
/// decode (§3.1.1 permits additive fields). Credentials whose type is
/// not "passkey" are skipped on decode and counted, never fatal.
struct CXFItem: Equatable {
    var id: Data
    var creationAt: UInt64?
    var modifiedAt: UInt64?
    var title: String
    var subtitle: String?
    var credentials: [CXFPasskey]
    var skippedCredentialCount: Int
}

/// §3.2.1 Account. `collections` encodes as [] (we have no grouping)
/// and is ignored on decode; `extensions` likewise.
struct CXFAccount: Equatable {
    var id: Data
    var username: String
    var email: String
    var fullName: String?
    var items: [CXFItem]
}

/// §3.1 Header (the document root IS the header).
struct CXFDocument: Equatable {
    var version: CXFVersion
    var exporterRpId: String
    var exporterDisplayName: String
    var timestamp: UInt64 // UNIX seconds (§3.1: uint .size 8)
    var accounts: [CXFAccount]
}

// MARK: - Codec

enum CXFCodec {
    /// §3.1.1: the current published format level.
    static let formatVersion = CXFVersion(major: 1, minor: 0)

    static func encode(_ document: CXFDocument) throws -> Data {
        throw CXFError.unimplemented
    }

    static func decode(_ data: Data) throws -> CXFDocument {
        throw CXFError.unimplemented
    }
}
