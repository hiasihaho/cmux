import CAdw
import CWebKit
import Crypto
import Foundation

// WebAuthn client layer for browser panes (docs/linux-port/PASSKEYS.md
// option B). WebKitGTK exposes no WebAuthn to pages (P0 probe), so a
// document-start user script DEFINES `navigator.credentials`,
// `PublicKeyCredential` and the response classes, and bridges
// create()/get() to native over a reply-capable script message handler.
// The wire protocol ({kind, payload} → {ok, credential|error}) and the
// serialized credential shape are the macOS bridge's
// (BrowserWebAuthnBridgeContract in Sources/Panels/) so the two ports
// stay conceptually one implementation.
//
// Deliberate v1 deviation from macOS: one page-world script + main-world
// handler instead of the two-world CustomEvent relay. macOS hides its
// native channel from pages because it *patches* a live WebKit API; here
// there is nothing to hide from — a page calling the handler directly is
// no stronger than a page calling the API we define, because every
// security decision (origin, rpId, consent) happens in Swift from
// embedder-trusted state, never from page-supplied data.
//
// SECURITY INVARIANTS (do not weaken in refactors):
//  - The effective origin comes from webkit_web_view_get_uri — never
//    from the message.
//  - rpId must be the origin's host or a registrable suffix of it.
//  - Ceremonies require explicit consent through a native dialog; the
//    auto-approve escape hatch is env-gated for tests/dev instances and
//    additionally requires the feature flag.
//  - Injection is TOP_FRAME only; the script self-disables in insecure
//    contexts.

enum BrowserWebAuthn {
    static let handlerName = "cmuxWebAuthn"

    /// Strictly opt-in while the feature hardens (same posture as
    /// CMUX_WEBDRIVER). Flip to a setting once dogfooded.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CMUX_WEBAUTHN"] == "1"
    }

    /// Test/dev escape hatch: skip the consent dialog. Headless suites
    /// cannot click GTK dialogs. Never enable on a daily instance.
    static var autoApproves: Bool {
        ProcessInfo.processInfo.environment["CMUX_WEBAUTHN_AUTOAPPROVE"] == "1"
    }
}

/// Carries the web view across the C signal callback (no captures
/// allowed); released by the closure-notify at disconnect time.
private final class WebAuthnHandlerBox {
    let webView: UnsafeMutablePointer<WebKitWebView>
    init(webView: UnsafeMutablePointer<WebKitWebView>) { self.webView = webView }
}

/// Install the WebAuthn client on a freshly created browser surface.
/// Same ordering discipline as installBrowserConsoleCapture: signal
/// first, then handler registration, then the user script.
func installBrowserWebAuthn(_ webView: UnsafeMutablePointer<WebKitWebView>) {
    guard BrowserWebAuthn.isEnabled else { return }
    guard let manager = webkit_web_view_get_user_content_manager(webView) else { return }

    let box = Unmanaged.passRetained(WebAuthnHandlerBox(webView: webView)).toOpaque()
    let callback: @convention(c) (
        UnsafeMutableRawPointer?, OpaquePointer?, OpaquePointer?, UnsafeMutableRawPointer?
    ) -> gboolean = { _, value, reply, userData in
        guard let userData, let value, let reply else { return 0 }
        let box = Unmanaged<WebAuthnHandlerBox>.fromOpaque(userData).takeUnretainedValue()
        handleWebAuthnMessage(webView: box.webView, value: value, reply: reply)
        return 1
    }
    let destroy: GClosureNotify = { data, _ in
        guard let data else { return }
        Unmanaged<WebAuthnHandlerBox>.fromOpaque(data).release()
    }
    g_signal_connect_data(
        UnsafeMutableRawPointer(manager),
        "script-message-with-reply-received::\(BrowserWebAuthn.handlerName)",
        unsafeBitCast(callback, to: GCallback.self),
        box,
        destroy,
        GConnectFlags(0)
    )
    _ = webkit_user_content_manager_register_script_message_handler_with_reply(
        manager, BrowserWebAuthn.handlerName, nil
    )

    if let script = webkit_user_script_new(
        browserWebAuthnUserScript,
        WEBKIT_USER_CONTENT_INJECT_TOP_FRAME,
        WEBKIT_USER_SCRIPT_INJECT_AT_DOCUMENT_START,
        nil, nil
    ) {
        webkit_user_content_manager_add_script(manager, script)
        webkit_user_script_unref(script)
    }
}

// MARK: - message handling

private func handleWebAuthnMessage(
    webView: UnsafeMutablePointer<WebKitWebView>,
    value: OpaquePointer,
    reply: OpaquePointer
) {
    guard let raw = jsc_value_to_string(value) else {
        returnWebAuthnError(reply, context: jsc_value_get_context(value),
                            name: "TypeError", message: "Malformed passkey request.")
        return
    }
    let text = String(cString: raw)
    g_free(raw)
    let context = jsc_value_get_context(value)

    guard text.utf8.count <= 512 * 1024,
          let decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
          let message = decoded as? [String: Any],
          let kind = message["kind"] as? String else {
        returnWebAuthnError(reply, context: context,
                            name: "TypeError", message: "Malformed passkey request.")
        return
    }

    switch kind {
    case "capabilities":
        returnWebAuthnJSON(reply, context: context, object: [
            "ok": true,
            "capabilities": [
                "userVerifyingPlatformAuthenticatorAvailable": true,
                "conditionalMediationAvailable": false,
            ],
        ])
    case "createCredential", "getCredential":
        runWebAuthnCeremony(
            kind: kind,
            payload: message["payload"] as? [String: Any] ?? [:],
            webView: webView, reply: reply, context: context
        )
    default:
        returnWebAuthnError(reply, context: context,
                            name: "NotSupportedError", message: "Unknown passkey request.")
    }
}

/// Effective origin, from embedder-trusted state only.
private struct WebAuthnOrigin {
    let scheme: String
    let host: String
    let serialized: String   // scheme://host[:port]

    var isPotentiallyTrustworthy: Bool {
        if scheme == "https" { return true }
        return host == "localhost" || host.hasSuffix(".localhost")
            || host == "127.0.0.1" || host == "::1"
    }

    /// WebAuthn rpId rule: equal to the host, or a suffix whose boundary
    /// is a dot. v1 ships without a public-suffix list; the dot
    /// requirement blocks the degenerate cases ("com"), which is the
    /// same pragmatic level the macOS bridge started at.
    func permitsRpId(_ rpId: String) -> Bool {
        if rpId == host { return true }
        guard rpId.contains(".") else { return false }
        return host.hasSuffix("." + rpId)
    }

    static func from(webView: UnsafeMutablePointer<WebKitWebView>) -> WebAuthnOrigin? {
        guard let uri = webkit_web_view_get_uri(webView),
              let url = URL(string: String(cString: uri)),
              let scheme = url.scheme?.lowercased(),
              let host = url.host?.lowercased() else { return nil }
        var serialized = "\(scheme)://\(host)"
        if let port = url.port,
           !(scheme == "https" && port == 443), !(scheme == "http" && port == 80) {
            serialized += ":\(port)"
        }
        return WebAuthnOrigin(scheme: scheme, host: host, serialized: serialized)
    }
}

private func runWebAuthnCeremony(
    kind: String,
    payload: [String: Any],
    webView: UnsafeMutablePointer<WebKitWebView>,
    reply: OpaquePointer,
    context: OpaquePointer?
) {
    guard let origin = WebAuthnOrigin.from(webView: webView),
          origin.isPotentiallyTrustworthy else {
        returnWebAuthnError(reply, context: context, name: "SecurityError",
                            message: "Passkey access requires a secure origin.")
        return
    }
    let publicKey = payload["publicKey"] as? [String: Any] ?? [:]
    let requestedRpId = ((publicKey["rp"] as? [String: Any])?["id"] as? String)
        ?? (publicKey["rpId"] as? String)
    let rpId = (requestedRpId?.isEmpty == false ? requestedRpId! : origin.host).lowercased()
    guard origin.permitsRpId(rpId) else {
        returnWebAuthnError(reply, context: context, name: "SecurityError",
                            message: "The relying party id is not valid for this origin.")
        return
    }

    let creating = kind == "createCredential"
    let finish: (Bool) -> Void = { approved in
        guard approved else {
            returnWebAuthnError(reply, context: context, name: "NotAllowedError",
                                message: "The passkey request was declined.")
            webkit_script_message_reply_unref(reply)
            return
        }
        do {
            let response = creating
                ? try performCreate(rpId: rpId, origin: origin, publicKey: publicKey)
                : try performGet(rpId: rpId, origin: origin, publicKey: publicKey)
            returnWebAuthnJSON(reply, context: context, object: response)
        } catch let error as WebAuthnCeremonyError {
            returnWebAuthnError(reply, context: context, name: error.name, message: error.message)
        } catch {
            // Generic toward the page (no internals leak), specific in
            // the instance log for debugging.
            FileHandle.standardError.write(Data(
                "cmux: webauthn ceremony failed unexpectedly: \(error)\n".utf8))
            returnWebAuthnError(reply, context: context, name: "UnknownError",
                                message: "The passkey request failed.")
        }
        webkit_script_message_reply_unref(reply)
    }

    // The reply outlives this stack frame whenever a dialog is shown.
    webkit_script_message_reply_ref(reply)
    if BrowserWebAuthn.autoApproves {
        finish(true)
        return
    }
    presentWebAuthnConsentDialog(
        webView: webView,
        rpId: rpId,
        creating: creating,
        userName: (publicKey["user"] as? [String: Any])?["name"] as? String,
        completion: finish
    )
}

// MARK: - ceremonies (bridge → authenticator)

private func b64urlDecode(_ s: String?) -> Data? {
    guard var s else { return nil }
    s = s.replacingOccurrences(of: "-", with: "+")
         .replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }
    return Data(base64Encoded: s)
}

private func b64url(_ d: Data) -> String {
    d.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

private func clientDataJSON(type: String, challenge: Data, origin: WebAuthnOrigin) -> Data {
    // Built natively so the page can never lie about type or origin.
    let object: [String: Any] = [
        "type": type,
        "challenge": b64url(challenge),
        "origin": origin.serialized,
        "crossOrigin": false,
    ]
    return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
}

private func performCreate(
    rpId: String, origin: WebAuthnOrigin, publicKey: [String: Any]
) throws -> [String: Any] {
    guard let challenge = b64urlDecode(publicKey["challenge"] as? String), !challenge.isEmpty else {
        throw WebAuthnCeremonyError.type("A challenge is required.")
    }
    let user = publicKey["user"] as? [String: Any] ?? [:]
    guard let userId = b64urlDecode(user["id"] as? String), !userId.isEmpty else {
        throw WebAuthnCeremonyError.type("A user id is required.")
    }
    let params = (publicKey["pubKeyCredParams"] as? [[String: Any]] ?? [])
        .compactMap { $0["alg"] as? Int }
    let exclude = (publicKey["excludeCredentials"] as? [[String: Any]] ?? [])
        .compactMap { b64urlDecode($0["id"] as? String) }

    let request = WebAuthnCreateRequest(
        challenge: challenge,
        rpId: rpId,
        rpName: (publicKey["rp"] as? [String: Any])?["name"] as? String,
        userId: userId,
        userName: user["name"] as? String ?? "",
        userDisplayName: user["displayName"] as? String ?? "",
        // An absent/empty list means "any" per spec registrations in the
        // wild; default to ES256 rather than failing them.
        algorithms: params.isEmpty ? [-7] : params,
        excludeCredentialIds: exclude
    )
    let clientData = clientDataJSON(type: "webauthn.create", challenge: challenge, origin: origin)
    let created = try WebAuthnSoftwareAuthenticator.create(rpId: rpId, request: request)

    return [
        "ok": true,
        "credential": [
            "responseKind": "attestation",
            "id": b64url(created.credentialId),
            "rawId": b64url(created.credentialId),
            "authenticatorAttachment": "platform",
            "clientExtensionResults": [String: Any](),
            "response": [
                "clientDataJSON": b64url(clientData),
                "attestationObject": b64url(created.attestationObject),
                "authenticatorData": b64url(created.authenticatorData),
                "publicKey": b64url(created.publicKeyDER),
                "publicKeyAlgorithm": -7,
                "transports": ["internal"],
            ],
        ],
    ]
}

private func performGet(
    rpId: String, origin: WebAuthnOrigin, publicKey: [String: Any]
) throws -> [String: Any] {
    guard let challenge = b64urlDecode(publicKey["challenge"] as? String), !challenge.isEmpty else {
        throw WebAuthnCeremonyError.type("A challenge is required.")
    }
    let allow = (publicKey["allowCredentials"] as? [[String: Any]] ?? [])
        .compactMap { b64urlDecode($0["id"] as? String) }
    let clientData = clientDataJSON(type: "webauthn.get", challenge: challenge, origin: origin)
    let assertion = try WebAuthnSoftwareAuthenticator.assert(
        rpId: rpId,
        request: WebAuthnGetRequest(challenge: challenge, rpId: rpId, allowCredentialIds: allow),
        clientDataJSON: clientData
    )
    return [
        "ok": true,
        "credential": [
            "responseKind": "assertion",
            "id": b64url(assertion.credentialId),
            "rawId": b64url(assertion.credentialId),
            "authenticatorAttachment": "platform",
            "clientExtensionResults": [String: Any](),
            "response": [
                "clientDataJSON": b64url(clientData),
                "authenticatorData": b64url(assertion.authenticatorData),
                "signature": b64url(assertion.signature),
                "userHandle": b64url(assertion.userHandle),
            ],
        ],
    ]
}

// MARK: - consent dialog

private final class WebAuthnConsentBox {
    let completion: (Bool) -> Void
    init(completion: @escaping (Bool) -> Void) { self.completion = completion }
}

private let webAuthnConsentResponse: @convention(c) (
    UnsafeMutableRawPointer?, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
) -> Void = { _, response, userData in
    guard let userData else { return }
    let box = Unmanaged<WebAuthnConsentBox>.fromOpaque(userData).takeUnretainedValue()
    let approved = response.map { String(cString: $0) == "approve" } ?? false
    box.completion(approved)
}

private let webAuthnConsentDestroy: GClosureNotify = { data, _ in
    guard let data else { return }
    Unmanaged<WebAuthnConsentBox>.fromOpaque(data).release()
}

private func presentWebAuthnConsentDialog(
    webView: UnsafeMutablePointer<WebKitWebView>,
    rpId: String,
    creating: Bool,
    userName: String?,
    completion: @escaping (Bool) -> Void
) {
    let title = creating ? "Create a passkey?" : "Sign in with your passkey?"
    var body = creating
        ? "\(rpId) wants to create a passkey on this device."
        : "\(rpId) wants to sign you in with a passkey stored on this device."
    if let userName, !userName.isEmpty {
        body += "\nAccount: \(userName)"
    }
    guard let dialog = adw_alert_dialog_new(title, body) else {
        completion(false)
        return
    }
    let alert = UnsafeMutableRawPointer(dialog).assumingMemoryBound(to: AdwAlertDialog.self)
    adw_alert_dialog_add_response(alert, "cancel", "Cancel")
    adw_alert_dialog_add_response(alert, "approve", creating ? "Create Passkey" : "Sign In")
    adw_alert_dialog_set_response_appearance(alert, "approve", ADW_RESPONSE_SUGGESTED)
    adw_alert_dialog_set_default_response(alert, "approve")
    adw_alert_dialog_set_close_response(alert, "cancel")

    let box = Unmanaged.passRetained(WebAuthnConsentBox(completion: completion)).toOpaque()
    g_signal_connect_data(
        UnsafeMutableRawPointer(dialog), "response",
        unsafeBitCast(webAuthnConsentResponse, to: GCallback.self),
        box, webAuthnConsentDestroy, GConnectFlags(0)
    )
    let dialogPtr = UnsafeMutableRawPointer(dialog).assumingMemoryBound(to: AdwDialog.self)
    let parent = UnsafeMutableRawPointer(webView).assumingMemoryBound(to: GtkWidget.self)
    adw_dialog_present(dialogPtr, parent)
}

// MARK: - reply helpers

private func returnWebAuthnJSON(
    _ reply: OpaquePointer, context: OpaquePointer?, object: [String: Any]
) {
    guard let context,
          let data = try? JSONSerialization.data(withJSONObject: object),
          let json = String(data: data, encoding: .utf8),
          let value = jsc_value_new_string(context, json) else { return }
    webkit_script_message_reply_return_value(reply, value)
    g_object_unref(UnsafeMutableRawPointer(value))
}

private func returnWebAuthnError(
    _ reply: OpaquePointer, context: OpaquePointer?, name: String, message: String
) {
    returnWebAuthnJSON(reply, context: context, object: [
        "ok": false,
        "error": ["name": name, "message": message],
    ])
}

// MARK: - the page-world polyfill

/// Defines the WebAuthn API surface. Runs before any page script
/// (document-start), top frame only, secure contexts only. Serialization
/// and hydration mirror the macOS bridge script so the native payloads
/// stay identical across ports.
private let browserWebAuthnUserScript = """
(() => {
  if (window.isSecureContext !== true) return;
  if (window.self !== window.top) return;
  if (window.__cmuxWebAuthnInstalled) return;
  if (typeof navigator.credentials !== "undefined") return;
  window.__cmuxWebAuthnInstalled = true;

  const handlerName = "\(BrowserWebAuthn.handlerName)";
  const maximumPayloadBytes = 512 * 1024;

  const bytesView = (value) => {
    if (value instanceof ArrayBuffer) return new Uint8Array(value);
    if (ArrayBuffer.isView(value)) {
      return new Uint8Array(value.buffer, value.byteOffset, value.byteLength);
    }
    return null;
  };
  const base64UrlEncode = (value) => {
    const bytes = bytesView(value);
    if (!bytes) return null;
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary).replace(/\\+/g, "-").replace(/\\//g, "_").replace(/=+$/g, "");
  };
  const base64UrlDecode = (value) => {
    if (typeof value !== "string") return null;
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized.length % 4 === 0
      ? normalized
      : normalized + "=".repeat(4 - (normalized.length % 4));
    const binary = atob(padded);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  };
  const normalizedString = (v) => (typeof v === "string" ? v.trim().toLowerCase() : "");
  const makeError = (name, message) => {
    const safeName = name || "UnknownError";
    const safeMessage = message || "The passkey request failed.";
    if (safeName === "TypeError") return new TypeError(safeMessage);
    try { return new DOMException(safeMessage, safeName); }
    catch (_) { const e = new Error(safeMessage); e.name = safeName; return e; }
  };

  const callNative = (kind, payload) => {
    let handler = null;
    try {
      const handlers = window.webkit && window.webkit.messageHandlers;
      handler = handlers && handlers[handlerName];
    } catch (_) {}
    if (!handler || typeof handler.postMessage !== "function") {
      return Promise.reject(makeError("NotSupportedError", "Passkey support is unavailable."));
    }
    const message = JSON.stringify(payload === undefined ? { kind } : { kind, payload });
    if (message.length > maximumPayloadBytes) {
      return Promise.reject(makeError("TypeError", "Malformed passkey request."));
    }
    return handler.postMessage(message).then((raw) => {
      let reply = null;
      try { reply = JSON.parse(raw); } catch (_) {}
      if (reply && reply.ok === true) return reply;
      const error = (reply && reply.error) || {};
      throw makeError(error.name, error.message);
    });
  };

  // ---- API surface -------------------------------------------------

  function PublicKeyCredential() {
    throw new TypeError("Illegal constructor");
  }
  PublicKeyCredential.isUserVerifyingPlatformAuthenticatorAvailable = () =>
    callNative("capabilities")
      .then((r) => !!(r.capabilities || {}).userVerifyingPlatformAuthenticatorAvailable)
      .catch(() => false);
  PublicKeyCredential.isConditionalMediationAvailable = () => Promise.resolve(false);

  function AuthenticatorResponse() { throw new TypeError("Illegal constructor"); }
  function AuthenticatorAttestationResponse() { throw new TypeError("Illegal constructor"); }
  function AuthenticatorAssertionResponse() { throw new TypeError("Illegal constructor"); }
  Object.setPrototypeOf(AuthenticatorAttestationResponse.prototype, AuthenticatorResponse.prototype);
  Object.setPrototypeOf(AuthenticatorAssertionResponse.prototype, AuthenticatorResponse.prototype);
  function CredentialsContainer() { throw new TypeError("Illegal constructor"); }

  const serializeCredentialDescriptor = (descriptor) => {
    if (!descriptor) return null;
    const encodedID = base64UrlEncode(descriptor.id);
    if (!encodedID) return null;
    return { type: normalizedString(descriptor.type) || "public-key", id: encodedID };
  };

  const serializeCreateRequest = (options) => {
    const publicKey = (options && options.publicKey) || {};
    const rp = publicKey.rp || {};
    const user = publicKey.user || {};
    return {
      publicKey: {
        challenge: base64UrlEncode(publicKey.challenge),
        rp: { id: normalizedString(rp.id) || undefined,
              name: typeof rp.name === "string" ? rp.name : undefined },
        user: {
          id: base64UrlEncode(user.id),
          name: typeof user.name === "string" ? user.name : undefined,
          displayName: typeof user.displayName === "string" ? user.displayName : undefined,
        },
        pubKeyCredParams: Array.isArray(publicKey.pubKeyCredParams)
          ? publicKey.pubKeyCredParams
              .map((p) => ({ type: normalizedString(p && p.type) || "public-key",
                             alg: Number(p && p.alg) }))
              .filter((p) => Number.isFinite(p.alg))
          : [],
        excludeCredentials: Array.isArray(publicKey.excludeCredentials)
          ? publicKey.excludeCredentials.map(serializeCredentialDescriptor).filter(Boolean)
          : undefined,
      },
    };
  };

  const serializeGetRequest = (options) => {
    const publicKey = (options && options.publicKey) || {};
    return {
      publicKey: {
        challenge: base64UrlEncode(publicKey.challenge),
        rpId: normalizedString(publicKey.rpId) || undefined,
        allowCredentials: Array.isArray(publicKey.allowCredentials)
          ? publicKey.allowCredentials.map(serializeCredentialDescriptor).filter(Boolean)
          : undefined,
      },
    };
  };

  const buildAttestationResponse = (serialized) => {
    const transports = Array.isArray(serialized.transports) ? [...serialized.transports] : [];
    const authenticatorData = serialized.authenticatorData
      ? base64UrlDecode(serialized.authenticatorData) : null;
    const publicKey = serialized.publicKey ? base64UrlDecode(serialized.publicKey) : null;
    const algorithm = Number.isFinite(serialized.publicKeyAlgorithm)
      ? serialized.publicKeyAlgorithm : null;
    const response = {
      clientDataJSON: base64UrlDecode(serialized.clientDataJSON),
      attestationObject: base64UrlDecode(serialized.attestationObject),
      getAuthenticatorData() { return authenticatorData; },
      getPublicKey() { return publicKey; },
      getPublicKeyAlgorithm() { return algorithm; },
      getTransports() { return [...transports]; },
      toJSON() {
        return {
          clientDataJSON: serialized.clientDataJSON,
          attestationObject: serialized.attestationObject,
          transports: [...transports],
        };
      },
    };
    Object.setPrototypeOf(response, AuthenticatorAttestationResponse.prototype);
    return response;
  };

  const buildAssertionResponse = (serialized) => {
    const response = {
      clientDataJSON: base64UrlDecode(serialized.clientDataJSON),
      authenticatorData: base64UrlDecode(serialized.authenticatorData),
      signature: base64UrlDecode(serialized.signature),
      userHandle: serialized.userHandle ? base64UrlDecode(serialized.userHandle) : null,
      toJSON() {
        return {
          clientDataJSON: serialized.clientDataJSON,
          authenticatorData: serialized.authenticatorData,
          signature: serialized.signature,
          userHandle: serialized.userHandle || null,
        };
      },
    };
    Object.setPrototypeOf(response, AuthenticatorAssertionResponse.prototype);
    return response;
  };

  const hydrateCredential = (serialized) => {
    const response = serialized.responseKind === "attestation"
      ? buildAttestationResponse(serialized.response || {})
      : buildAssertionResponse(serialized.response || {});
    const credential = {
      type: "public-key",
      id: serialized.id,
      rawId: base64UrlDecode(serialized.rawId),
      authenticatorAttachment: serialized.authenticatorAttachment || null,
      response,
      getClientExtensionResults() { return {}; },
      toJSON() {
        return {
          id: serialized.id,
          rawId: serialized.rawId,
          type: "public-key",
          authenticatorAttachment: serialized.authenticatorAttachment || null,
          response: response.toJSON(),
          clientExtensionResults: {},
        };
      },
    };
    Object.setPrototypeOf(credential, PublicKeyCredential.prototype);
    return credential;
  };

  const credentials = {
    create(options) {
      if (!options || !options.publicKey) {
        return Promise.reject(makeError("NotSupportedError",
          "Only public-key credentials are supported."));
      }
      return callNative("createCredential", serializeCreateRequest(options))
        .then((reply) => hydrateCredential(reply.credential));
    },
    get(options) {
      if (!options || !options.publicKey) {
        return Promise.reject(makeError("NotSupportedError",
          "Only public-key credentials are supported."));
      }
      return callNative("getCredential", serializeGetRequest(options))
        .then((reply) => hydrateCredential(reply.credential));
    },
    store() {
      return Promise.reject(makeError("NotSupportedError", "store() is not supported."));
    },
    preventSilentAccess() { return Promise.resolve(); },
  };
  Object.setPrototypeOf(credentials, CredentialsContainer.prototype);

  window.PublicKeyCredential = PublicKeyCredential;
  window.AuthenticatorResponse = AuthenticatorResponse;
  window.AuthenticatorAttestationResponse = AuthenticatorAttestationResponse;
  window.AuthenticatorAssertionResponse = AuthenticatorAssertionResponse;
  window.CredentialsContainer = CredentialsContainer;
  Object.defineProperty(Navigator.prototype, "credentials", {
    configurable: true,
    enumerable: true,
    get() { return credentials; },
  });
})();
"""
