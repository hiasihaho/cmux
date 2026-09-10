import Crypto
import Foundation
import Glibc

// Vault-key provider for WebAuthn vault encryption-at-rest (PASSKEYS.md
// P1b; GAPS.md "Passkeys P1b–P3"). The vault holds only the load/save
// seam (WebAuthnVault in WebAuthnAuthenticator.swift); this file decides
// WHERE the AES-GCM master key comes from:
//
//   host    — a random 32-byte key stored as a gnome-keyring item via
//             `secret-tool` (org.freedesktop.secrets on the session bus).
//   flatpak — the Secret portal (org.freedesktop.portal.Secret): a
//             per-app master secret read over a pipe fd, expanded to 32
//             bytes with HKDF-SHA256. No keyring-wide access, no
//             --talk-name finish-arg.
//   none    — no backend reachable: the vault stays 0600 plaintext with
//             an honest logged warning, never silently.
//
// Backend selection: CMUX_WEBAUTHN_KEY_BACKEND=host|portal|none forces a
// backend (suites need determinism); unset means auto — portal inside
// flatpak (FLATPAK_ID set), host otherwise, none when the host lookup
// fails.
//
// The key never touches disk outside the keyring/portal; the plaintext
// vault never touches disk when a backend answers (see WebAuthnVault).

enum WebAuthnVaultKeyProvider {
    enum Backend: String {
        case host, portal, file, none
    }

    struct VaultKey {
        let key: SymmetricKey
        let backend: Backend
    }

    /// Resolve the vault key for this process. Returns nil only in the
    /// `none` case (caller logs the honest fallback warning once).
    static func resolve() -> VaultKey? {
        switch forcedBackend() {
        case .host:
            return hostKey().map { VaultKey(key: $0, backend: .host) }
                ?? { FileHandle.standardError.write(Data(
                    "cmux: webauthn vault key: forced host backend unavailable (secret-tool/keyring), vault stays plaintext\n".utf8)); return nil }()
        case .portal:
            return portalKey().map { VaultKey(key: $0, backend: .portal) }
                ?? { FileHandle.standardError.write(Data(
                    "cmux: webauthn vault key: forced portal backend unavailable, vault stays plaintext\n".utf8)); return nil }()
        case .file:
            return fileKey().map { VaultKey(key: $0, backend: .file) }
        case .none:
            return nil
        case .auto:
            if isFlatpak {
                if let key = portalKey() { return VaultKey(key: key, backend: .portal) }
            } else if let key = hostKey() {
                return VaultKey(key: key, backend: .host)
            }
            return nil
        }
    }

    // MARK: - selection

    private enum Selection { case host, portal, file, none, auto }

    private static var isFlatpak: Bool {
        guard let raw = ProcessInfo.processInfo.environment["FLATPAK_ID"] else { return false }
        return !raw.isEmpty
    }

    private static func forcedBackend() -> Selection {
        switch ProcessInfo.processInfo.environment["CMUX_WEBAUTHN_KEY_BACKEND"] {
        case "host": return .host
        case "portal": return .portal
        case "file": return .file
        case "none": return .none
        default: return .auto
        }
    }

    // MARK: - file backend: a key file beside a REDIRECTED vault

    /// The suites' key backend. It exists so tests never touch the real
    /// Secret Service — the layer-1 defect (2026-09-10) was that the host
    /// keyring key was global, so a KEY_BACKEND=host test could overwrite
    /// the developer's real vault key. A file key keyed to the vault is
    /// isolated by construction.
    ///
    /// Gated exactly like the consent bypass (S3) and the UV test backend:
    /// it is inert on the default vault. Keying the credentials a person
    /// actually uses off a file on disk — plantable, unencrypted at rest —
    /// would be a NEW way to lose or subvert them, so `file` on the
    /// default vault refuses and says so, and the caller falls back to the
    /// honest no-backend plaintext warning.
    private static func fileKey() -> SymmetricKey? {
        let vault = ProcessInfo.processInfo.environment["CMUX_WEBAUTHN_VAULT"] ?? ""
        guard !vault.isEmpty else {
            if !fileRefusalLogged {
                fileRefusalLogged = true
                FileHandle.standardError.write(Data(
                    ("cmux: webauthn vault key: file key backend ignored — "
                     + "CMUX_WEBAUTHN_KEY_BACKEND=file requires an explicit "
                     + "CMUX_WEBAUTHN_VAULT pointing away from the default vault, so a "
                     + "file-backed key can never protect real credentials. Falling "
                     + "back to no key backend.\n").utf8))
            }
            return nil
        }
        let keyPath = (vault as NSString).expandingTildeInPath + ".key"
        if let existing = try? String(contentsOf: URL(fileURLWithPath: keyPath), encoding: .utf8),
           let decoded = Data(base64Encoded: existing.trimmingCharacters(in: .whitespacesAndNewlines)),
           decoded.count == 32 {
            return SymmetricKey(data: decoded)
        }
        // No key file yet: mint one for THIS vault and persist it 0600.
        // Minting here is safe — a file key is per-vault by its path, and
        // this backend is already gated to redirected (test) vaults.
        let key = SymmetricKey(size: .bits256)
        let raw = key.withUnsafeBytes { Data($0) }
        let b64 = raw.base64EncodedString()
        let tmp = keyPath + ".\(UUID().uuidString).tmp"
        do {
            try Data(b64.utf8).write(to: URL(fileURLWithPath: tmp))
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp)
            guard rename(tmp, keyPath) == 0 else {
                try? FileManager.default.removeItem(atPath: tmp)
                return nil
            }
        } catch { return nil }
        return key
    }

    private static var fileRefusalLogged = false

    // MARK: - host backend: gnome-keyring via secret-tool

    /// Read the existing key, or create-and-store a fresh random one.
    /// secret-tool is the libsecret CLI; it talks org.freedesktop.secrets
    /// for us, so no direct D-Bus code is needed on the host path.
    private static let hostKeyLabel = "cmux WebAuthn vault key"

    private static func hostKey() -> SymmetricKey? {
        if let existing = runSecretTool(["secret-tool", "lookup",
                                         "service", "cmux",
                                         "purpose", "webauthn-vault-key"]),
           let key = decodeStoredKey(existing) {
            return key
        }
        // First run: generate and store. A store failure must NOT fall
        // back to plaintext silently — report nil and let resolve()'s
        // caller log the honest warning.
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytesShim(&bytes) else { return nil }
        let secret = Data(bytes).base64EncodedString()
        guard runSecretToolInput(
            ["secret-tool", "store", "--label", hostKeyLabel,
             "service", "cmux", "purpose", "webauthn-vault-key"],
            input: secret
        ) else { return nil }
        return SymmetricKey(data: Data(bytes))
    }

    private static func decodeStoredKey(_ stored: String) -> SymmetricKey? {
        let trimmed = stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: trimmed), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    // MARK: - flatpak backend: Secret portal

    /// org.freedesktop.portal.Secret.RetrieveSecret: the portal writes the
    /// per-app master secret into a pipe we supply. We drive it with
    /// gdbus (ships with GLib, present in every flatpak runtime) and read
    /// the secret from the pipe's read end. The secret length is opaque
    /// to us, so it is expanded with HKDF-SHA256 to the AES-256 key.
    private static func portalKey() -> SymmetricKey? {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { return nil }
        let readFD = fds[0], writeFD = fds[1]
        defer { close(readFD) }

        // gdbus call --session -d org.freedesktop.portal.Desktop
        //   -o /org/freedesktop/portal/desktop
        //   -m org.freedesktop.portal.Secret.RetrieveSecret <fd> {}
        // The fd is inherited by number; gdbus handles the h encoding.
        let out = runCapturing([
            "gdbus", "call", "--session",
            "-d", "org.freedesktop.portal.Desktop",
            "-o", "/org/freedesktop/portal/desktop",
            "-m", "org.freedesktop.portal.Secret.RetrieveSecret",
            String(writeFD), "{}",
        ])
        close(writeFD)
        guard out != nil else { return nil }

        var secret = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        // Bounded read: a portal that errors without closing its dup would
        // otherwise hang the main thread here. poll() with a 5s ceiling.
        while true {
            var pfd = pollfd(fd: readFD, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 5000)
            if ready <= 0 { break }  // timeout or error — take what we have
            let n = read(readFD, &buf, buf.count)
            if n <= 0 { break }
            secret.append(contentsOf: buf[0..<n])
        }
        guard !secret.isEmpty else { return nil }
        // The portal secret's length is opaque; expand to the AES-256 key.
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: secret),
            salt: Data("cmux-webauthn-vault".utf8),
            info: Data("aes-gcm-256".utf8),
            outputByteCount: 32
        )
    }

    // MARK: - process helpers (SystemTop.runHost pattern)

    private static func runSecretTool(_ argv: [String]) -> String? {
        runCapturing(argv)
    }

    private static func runSecretToolInput(_ argv: [String], input: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let inPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return false }
        return process.terminationStatus == 0
    }

    private static func runCapturing(_ argv: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        // Read before waiting (full-pipe deadlock, see SystemTop).
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// CSPRNG shim: read from /dev/urandom (getrandom(2) without the
/// sys/random.h import dance; urandom never blocks after early boot).
private func SecRandomCopyBytesShim(_ bytes: inout [UInt8]) -> Bool {
    let fd = open("/dev/urandom", O_RDONLY)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var written = 0
    while written < bytes.count {
        let n = bytes.withUnsafeMutableBufferPointer { buf -> Int in
            guard let base = buf.baseAddress else { return -1 }
            return read(fd, base.advanced(by: written), buf.count - written)
        }
        if n <= 0 { return false }
        written += n
    }
    return true
}
