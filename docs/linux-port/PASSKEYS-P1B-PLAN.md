# Passkeys P1b — completion plan (vault encryption-at-rest)

Status: **in progress, staged but not folded in.** P1b is the next increment
after P1a (the shipped, webauthn.io-verified client layer + ES256 software
authenticator behind `CMUX_WEBAUTHN=1`). Owner: pk3. Reviewer: passkey desk
(pk). This plan is written the evening before the work resumes; nothing here
is in the daily binary yet, and folding it in is a separate, announced
promote that hias approves.

Context and prior decisions: [PASSKEYS.md](PASSKEYS.md) (option analysis,
P0 refutation), GAPS.md "Passkeys P1b–P3" row (the adopted route and
owners), the red-suite commit `da5f0f8e59`.

## 1. What P1b is

Encrypt the resident-credential vault at rest. Today the vault is 0600
plaintext JSON (`WebAuthnVault` in `linux/Sources/CmuxAdw/WebAuthnAuthenticator.swift`).
P1b puts AES-GCM encryption behind a **vault-key provider** with two
backends, keeping `WebAuthnVault.load`/`save` as the only seam:

- **host backend** — a random 32-byte key stored as a gnome-keyring item via
  `secret-tool` (which talks `org.freedesktop.secrets` on the session bus, so
  no direct D-Bus code on the host path).
- **flatpak backend** — the Secret **portal** (`org.freedesktop.portal.Secret`
  / `RetrieveSecret`): a per-app master secret read over a pipe fd, expanded
  to 32 bytes with HKDF-SHA256. No keyring-wide access, no
  `--talk-name=org.freedesktop.secrets` finish-arg. Verified activatable on
  this host.
- **no backend** — honest logged fallback: the vault stays 0600 plaintext
  with one warning per process, never silent.

On-disk format is a v2 JSON envelope `{version:2, backend, nonce,
ciphertext}` — the envelope is JSON by design; the *plaintext* is not
recoverable from it. A v1 plaintext vault migrates in place on first load,
keeping a `.v1.bak` until the first successful decrypt-read retires it.

Backend selection: `CMUX_WEBAUTHN_KEY_BACKEND=host|portal|none` forces a
backend (suites need determinism); unset = auto (portal under flatpak /
`FLATPAK_ID`, host otherwise, none when the host lookup fails).

## 2. Current state (measured 2026-09-01 late)

- **Red suite committed and pushed** (`da5f0f8e59`): `webauthn-smoke`
  extended 10 → 16 assertions (ciphertext-at-rest, migration, fallback),
  ledger bumped in the same commit. Red as expected.
- **Implementation staged in `stash@{0}`** (384 lines, 3 files:
  `WebAuthnVaultKeyProvider.swift` new, `WebAuthnAuthenticator.swift` vault
  seam, `webauthn-smoke.sh`). It was stashed, not committed, because it still
  carried **diagnostic debug prints** from a debugging round — correctly kept
  out of the daily binary.
- **Proven working by direct test** (outside the suite): with the host
  backend, `create()` wrote a v2 envelope (`backend:"host"`, ciphertext, no
  readable `credentials`), the key was found in gnome-keyring
  (`host lookup -> value`), and the post-reload assertion ceremony passed —
  i.e. decrypt + sign round-trips.
- **Known gap: the migration suite leg is red**, and it is a
  *suite-orchestration* bug, not a code bug — the migration phase's instance
  restart + `#get` click was not reliably triggering `load()` before the
  assertion read the vault. Switched to a deterministic `eval`-driven
  ceremony with a poll; needs one clean red→green run to confirm.

## 3. Completion steps (in order)

1. **Restore the stash** onto a fresh branch; **remove the debug prints**
  (`load() from…`, `resolve() selection=…`, `host lookup/store…`). They were
  scaffolding, not product.
2. **Green the migration leg** — confirm the `eval`-driven trigger + poll
  makes the migration assertions pass deterministically (no fixed sleeps,
  per lib.sh's "poll, don't sleep").
3. **Full suite green** (16/16), same-commit docs: PROGRESS (evidence +
   traps), GAPS (row update), PARITY, suites.tsv (ledger 10 → 16).
4. **Push, hand to pk for review** per the adopted route. pk holds review,
   then verbs, then credentialsd.
5. **Folding into a promote is hias's checkpoint** — announced, never forced.
   The feature stays behind `CMUX_WEBAUTHN=1` (off by default) regardless,
   until hias flips it.

## 4. Open item to settle with pk (not tonight)

The **flatpak Secret-portal backend is written but not suite-verified** —
only the host (gnome-keyring) path has coverage. Honest coverage requires a
flatpak-sandbox test (the portal only answers inside the sandbox). Options:
a flatpak-leg suite, or a documented manual verification step. Decide with pk
before P1b is called done; do not claim portal coverage we have not run.

## 5. Security invariants carried forward (do not weaken)

From `BrowserWebAuthn.swift`'s header, unchanged by P1b: origin truth lives
in Swift (never page data); the consent dialog IS the security boundary;
`CMUX_WEBAUTHN_AUTOAPPROVE` is suites/dev only and must never appear in a
manifest or default. P1b adds: the vault key never touches disk outside the
keyring/portal, and the plaintext vault never touches disk when a backend
answers.
