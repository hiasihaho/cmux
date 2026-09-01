# Passkeys / WebAuthn for the Linux port — options analysis

Status: **analysis / proposal — nothing implemented, nothing decided.**
Date: 2026-09-01. Companion to GAPS.md (browser-pane parity) and PORTING.md.

macOS cmux shipped passkey support in browser panes
(https://cmux.com/blog/passkey-auth, v0.64): login flows with passkeys,
Touch ID and hardware keys work inside a cmux pane, framed explicitly as
"agents can test authenticated local apps without leaving cmux". On macOS
this is nearly free — WKWebView inherits Apple's WebAuthn client and the
iCloud Keychain platform authenticator. On Linux none of that exists. This
document maps the possibility space and recommends a path.

## 1. Ground truth (verified on this host, 2026-09-01)

- **WebKitGTK exposes no WebAuthn to pages.** Probed a live cmux browser
  pane (WebKitGTK 2.52.4, Fedora 43): `navigator.credentials` is
  `undefined`, as are `PublicKeyCredential`, `CredentialsContainer`,
  `AuthenticatorResponse`. The runtime feature list (489 features via
  `webkit_settings_get_all_features`) contains no WebAuthn/FIDO toggle,
  and no `WebAuthenticationEnabled` preference string exists in the
  library — there is nothing to switch on from the embedder API.
  Upstream tracker: https://bugs.webkit.org/show_bug.cgi?id=205350
  ("[WPE][GTK] Support WebAuthn", open since 2019). This is why Epiphany
  has no passkeys either (GNOME/epiphany#1007).
- **…but the machinery is compiled into this build.** Verified on
  `/lib64/libwebkitgtk-6.0.so.4`: it links `libhidapi-hidraw` (the CTAP
  USB transport), contains the WebAuthn class names internally (no
  dynamic exports), and — crucially — contains all six **W3C WebDriver
  virtual-authenticator endpoints** (`addVirtualAuthenticator`,
  `addVirtualAuthenticatorCredential`, `getVirtualAuthenticatorCredentials`,
  `setVirtualAuthenticatorUserVerified`, `removeVirtualAuthenticator*`).
  `/usr/bin/WebKitWebDriver` ships in the same Fedora package. Hypothesis
  to probe (P0 below): WebAuthn lights up for pages inside a WebDriver
  automation session, backed by virtual authenticators. What the build
  definitely lacks is any consent UI (no panel/dialog strings) and any
  embedder API to drive ceremonies — so even in the best case the native
  path covers testing, not user-facing passkeys.
- Host has `libfido2` 1.16 installed, and gnome-keyring exposes
  `org.freedesktop.secrets` (Secret Service) on the session bus — usable
  for encrypted credential storage.
- `swift-crypto` is already a dependency of the Linux port
  (`linux/Package.swift:59`) — gives us P-256 / ES256, the mandatory
  WebAuthn algorithm.
- Browser panes already have a generic JS execution + automation surface
  (eval/snapshot/actions/…), i.e. the injection plumbing a WebAuthn
  client needs already exists in some form (see §5).

## 2. The key insight: two halves, and which one we lack

Every passkey stack splits into:

1. **WebAuthn client** (the browser half): exposes
   `navigator.credentials.create/get`, builds `clientDataJSON`, binds the
   request to the **origin**, enforces rpId rules, runs the consent UI,
   talks to authenticators. Chrome/Firefox/Safari each ship one.
   **WebKitGTK ships none. This is our gap.**
2. **Authenticator** (the key-custody half): holds the private keys, does
   user presence/verification, signs. Can be a USB security key, a phone
   (hybrid/QR "caBLE"), a TPM-backed platform authenticator, or a
   software vault (what Proton Pass / Bitwarden / 1Password passkeys are).

The two projects from the prompt are both **authenticators**, not clients:

- **matejsmycka/linux-id** (Go, MIT, ~70★): TPM-backed software
  authenticator that emulates a **USB HID FIDO device via uhid**, so any
  browser that already speaks CTAP-over-USB (Chromium, Firefox) sees it
  as a plugged-in security key. pinentry/fprintd for consent.
- **bjn7/passkeyd** (Rust, GPL-3, ~63★): daemon + manager UI + storage,
  TPM optional, packaged for Arch/Ubuntu; same category.

Both presuppose a browser with a working, page-exposed CTAP client.
**WebKitGTK exposes none to pages** (its compiled-in CTAP code is
unreachable outside automation, §1), so adopting either would give cmux
panes exactly nothing
until we build the client half anyway — and once we have the client half,
a D-Bus/native backend is strictly simpler and richer than tunneling
CTAP through a fake USB device. They remain useful as prior art
(TPM sealing, consent UX) and as system-wide companions, not as our
integration point.

## 3. The landscape (who else is solving this)

- **linux-credentials / credentialsd** (https://github.com/linux-credentials/credentialsd,
  LGPL, FOSDEM 2026 talk "Credentials for Linux"): the serious platform
  play. A D-Bus service (`xyz.iinuwa.credentialsd.Credentials` +
  `.UiControl`) proposed as a future **xdg credentials portal**, built on
  their Rust `libwebauthn` (USB support done, phone/hybrid in progress,
  TPM platform authenticator planned). Ships a reference UI, OBS packages
  (Fedora/openSUSE), and — tellingly — their only browser integrations
  today are a **web extension that overrides `navigator.credentials`**
  (Firefox/Chromium) plus a patched Firefox build. I.e. the exact
  polyfill-and-bridge architecture we would build natively. No
  WebKitGTK/WPE integration exists; nobody has claimed it. Funding fell
  through in 2025; it advances on nights-and-weekends pace.
- **Proton Pass model**: browser extension intercepts WebAuthn calls,
  software authenticator inside the encrypted vault, attestation `none`,
  passkeys travel wherever the vault is. Proton needs a server for sync;
  the interception + vault architecture itself is serverless.
- **Portability standard**: FIDO **CXF** (Credential Exchange Format,
  Proposed Standard Aug 2025) + **CXP** (transfer protocol, standardizing
  early 2026; Apple shipped CXF-based transfer in macOS/iOS 26, Android
  supports CXP via Play Services). This is the sanctioned way passkeys
  move between vaults — directly relevant to any "vault that travels".

## 4. Option space

**A. Wait for / implement WebAuthn in WebKitGTK upstream.**
The architecturally pure fix; benefits every WebKitGTK app. Six years of
no momentum on bug 205350 — but §1 shrinks the true upstream gap: the
WebAuthn core + CTAP-over-hidraw transport already compile into the GTK
port; what's missing is the preference/IDL exposure, an embedder-facing
ceremony/consent API, and UI. That is a much smaller (though still C++,
still WebKit-release-cycle) contribution than "implement WebAuthn".
Not schedulable as our plan of record; worth reporting our findings and
prior art (B) on the bug either way.

**F. WebDriver virtual authenticator — PROBED 2026-09-01: REFUTED.**
`linux/tests/webauthn-probe.sh` (attach mode, isolated instance) found:
(1) `POST /session/<id>/webauthn/authenticator` → `unknown command` —
`/usr/bin/WebKitWebDriver` contains **zero** webauthn strings (the 14
`VirtualAuthenticator` strings live in libwebkitgtk's internal
automation backend; the REST→Automation mapping isn't compiled into the
GTK driver front-end); (2) even inside a live automation session the
page still sees `navigator.credentials: undefined`, so the runtime
feature is off regardless. The native path is dead in this build on both
ends. Consequence: **B is the only viable path**, and it should carry
its own virtual-authenticator/testing story (option C's dev verbs).

**B. Build the WebAuthn client inside cmux browser panes.** ⭐ load-bearing
Inject `navigator.credentials` / `PublicKeyCredential` at document-start
via a user script; bridge `create()`/`get()` through script message
handlers into Swift; Swift owns origin/rpId validation (from the trusted
`webkit_web_view` URI, never from page data), consent UI, and dispatch to
a **pluggable authenticator backend**. This is what credentialsd's
extension does for Firefox — we can do it better because we own the
embedder: native GTK consent dialogs, trusted-origin plumbing, agent
policy hooks. Everything else composes behind this.

**C. Backend #1: built-in software authenticator + local encrypted vault.**
ES256 keypair per credential (swift-crypto), WebAuthn-conformant
`authenticatorData`/attestation-object assembly (attestation `none`, like
every password-manager passkey), CBOR encoding (small, self-written),
vault encrypted at rest with the key in gnome-keyring (Secret Service),
file fallback. Works **headless** — which is the cmux-native superpower:
agents and dogfood/scratch instances can complete passkey ceremonies
under policy, and we can expose a Chrome-DevTools-style *virtual
authenticator for development* (`cmux browser webauthn …`) that no GTK
webview offers today. Caveat to state honestly: software passkeys carry
no hardware attestation; a minority of strict/enterprise RPs reject them
(the same trade-off Proton/Bitwarden accepted).

**D. Backend #2: credentialsd (system authenticators).**
When `xyz.iinuwa.credentialsd.Credentials` is on the bus, offer it as the
"system" choice in the ceremony picker: real USB security keys and —
once libwebauthn lands it — phone hybrid/QR, with the system's own UI.
This makes cmux **the first webview/browser shipping native integration
with the proposed Linux credentials portal** — a genuine contribution
the linux-credentials folks can point at, and our hedge: if the portal
becomes the GNOME/KDE standard, we're already speaking it; our vault (C)
can later register as a third-party provider behind it (their stated
roadmap mirrors Android/Windows provider APIs).

**E. Expose the cmux vault system-wide (other apps / other browsers).**
Two routes: uhid CTAP emulation (linux-id's trick — root/udev perms, a
full CTAP2 stack, fake-USB indirection) or registering as a credentialsd
third-party provider once that API exists. The second is clearly better
and costs almost nothing *if* C and D exist. Defer; do not build uhid.

**P2P vault sync (the qmp/hypercore angle).**
The qmp project (~/qmp) is building identity/attestation/room primitives
over Hypercore-family replication with hole-punching. A passkey vault is
"just" a small, high-value encrypted document — syncing it over an
authenticated P2P room would be a **serverless Proton Pass**: passkeys
that travel wherever your qmp identity does, no vendor server. That is a
real differentiator and a natural phase-3 experiment, with two
disciplines attached: the vault crypto must not depend on transport
security (encrypt-before-replicate, key never in the room), and
import/export should speak **CXF** so the vault is never a lock-in trap.
Not on the critical path; C's vault format should merely be designed so
a sync layer can attach later (content-addressed, versioned, mergeable).

## 5. What we already have to build on (code-level)

Findings from a full sweep of `linux/Sources/` (2026-09-01):

- **The injection pattern exists and runs on every browser surface.**
  `installBrowserConsoleCapture` (`BrowserAutomation.swift:628-672`,
  called unconditionally from `BrowserSurfaces.swift:169`) is a complete
  worked example: document-start user script + `script-message-received::`
  handler + `postMessage` payload. A `cmuxWebAuthn` channel is a ~40-line
  copy of that shape. Two current constraints to lift for WebAuthn:
  the handler registers in the **main world** (world arg `nil`) and the
  script injects `WEBKIT_USER_CONTENT_INJECT_TOP_FRAME` only.
- **Isolated script worlds are already exercised** — the CSP fallback
  world `cmuxAutomation` (`BrowserAutomation.swift:118`, `:205-210`), so
  the macOS design (relay in page world, logic in a `cmux.webauthn`
  world) maps 1:1 via
  `webkit_user_content_manager_register_script_message_handler` with a
  world name.
- **macOS is the blueprint, not just prior art.**
  `Sources/Panels/BrowserWebAuthnSupport.swift` (1,866 lines) + 19
  `BrowserWebAuthn*` model/parser files (~2,500 lines): page-world relay
  script overriding `navigator.credentials.create/get`, dedicated
  `WKContentWorld("cmux.webauthn")`, reply-capable `cmuxWebAuthn`
  handler, coordinator bridging to `ASAuthorizationController`. The
  relay script and the WebAuthn JSON model/parsing layers are
  platform-neutral Swift/JS and look substantially reusable; only the
  `ASAuthorization` coordinator needs a Linux counterpart (our backend
  layer, §4 C/D). This mirrors how `CLI/cmux.swift` is shared today.
- **Verb plumbing is a solved problem**: socket dispatch
  (`ControlProtocol.swift:325+`), `BrowserJS.run` single JS entry point,
  per-surface targeting — a `browser.webauthn.*` verb family slots in
  like cookies/storage did.
- **WebDriver opt-in already hands real panes to the driver**
  (`BrowserWebDriver.swift:118-172`) — the lever for option F.
- **Per-profile isolation comes free**: credential/vault state can key
  off the existing profile system (`BrowserProfiles.swift:288-303` —
  per-profile `WebKitNetworkSession` dirs, per-pane ephemeral sessions).
- **Gaps to be honest about**: there is **no** permission-request,
  HTTP-auth, or TLS-error handling anywhere in the Linux browser stack
  yet (greenfield, though the signal-connection idiom is used 4×); no
  secret storage abstraction exists on Linux (the only cross-platform
  store is the CLI's 0600 plaintext socket-password file) — the vault's
  Secret Service integration is new code; and the port cannot produce
  trusted input/user activation (documented at
  `BrowserAutomation.swift:1301-1303`), which matters for RPs that gate
  WebAuthn calls on user gestures.

## 6. Security discipline (non-negotiables for B/C)

- **Origin truth lives in Swift.** rpId validation against the effective
  origin from the WebKit API; page-supplied strings are requests, not
  facts. Same rule as the macOS WebAuthn client.
- **Consent UI is native and unspoofable** — a GTK dialog showing rpId +
  action, never page-rendered chrome. User presence = explicit click;
  user verification = system-auth step (passphrase prompt, later
  fprintd), and the UP/UV flags in `authenticatorData` must report what
  actually happened.
- **Agent policy is explicit.** Default: a human approves each ceremony
  (the request lights up the attention pipeline like any notification).
  Per-origin standing grants and a localhost/dev-mode auto-approve are
  opt-in settings — this is where "agents test authed apps" becomes real
  without turning the vault into an agent-exfiltratable secret store.
- **Scope v1 to top-level frames**; cross-origin-iframe WebAuthn
  (permissions-policy semantics) only after the base is solid.
- Page-world tampering (a page deleting/wrapping our polyfill) only
  breaks that page — but the bridge must treat every message as
  untrusted input regardless of which world it claims to come from.

## 7. Recommended path

0. **Probe P0 — DONE 2026-09-01, verdict REFUTED** (see option F).
   Probe script kept at `linux/tests/webauthn-probe.sh`; it will be
   repurposed as the regression suite for the P1 client layer (same
   fixture, our polyfill instead of the driver's virtual authenticator).
1. **Increment P1 — client layer + software authenticator** (B + C),
   behind a build/runtime flag. Exit criterion: register + sign in on
   webauthn.io and demo.yubico.com in a dogfood cycle; `cmux browser`
   gains a `webauthn` verb group for the dev virtual authenticator.
2. **Increment P2 — credentialsd backend + picker** (D). Detect the bus
   name, add "use system authenticator" to the ceremony dialog; file the
   WebKitGTK prior-art note on bug 205350 and say hello to
   linux-credentials (Matrix: #credentials-for-linux).
3. **Increment P3 — portability**: CXF export/import; then the qmp
   P2P-sync experiment against a disposable vault.
4. **Explicit non-goals**: no uhid device emulation, no own CTAP stack,
   no server-side component, no attestation forgery (attestation is
   `none`, honestly).

Ordering rationale: P1 alone reaches feature-parity headline with the
macOS blog post *and* unlocks the agent story; P2 turns a cmux feature
into a Linux-ecosystem contribution; P3 is where the "passkeys travel in
your own p2p vault" vision lives, safely decoupled from the base.
