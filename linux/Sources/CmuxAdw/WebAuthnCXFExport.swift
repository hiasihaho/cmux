import Adwaita
import CAdw
import Crypto
import Foundation
import _CryptoExtras

// CXF slice 2a — the vault-seam EXPORT (PASSKEYS.md §0 "CXF-core
// brief"; green-lit in announce-cmux-desk 2026-09-03 with the scrypt
// correction). This file is the ONLY export path, and it is deliberately
// NOT referenced from BrowserWebAuthn.swift: no export may ever be
// reachable from the page bridge (the suite carries a grep-leg).
//
// The four security rules, and where each lives:
//  1. No page-bridge reachability — structural: this file is socket-verb
//     only, and BrowserWebAuthn.swift never names it.
//  2. Native consent naming what leaves — presentExportConsent below:
//     count, RP list, destination, and the format, in an AdwAlertDialog
//     on the main window. Consent is ASYNC (GClosure + completion);
//     ControlSocketServer answers verbs inside response.wait(seconds:),
//     so a verb must never block on a human.
//  3. Nothing plaintext on disk by default — the default artifact is a
//     passphrase-encrypted envelope around the CXF document. CXF v1.0
//     defines no encrypted container (CXP encrypts in transfer), so this
//     envelope is OURS, documented as such, until CXP exists: scrypt
//     (a PASSWORD kdf — HKDF is extract-and-expand for high-entropy
//     input and would leave the artifact open to a fast offline
//     dictionary attack) with the parameters recorded IN the envelope,
//     so a future cost-tune never strands a file (same class as the
//     vault's v1->v2 migration). --plaintext opts out, and the consent
//     dialog says PLAINTEXT when it does.
//  4. No standing ceremony grant implies an export grant — the suite
//     hatch is a SEPARATE env (CMUX_WEBAUTHN_EXPORT_AUTOAPPROVE), never
//     the ceremony's CMUX_WEBAUTHN_AUTOAPPROVE, and both are banned from
//     any flatpak manifest (consent IS the security boundary).

/// Outcome of an export, posted to the notification store when the
/// consent flow resolves. Typed, never a silent "pending" that never
/// resolves.
enum CXFExportCompletion {
    case exported(path: String, count: Int, format: String)
    case denied
    case expired
    case failed(String)

    var stateName: String {
        switch self {
        case .exported: return "exported"
        case .denied: return "denied"
        case .expired: return "expired"
        case .failed: return "failed"
        }
    }
}

enum CXFExportError: Error, Equatable {
    case noCredentials
    case undecryptableVault
    case destinationExists(String)
    case missingPassphrase
    case writeFailed(String)
}

struct CXFExportRequest {
    var destination: String
    var plaintext: Bool
    var force: Bool
    /// From --passphrase-stdin. Never an argv value (ps visibility).
    /// With the dialog up and this nil, the dialog's entry field asks.
    var passphrase: String?

    var expandedDestination: String {
        (destination as NSString).expandingTildeInPath
    }
}

enum WebAuthnCXFExport {
    /// Wire value in the pending reply + the envelope's format member.
    static let encryptedFormat = "cmux-cxf-encrypted"
    static let plaintextFormat = "cxf-plaintext"

    /// Human-facing format sentence, used by BOTH the consent dialog and
    /// the CLI output (sharpening 3: say which artifact you just made —
    /// the encrypted default is the safe one but only cmux reads it; the
    /// plaintext CXF is the portable one, and portability is the point).
    static func formatSentence(plaintext: Bool) -> String {
        plaintext
            ? "CXF (portable, plaintext — any CXF importer can read this)"
            : "cmux-encrypted CXF (only cmux can read this)"
    }

    /// Suite-only consent bypass. Separate from the ceremony hatch on
    /// purpose (rule 4); banned from any flatpak manifest.
    static var autoApproves: Bool {
        ProcessInfo.processInfo.environment["CMUX_WEBAUTHN_EXPORT_AUTOAPPROVE"] == "1"
    }

    /// scrypt cost baseline. 128*N*r*p bytes of memory (128 MiB here);
    /// recorded in every envelope so retuning never strands a file.
    private static let scryptN = 131072
    private static let scryptR = 8
    private static let scryptP = 1

    // MARK: - validation (synchronous, before consent)

    /// Loads the vault through the P1b seam and validates the request.
    /// The loaded credentials ride along so consent never reloads.
    static func validate(
        _ request: CXFExportRequest
    ) -> Result<(credentials: [WebAuthnCredential], rpIds: [String]), CXFExportError> {
        let credentials = WebAuthnVault.load()
        if WebAuthnVault.vaultIsUndecryptable { return .failure(.undecryptableVault) }
        guard !credentials.isEmpty else { return .failure(.noCredentials) }
        if !request.force,
           FileManager.default.fileExists(atPath: request.expandedDestination) {
            return .failure(.destinationExists(request.expandedDestination))
        }
        if !request.plaintext, autoApproves,
           (request.passphrase?.isEmpty ?? true) {
            // The hatch skips the dialog, so nothing remains to ask.
            return .failure(.missingPassphrase)
        }
        var seen = Set<String>()
        let rpIds = credentials.map(\.rpId).filter { seen.insert($0).inserted }
        return .success((credentials, rpIds))
    }

    // MARK: - document + envelope

    /// vault entry -> CXF passkey item, field for field. One Item per
    /// credential (an Item groups RELATED credentials; ours are each
    /// their own registration). The account is a placeholder — our vault
    /// has no account concept; spec-required members get honest empties.
    static func buildDocument(_ credentials: [WebAuthnCredential]) -> CXFDocument {
        let items = credentials.map { credential in
            CXFItem(
                id: credential.id,
                creationAt: UInt64(credential.createdAtMs / 1000),
                modifiedAt: nil,
                title: "\(credential.userName) @ \(credential.rpId)",
                subtitle: nil,
                credentials: [CXFPasskey(
                    credentialId: credential.id,
                    rpId: credential.rpId,
                    username: credential.userName,
                    userDisplayName: credential.userDisplayName,
                    userHandle: credential.userHandle,
                    key: credential.privateKey
                )],
                skippedCredentialCount: 0
            )
        }
        let accountId = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        return CXFDocument(
            version: CXFCodec.formatVersion,
            exporterRpId: "cmux.local",
            exporterDisplayName: "cmux",
            timestamp: UInt64(Date().timeIntervalSince1970),
            accounts: [CXFAccount(id: accountId, username: "", email: "",
                                  fullName: nil, items: items)]
        )
    }

    private struct EnvelopeKDF: Codable {
        var name: String // "scrypt"
        var salt: String // base64
        var n: Int
        var r: Int
        var p: Int
    }

    private struct ExportEnvelope: Codable {
        var version: Int
        var format: String
        var kdf: EnvelopeKDF
        var nonce: String      // base64
        var ciphertext: String // base64, AES-GCM ct||tag
    }

    /// The bytes that land on disk. Plaintext is the CXF document itself;
    /// encrypted is OUR envelope (not a spec artifact — see the header).
    static func render(_ document: CXFDocument, request: CXFExportRequest,
                       passphrase: String?) throws -> Data {
        let cxf = try CXFCodec.encode(document)
        guard !request.plaintext else { return cxf }
        guard let passphrase, !passphrase.isEmpty else {
            throw CXFExportError.missingPassphrase
        }
        let salt = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
        let key = try KDF.Scrypt.deriveKey(
            from: Data(passphrase.utf8), salt: salt, outputByteCount: 32,
            rounds: scryptN, blockSize: scryptR, parallelism: scryptP,
            maxMemory: 1 << 30
        )
        let sealed = try AES.GCM.seal(cxf, using: key)
        guard let combined = sealed.combined else {
            throw CXFExportError.writeFailed("AES-GCM seal produced no combined representation")
        }
        let envelope = ExportEnvelope(
            version: 1,
            format: encryptedFormat,
            kdf: EnvelopeKDF(
                name: "scrypt",
                salt: salt.base64EncodedString(),
                n: scryptN, r: scryptR, p: scryptP
            ),
            nonce: combined.prefix(12).base64EncodedString(),
            ciphertext: combined.suffix(from: 12).base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    /// 0600, tmp+rename (the vault's pattern), and the refuse-existing
    /// check runs AGAIN here: consent is async, so the path could have
    /// appeared while the dialog stood.
    static func write(_ data: Data, request: CXFExportRequest) throws {
        let path = request.expandedDestination
        if !request.force, FileManager.default.fileExists(atPath: path) {
            throw CXFExportError.destinationExists(path)
        }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".cxf-export.\(UUID().uuidString).tmp")
        try data.write(to: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
        guard rename(tmp.path, path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CXFExportError.writeFailed("rename into \(path) failed (errno \(errno))")
        }
    }
}

// MARK: - consent + completion (async; never inside response.wait)

/// One pending export's shared state across the dialog response and the
/// expiry timer. All callbacks fire on the main loop.
private final class CXFExportBox {
    var fired = false
    let request: CXFExportRequest
    let credentials: [WebAuthnCredential]
    let entry: UnsafeMutableRawPointer? // GtkEntry, encrypted-without-passphrase case
    let completion: (CXFExportCompletion) -> Void
    init(request: CXFExportRequest, credentials: [WebAuthnCredential],
         entry: UnsafeMutableRawPointer?,
         completion: @escaping (CXFExportCompletion) -> Void) {
        self.request = request
        self.credentials = credentials
        self.entry = entry
        self.completion = completion
    }
}

private let cxfExportResponse: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { _, response, userData in
    guard let userData else { return }
    let box = Unmanaged<CXFExportBox>.fromOpaque(userData).takeUnretainedValue()
    guard !box.fired else { return }
    box.fired = true
    guard response.map({ String(cString: $0) == "export" }) == true else {
        box.completion(.denied)
        return
    }
    WebAuthnCXFExport.finish(box)
}

private let cxfExportDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<CXFExportBox>.fromOpaque(data).release()
}

extension WebAuthnCXFExport {

    /// Entry point from the verb handler. Validation has already passed;
    /// this either completes immediately (suite hatch) or presents the
    /// consent dialog and completes from its response/expiry.
    static func begin(
        request: CXFExportRequest,
        credentials: [WebAuthnCredential],
        completion: @escaping (CXFExportCompletion) -> Void
    ) {
        if autoApproves {
            let box = CXFExportBox(request: request, credentials: credentials,
                                   entry: nil, completion: completion)
            box.fired = true
            finish(box)
            return
        }
        presentExportConsent(request: request, credentials: credentials, completion: completion)
    }

    /// Consent granted (or the hatch fired): render + write + report.
    /// The passphrase comes from the request, else the dialog entry.
    fileprivate static func finish(_ box: CXFExportBox) {
        let request = box.request
        var passphrase = request.passphrase
        if !request.plaintext, (passphrase?.isEmpty ?? true), let entry = box.entry {
            let text = gtk_editable_get_text(OpaquePointer(entry))
            passphrase = text.map { String(cString: $0) }
        }
        do {
            let document = buildDocument(box.credentials)
            let data = try render(document, request: request, passphrase: passphrase)
            try write(data, request: request)
            box.completion(.exported(
                path: request.expandedDestination, count: box.credentials.count,
                format: request.plaintext ? plaintextFormat : encryptedFormat))
        } catch CXFExportError.missingPassphrase {
            box.completion(.failed("no passphrase given for the encrypted export"))
        } catch CXFExportError.destinationExists(let path) {
            box.completion(.failed("destination appeared during consent: \(path)"))
        } catch {
            box.completion(.failed("\(error)"))
        }
    }

    private static func presentExportConsent(
        request: CXFExportRequest,
        credentials: [WebAuthnCredential],
        completion: @escaping (CXFExportCompletion) -> Void
    ) {
        let rpList = Array(Set(credentials.map(\.rpId))).sorted()
        let shown = rpList.prefix(8).joined(separator: ", ")
        let suffix = rpList.count > 8 ? " and \(rpList.count - 8) more" : ""
        var body = "Export \(credentials.count) passkey(s) for \(shown)\(suffix)"
            + "\nDestination: \(request.expandedDestination)"
            + "\nFormat: \(formatSentence(plaintext: request.plaintext))"
            + "\n\nThe file contains the PRIVATE KEYS. Anyone holding it can sign in as these accounts."
        let needsEntry = !request.plaintext && (request.passphrase?.isEmpty ?? true)
        if needsEntry {
            body += "\nChoose an export passphrase below."
        }
        guard let raw = adw_alert_dialog_new("Export passkeys?", body) else {
            completion(.failed("could not create the consent dialog"))
            return
        }
        let alert = UnsafeMutableRawPointer(raw).assumingMemoryBound(to: AdwAlertDialog.self)
        adw_alert_dialog_add_response(alert, "cancel", "Cancel")
        adw_alert_dialog_add_response(alert, "export", "Export")
        adw_alert_dialog_set_response_appearance(alert, "export", ADW_RESPONSE_DESTRUCTIVE)
        adw_alert_dialog_set_close_response(alert, "cancel")

        var entry: UnsafeMutableRawPointer?
        if needsEntry, let rawEntry = gtk_entry_new() {
            let gtkEntry = UnsafeMutableRawPointer(rawEntry).assumingMemoryBound(to: GtkEntry.self)
            gtk_entry_set_visibility(gtkEntry, 0)
            gtk_entry_set_activates_default(gtkEntry, 1)
            adw_alert_dialog_set_default_response(alert, "export")
            adw_alert_dialog_set_extra_child(alert, rawEntry)
            entry = UnsafeMutableRawPointer(rawEntry)
        } else {
            adw_alert_dialog_set_default_response(alert, "export")
        }

        let box = Unmanaged.passRetained(
            CXFExportBox(request: request, credentials: credentials,
                         entry: entry, completion: completion)
        ).toOpaque()
        g_signal_connect_data(
            UnsafeMutableRawPointer(raw), "response",
            unsafeBitCast(cxfExportResponse, to: GCallback.self),
            box, cxfExportDestroy, GConnectFlags(0)
        )
        // Expiry: a dialog nobody answers resolves as `expired`, never a
        // pending that never resolves. g_timeout_add repeats while the
        // callback returns non-zero; ours fires once.
        _ = g_timeout_add(5 * 60 * 1000, { userData in
            guard let userData else { return 0 }
            let box = Unmanaged<CXFExportBox>.fromOpaque(userData).takeUnretainedValue()
            if !box.fired {
                box.fired = true
                box.completion(.expired)
            }
            return 0
        }, box)
        adw_dialog_present(
            UnsafeMutableRawPointer(raw).assumingMemoryBound(to: AdwDialog.self),
            UIDialogs.mainWindowWidget()
        )
    }
}

// MARK: - socket verb (browser.webauthn.export)

extension ControlCommandHandler {

    /// Initiates an export. Validates synchronously and answers at once —
    /// either a typed error or `consent_pending`; the socket never waits
    /// on the human. Completion (exported/denied/expired/failed) lands in
    /// the notification store.
    func v2BrowserWebAuthnExport(id: Any?, params: [String: Any]) -> String {
        guard let destination = params["destination"] as? String, !destination.isEmpty else {
            return v2Error(id: id, code: "invalid_params",
                           message: "browser.webauthn.export requires a destination path")
        }
        let request = CXFExportRequest(
            destination: destination,
            plaintext: (params["plaintext"] as? Bool) ?? false,
            force: (params["force"] as? Bool) ?? false,
            passphrase: (params["passphrase"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        )
        switch WebAuthnCXFExport.validate(request) {
        case .failure(.undecryptableVault):
            return v2Error(id: id, code: "unavailable",
                           message: "The passkey vault cannot be decrypted right now (key backend unavailable or changed) — refusing to export. The vault is preserved; see the instance log.")
        case .failure(.noCredentials):
            return v2Error(id: id, code: "invalid_state",
                           message: "No credentials in the passkey vault — nothing to export")
        case .failure(.destinationExists(let path)):
            return v2Error(id: id, code: "invalid_state",
                           message: "Destination exists: \(path) — pass force to overwrite")
        case .failure(.missingPassphrase):
            return v2Error(id: id, code: "invalid_params",
                           message: "Encrypted export needs a passphrase (the consent dialog asks when it can; headless runs must supply one)")
        case .failure(.writeFailed(let why)):
            return v2Error(id: id, code: "internal_error", message: why)
        case .success(let validated):
            let credentials = validated.credentials
            let rpIds = validated.rpIds
            let format = request.plaintext
                ? WebAuthnCXFExport.plaintextFormat : WebAuthnCXFExport.encryptedFormat
            let notifications = self.notifications
            let selection = self.selection
            let tabs = self.tabs
            WebAuthnCXFExport.begin(request: request, credentials: credentials) { completion in
                WebAuthnCXFExport.postCompletion(
                    completion, notifications: notifications,
                    selection: selection, tabs: tabs)
            }
            return v2Ok(id: id, result: [
                "status": "consent_pending",
                "credential_count": credentials.count,
                "rp_ids": rpIds,
                "destination": request.expandedDestination,
                "format": format,
            ])
        }
    }
}

extension WebAuthnCXFExport {
    /// The completion lands in the notification store (queryable via
    /// list-notifications) with the typed state in the body, plus an
    /// instance-log breadcrumb. Anchored to the currently selected
    /// workspace — the human consented there.
    static func postCompletion(
        _ completion: CXFExportCompletion,
        notifications: Binding<[TerminalNotification]>,
        selection: Binding<UUID>,
        tabs: Binding<[TerminalTab]>
    ) {
        let body: String
        switch completion {
        case .exported(let path, let count, let format):
            body = "exported \(count) passkey(s) to \(path) — \(format) (\(formatSentence(plaintext: format == plaintextFormat)))"
        case .denied:
            body = "denied by the user — no file written"
        case .expired:
            body = "expired (consent dialog unanswered for 5 minutes) — no file written"
        case .failed(let why):
            body = "failed: \(why)"
        }
        FileHandle.standardError.write(Data(
            "cmux: webauthn export \(completion.stateName): \(body)\n".utf8))
        let tabId = selection.wrappedValue
        notifications.wrappedValue.append(TerminalNotification(
            tabId: tabId,
            surfaceId: nil,
            title: "Passkey export: \(completion.stateName)",
            subtitle: "",
            body: body
        ))
        if let index = tabs.wrappedValue.firstIndex(where: { $0.id == tabId }) {
            tabs.wrappedValue[index].needsAttention = true
        }
    }
}
