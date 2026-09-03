import Foundation

// Socket verbs over the WebAuthn vault (PASSKEYS.md §0, passkey-desk
// lane): status / list / rm. A credential store nobody can inspect is a
// liability — these make the P1b vault operable from the CLI.
//
// Boundary rules:
//  - Everything goes through the WebAuthnVault load/save seam; the
//    envelope crypto stays that file's concern. The one exception is
//    `status`, which READS the vault file head to report
//    encrypted/backend without forcing a key resolve for a status call.
//  - list NEVER exposes private-key material — ids and metadata only.
//  - Socket access is the authorization boundary, same as the cookies
//    and storage verbs: whoever holds the socket owns the vault file
//    anyway. `rm` is available even with CMUX_WEBAUTHN unset (cleanup
//    must not require enabling the feature).

extension ControlCommandHandler {

    func v2BrowserWebAuthnStatus(id: Any?) -> String {
        var present = false
        var encrypted = false
        var backend = "none"
        if let data = try? Data(contentsOf: WebAuthnVault.fileURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            present = true
            if let version = object["version"] as? Int, version >= 2 {
                encrypted = true
                backend = object["backend"] as? String ?? "unknown"
            }
        }
        // Count via the seam — on an encrypted vault this resolves the
        // key (and may run the v1 migration), which is what an operator
        // asking for status wants to see happen.
        let count = present ? WebAuthnVault.load().count : 0
        return v2Ok(id: id, result: [
            "enabled": BrowserWebAuthn.isEnabled,
            "vault_present": present,
            "vault_encrypted": encrypted,
            "vault_backend": backend,
            "vault_path": WebAuthnVault.fileURL.path,
            "credential_count": count,
        ])
    }

    func v2BrowserWebAuthnList(id: Any?) -> String {
        let credentials = WebAuthnVault.load().map { credential -> [String: Any] in
            [
                "id": webAuthnB64url(credential.id),
                "rp_id": credential.rpId,
                "user_name": credential.userName,
                "user_display_name": credential.userDisplayName,
                "user_handle": webAuthnB64url(credential.userHandle),
                "created_at_ms": credential.createdAtMs,
            ]
        }
        return v2Ok(id: id, result: ["credentials": credentials])
    }

    func v2BrowserWebAuthnRemove(id: Any?, params: [String: Any]) -> String {
        guard let idString = params["credential_id"] as? String,
              let credentialId = webAuthnB64urlDecode(idString) else {
            return v2Error(id: id, code: "invalid_request",
                           message: "webauthn rm requires a base64url credential_id")
        }
        var vault = WebAuthnVault.load()
        let before = vault.count
        vault.removeAll { $0.id == credentialId }
        let removed = before - vault.count
        guard removed > 0 else {
            return v2Error(id: id, code: "not_found",
                           message: "No credential with that id in the vault")
        }
        do {
            try WebAuthnVault.save(vault)
        } catch {
            return v2Error(id: id, code: "internal_error",
                           message: "Vault save failed: \(error)")
        }
        return v2Ok(id: id, result: ["removed": removed])
    }
}

private func webAuthnB64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func webAuthnB64urlDecode(_ string: String) -> Data? {
    var s = string.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}
