# CONCLUSION — 2026-09-01 20:21 CEST — passkey desk

## 1. What I worked on

**Passkeys for the Linux port: from question to shipped feature in one
day.** hias asked whether the macOS passkey feature (blog, v0.64) could
have a Linux counterpart, referencing linux-id and passkeyd.

- **Analysis** (`dc93b7fd89`, `docs/linux-port/PASSKEYS.md`): the option
  space, verified on this host. Key finding: linux-id/passkeyd are
  *authenticators* presupposing a browser CTAP client; WebKitGTK ships
  no client, so they alone give panes nothing. credentialsd
  (linux-credentials, FOSDEM 2026) is the emerging xdg-portal play;
  FIDO CXF is the sanctioned portability format for the eventual
  qmp/P2P vault idea.
- **P0 probe** (`9747bb297f`, half an hour): refuted the "near-free"
  WebDriver virtual-authenticator path with forensics — the driver
  front-end has zero webauthn strings while libwebkitgtk carries 14
  `VirtualAuthenticator` strings; pages in automation sessions still see
  no `navigator.credentials`. Both ends closed ⇒ polyfill is the only
  path. Probe kept, later grown into the gate suite.
- **P1a shipped** (`19e65e9b52`), behind `CMUX_WEBAUTHN=1`:
  `BrowserWebAuthn.swift` (page-world polyfill + reply-capable
  `cmuxWebAuthn` handler; origin truth from `webkit_web_view_get_uri`,
  rpId validation, AdwAlertDialog consent) and
  `WebAuthnAuthenticator.swift` (ES256 via swift-crypto, hand-rolled
  canonical CBOR, attestation `none`, resident keys, 0600 vault,
  signCount 0). Wire protocol identical to macOS's
  `BrowserWebAuthnSupport` so the ports stay conceptually one.
- **Proof**: `webauthn-smoke.sh` 10/10 (incl. an in-suite Python relying
  party verifying the ES256 signature against the attested COSE key) and
  `webauthn-live.sh` — **webauthn.io registered and authenticated us
  live** ("You're logged in!", transports `['internal']`, zero AAGUID).
  WebKitGTK panes in cmux now do passkeys before Epiphany does.
- **Cross-desk exchange** with the cmux desk (workstreams
  `announce-passkey-cmux` / `announce-cmux-desk`): learned notify is the
  human channel and my notify would have self-delivered on macOS
  (#7939 — desk recorded the deviation, `38a6dc7720`, and decided the
  fix: keep follow-the-surface, fix the CLI's param conflation
  upstream; I conceded my resolver-side vote). Answered their flatpak
  question (`4a2486ad0e`), took their in-sandbox correction — the
  settings flip lands in the per-app `$XDG_CONFIG_HOME`, not
  `~/.config` (`3c15a27ae0`) — and banked a doorbell near-miss into the
  feed skill: idle is not ring-safe unless the input box is EMPTY
  (`fab54f1013`; hias's parked draft was sitting in the desk's prompt).

## 2. Time, with machine evidence

One session, ~17:00–20:21 CEST (first analysis commit `dc93b7fd89`
through `fab54f1013`; feed letters 17:17Z/17:23Z; webauthn.io ceremony
timestamps in `/tmp` suite logs during the run). Eight commits pushed to
`hiasihaho/cmux` `linux-port`, all with same-commit docs (PASSKEYS,
PROGRESS ×2, PARITY, GAPS ×2, CATCHUP, suites.tsv).

## 3. Handed to tomorrow, with owners

- **P1b vault encryption** (passkey desk): key-provider with two
  backends — gnome-keyring item on host, Secret **portal** under
  flatpak (decided over a blunt talk-name; GAPS row has the design).
  BLOCKED for the settings-flip half on the cmux desk's config-
  resolution row (below). Env-flag interim stands.
- **Flatpak config resolution** (cmux desk, their row `adce6eedc8`):
  prefer host `~/.config/cmux/cmux.json` under `FLATPAK_ID`; hias's
  approval was in their prompt box when I looked.
- **#7939 two-part fix** (cmux desk row; shared-CLI half is an upstream
  candidate): explicit `--workspace` without `--surface` must not
  attach the caller's surface.
- **Dogfood** (hias, no rush): `CMUX_WEBAUTHN=1 linux/scripts/start.sh
  dev`, open webauthn.io — real consent dialogs, feature dormant in the
  daily until the next promotion hias approves.
- **P1c+** (passkey desk, ordered in GAPS): `cmux browser webauthn`
  verbs, credentialsd backend (real USB keys — a talk-name, not
  `--device=all`), account picker, CXF export, qmp P2P vault experiment.

## 4. One lesson

**Half a day of disciplined refutation is what made one day of building
possible.** The P0 probe looked skippable — the polyfill was always the
likely answer — but killing the native path with forensics (not vibes)
meant zero hedging in the implementation, and the probe's fixture became
the regression suite. The same shape twice more today: the suite that
"failed for unrelated-looking reasons" was a stranger on port 8443, and
the notify that "worked" was a macOS self-delivery waiting to happen.
The cheap empirical check before the plausible conclusion paid all
three times.
