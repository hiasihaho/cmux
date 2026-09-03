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
}

// MARK: - b64url (§2)

/// Strict base64url. Decode accepts padded and unpadded input in either
/// the URL-safe or the standard alphabet (imported documents come from
/// providers we do not control) but rejects anything else — whitespace,
/// embedded '=', impossible lengths — rather than letting Foundation
/// silently drop characters. Encode emits unpadded URL-safe.
enum CXFBase64 {
    static func encode(_ data: Data) -> String {
        var s = data.base64EncodedString()
        s = s.replacingOccurrences(of: "+", with: "-")
        s = s.replacingOccurrences(of: "/", with: "_")
        while s.hasSuffix("=") { s.removeLast() }
        return s
    }

    static func decode(_ string: String, field: String) throws -> Data {
        var body = string
        var padding = 0
        while body.hasSuffix("=") { body.removeLast(); padding += 1 }
        guard padding <= 2 else { throw CXFError.invalidBase64(field: field) }
        var mapped = [UInt8]()
        mapped.reserveCapacity(body.utf8.count)
        for byte in body.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"):
                mapped.append(byte)
            case UInt8(ascii: "-"), UInt8(ascii: "+"):
                mapped.append(UInt8(ascii: "+"))
            case UInt8(ascii: "_"), UInt8(ascii: "/"):
                mapped.append(UInt8(ascii: "/"))
            default:
                throw CXFError.invalidBase64(field: field)
            }
        }
        var standard = String(decoding: mapped, as: UTF8.self)
        switch standard.count % 4 {
        case 0: break
        case 2: standard += "=="
        case 3: standard += "="
        default: throw CXFError.invalidBase64(field: field) // %4 == 1 cannot be real base64
        }
        guard let data = Data(base64Encoded: standard) else {
            throw CXFError.invalidBase64(field: field)
        }
        return data
    }
}

// MARK: - PKCS#8 (§3.3.12 key member)

/// Wrap/unwrap a P-256 private scalar in the PKCS#8 ASN.1 DER the spec
/// requires for Passkey.key. Strict: short-form lengths only (every
/// structure here is far under 128 bytes), exact OIDs, exact scalar
/// length, no trailing bytes at any level. A scalar must be non-zero and
/// below the P-256 group order to be a key at all.
enum CXFPKCS8 {
    private static let ecPublicKeyOID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01])
    private static let prime256v1OID = Data([0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07])
    private static let p256Order = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x00,
                                         0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
                                         0xBC, 0xE6, 0xFA, 0xAD, 0xA7, 0x17, 0x9E, 0x84,
                                         0xF3, 0xB9, 0xCA, 0xC2, 0xFC, 0x63, 0x25, 0x51])

    private struct Reader {
        let data: Data
        var pos = 0
        var atEnd: Bool { pos == data.count }
        mutating func tlv(_ tag: UInt8, _ what: String) throws -> Data {
            guard pos + 2 <= data.count else {
                throw CXFError.invalidKeyEncoding("truncated \(what)")
            }
            guard data[pos] == tag else {
                throw CXFError.invalidKeyEncoding(
                    "expected \(what), found DER tag \(String(format: "%02x", data[pos]))")
            }
            let length = Int(data[pos + 1])
            guard length & 0x80 == 0 else {
                throw CXFError.invalidKeyEncoding("long-form length in \(what)")
            }
            guard pos + 2 + length <= data.count else {
                throw CXFError.invalidKeyEncoding("truncated \(what) value")
            }
            let value = data[(pos + 2) ..< (pos + 2 + length)]
            pos += 2 + length
            return Data(value)
        }
    }

    private static func checkScalar(_ scalar: Data) throws {
        guard scalar.count == 32 else {
            throw CXFError.invalidKeyEncoding("P-256 scalar must be 32 bytes, got \(scalar.count)")
        }
        guard scalar != Data(repeating: 0, count: 32) else {
            throw CXFError.invalidKeyEncoding("zero is not a valid P-256 scalar")
        }
        guard scalar.lexicographicallyPrecedes(p256Order) else {
            throw CXFError.invalidKeyEncoding("scalar is not below the P-256 group order")
        }
    }

    static func wrapP256Scalar(_ scalar: Data) throws -> Data {
        try checkScalar(scalar)
        // ECPrivateKey ::= SEQUENCE { INTEGER 1, OCTET STRING <scalar> }
        var ecPrivateKey = Data([0x30, 0x25, 0x02, 0x01, 0x01, 0x04, 0x20])
        ecPrivateKey.append(scalar)
        // PrivateKeyInfo ::= SEQUENCE { INTEGER 0, AlgorithmIdentifier, OCTET STRING <ecPrivateKey> }
        var der = Data([0x30, 0x41, 0x02, 0x01, 0x00])
        der.append(contentsOf: [0x30, 0x13])
        der.append(contentsOf: [0x06, 0x07]); der.append(ecPublicKeyOID)
        der.append(contentsOf: [0x06, 0x08]); der.append(prime256v1OID)
        der.append(contentsOf: [0x04, 0x27]); der.append(ecPrivateKey)
        return der
    }

    static func unwrapP256Scalar(_ der: Data) throws -> Data {
        var outer = Reader(data: der)
        let info = try outer.tlv(0x30, "PrivateKeyInfo")
        guard outer.atEnd else {
            throw CXFError.invalidKeyEncoding("trailing bytes after PrivateKeyInfo")
        }
        var level1 = Reader(data: info)
        let version = try level1.tlv(0x02, "PKCS#8 version")
        guard version == Data([0x00]) else {
            throw CXFError.invalidKeyEncoding("PKCS#8 version must be 0")
        }
        var algorithm = Reader(data: try level1.tlv(0x30, "algorithm identifier"))
        guard try algorithm.tlv(0x06, "algorithm OID") == ecPublicKeyOID else {
            throw CXFError.invalidKeyEncoding("key is not an EC key (id-ecPublicKey)")
        }
        guard try algorithm.tlv(0x06, "curve OID") == prime256v1OID else {
            throw CXFError.invalidKeyEncoding("EC key is not on P-256 (prime256v1)")
        }
        let privateKey = try level1.tlv(0x04, "privateKey OCTET STRING")
        var privateKeyReader = Reader(data: privateKey)
        var ec = Reader(data: try privateKeyReader.tlv(0x30, "ECPrivateKey"))
        let ecVersion = try ec.tlv(0x02, "ECPrivateKey version")
        guard ecVersion == Data([0x01]) else {
            throw CXFError.invalidKeyEncoding("ECPrivateKey version must be 1")
        }
        let scalar = try ec.tlv(0x04, "EC private scalar")
        // An optional [0] parameters / [1] publicKey may follow; the
        // scalar is what we custody, so trailing members are ignored.
        try checkScalar(scalar)
        return scalar
    }
}

// MARK: - Model (§3)

struct CXFVersion: Codable, Equatable {
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

extension CXFPasskey: Codable {
    enum CodingKeys: String, CodingKey {
        case type, credentialId, rpId, username, userDisplayName, userHandle, key
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == CXFPasskey.credentialType else {
            throw CXFError.malformedDocument("passkey payload carrying type '\(type)'")
        }
        credentialId = try CXFBase64.decode(
            container.decode(String.self, forKey: .credentialId), field: "credentialId")
        rpId = try container.decode(String.self, forKey: .rpId)
        username = try container.decode(String.self, forKey: .username)
        userDisplayName = try container.decode(String.self, forKey: .userDisplayName)
        userHandle = try CXFBase64.decode(
            container.decode(String.self, forKey: .userHandle), field: "userHandle")
        let der = try CXFBase64.decode(
            container.decode(String.self, forKey: .key), field: "key")
        key = try CXFPKCS8.unwrapP256Scalar(der)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CXFPasskey.credentialType, forKey: .type)
        try container.encode(CXFBase64.encode(credentialId), forKey: .credentialId)
        try container.encode(rpId, forKey: .rpId)
        try container.encode(username, forKey: .username)
        try container.encode(userDisplayName, forKey: .userDisplayName)
        try container.encode(CXFBase64.encode(userHandle), forKey: .userHandle)
        try container.encode(CXFBase64.encode(CXFPKCS8.wrapP256Scalar(key)), forKey: .key)
    }
}

/// A credential of any type, for import filtering: passkeys decode
/// fully; anything else is kept only as its type name so the caller can
/// count what it skipped (§3.1.1: unknown enum values handled
/// gracefully). Unknown credentials cannot be re-encoded — their fields
/// were never read — and trying is a caller bug.
enum CXFCredential: Equatable {
    case passkey(CXFPasskey)
    case unknown(String)
}

extension CXFCredential: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CXFPasskey.CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if type == CXFPasskey.credentialType {
            self = .passkey(try CXFPasskey(from: decoder))
        } else {
            self = .unknown(type)
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .passkey(let passkey):
            try passkey.encode(to: encoder)
        case .unknown(let type):
            throw CXFError.malformedDocument("cannot re-encode a skipped credential of type '\(type)'")
        }
    }
}

/// §3.2.3 Item. Slice 1 models only what a passkey export carries:
/// favorite/scope/tags/extensions are omitted on encode and ignored on
/// decode (§3.1.1 permits additive fields). `skippedCredentialCount` is
/// decode-side bookkeeping, never written to the wire.
struct CXFItem: Equatable {
    var id: Data
    var creationAt: UInt64?
    var modifiedAt: UInt64?
    var title: String
    var subtitle: String?
    var credentials: [CXFPasskey]
    var skippedCredentialCount: Int
}

extension CXFItem: Codable {
    enum CodingKeys: String, CodingKey {
        case id, creationAt, modifiedAt, title, subtitle, credentials
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try CXFBase64.decode(container.decode(String.self, forKey: .id), field: "item.id")
        creationAt = try container.decodeIfPresent(UInt64.self, forKey: .creationAt)
        modifiedAt = try container.decodeIfPresent(UInt64.self, forKey: .modifiedAt)
        title = try container.decode(String.self, forKey: .title)
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        let raw = try container.decode([CXFCredential].self, forKey: .credentials)
        credentials = raw.compactMap { credential in
            if case .passkey(let passkey) = credential { return passkey }
            return nil
        }
        skippedCredentialCount = raw.count - credentials.count
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CXFBase64.encode(id), forKey: .id)
        try container.encodeIfPresent(creationAt, forKey: .creationAt)
        try container.encodeIfPresent(modifiedAt, forKey: .modifiedAt)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(subtitle, forKey: .subtitle)
        try container.encode(credentials, forKey: .credentials)
    }
}

/// §3.2.1 Account. `collections` is a REQUIRED member on the wire, so
/// encode always writes [] (we have no grouping); decode ignores its
/// contents — importing a foreign provider's folder tree is a later
/// slice. `extensions` is omitted/ignored (§3.1.1).
struct CXFAccount: Equatable {
    var id: Data
    var username: String
    var email: String
    var fullName: String?
    var items: [CXFItem]
}

extension CXFAccount: Codable {
    enum CodingKeys: String, CodingKey {
        case id, username, email, fullName, collections, items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try CXFBase64.decode(container.decode(String.self, forKey: .id), field: "account.id")
        username = try container.decode(String.self, forKey: .username)
        email = try container.decode(String.self, forKey: .email)
        fullName = try container.decodeIfPresent(String.self, forKey: .fullName)
        items = try container.decode([CXFItem].self, forKey: .items)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CXFBase64.encode(id), forKey: .id)
        try container.encode(username, forKey: .username)
        try container.encode(email, forKey: .email)
        try container.encodeIfPresent(fullName, forKey: .fullName)
        // §3.2.1: collections is a REQUIRED member — always emit it,
        // empty (we have no grouping); decode ignores its contents.
        try container.encode([String](), forKey: .collections)
        try container.encode(items, forKey: .items)
    }
}

/// §3.1 Header (the document root IS the header). A missing version or
/// a foreign major version is a hard error; everything else unknown is
/// ignored (§3.1.1).
struct CXFDocument: Equatable {
    var version: CXFVersion
    var exporterRpId: String
    var exporterDisplayName: String
    var timestamp: UInt64 // UNIX seconds (§3.1: uint .size 8)
    var accounts: [CXFAccount]
}

extension CXFDocument: Codable {
    enum CodingKeys: String, CodingKey {
        case version, exporterRpId, exporterDisplayName, timestamp, accounts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let decoded = try container.decodeIfPresent(CXFVersion.self, forKey: .version) else {
            throw CXFError.malformedDocument("missing version member")
        }
        guard decoded.major == CXFCodec.formatVersion.major else {
            throw CXFError.unsupportedMajorVersion(decoded.major)
        }
        version = decoded
        exporterRpId = try container.decode(String.self, forKey: .exporterRpId)
        exporterDisplayName = try container.decode(String.self, forKey: .exporterDisplayName)
        timestamp = try container.decode(UInt64.self, forKey: .timestamp)
        accounts = try container.decode([CXFAccount].self, forKey: .accounts)
    }
}

// MARK: - Codec

enum CXFCodec {
    /// §3.1.1: the current published format level.
    static let formatVersion = CXFVersion(major: 1, minor: 0)

    /// Deterministic output (sorted keys) so two exports of the same
    /// vault diff cleanly.
    static func encode(_ document: CXFDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    static func decode(_ data: Data) throws -> CXFDocument {
        do {
            return try JSONDecoder().decode(CXFDocument.self, from: data)
        } catch let error as CXFError {
            throw error
        } catch let error as DecodingError {
            throw CXFError.malformedDocument(describe(error))
        } catch {
            throw CXFError.malformedDocument("\(error)")
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context),
             .keyNotFound(_, let context),
             .typeMismatch(_, let context),
             .valueNotFound(_, let context):
            return context.debugDescription
        @unknown default:
            return "\(error)"
        }
    }
}
