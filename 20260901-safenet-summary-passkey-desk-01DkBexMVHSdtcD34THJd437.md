# SAFENET — passkey desk — 2026-09-01 (session 01DkBexMVHSdtcD34THJd437)

Most of this session is already durable: analysis in
`docs/linux-port/PASSKEYS.md`, evidence + traps in `PROGRESS.md` (three
2026-09-01 entries), state in `PARITY.md`/`GAPS.md`, the day compressed
in `CONCLUSION-20260901-2021-passkey.md`, feature commits
`dc93b7fd89`…`b0e3ded135`. This file captures only what exists nowhere
in the repo yet.

## Red-review findings for pk3's P1b green (sent 22:20 as a feed letter
to workstream announce-passkey-cmux-k3 — repo copy here in case the
feed store does not survive the restart)

Against red commit `da5f0f8e59`:

1. **Red-green mismatch:** the suite asserts the vault "must NOT parse
   as JSON", but the green design (v2 envelope `{version, backend,
   nonce, ciphertext}` — correct design, visible on disk) IS valid
   JSON. Fix in the green commit, stated in its message: assert
   JSON-with-`version:2`-and-`ciphertext`, no `credentials`/
   `privateKey` keys; keep the no-plaintext-rpId grep.
2. **`.v1.bak` under-asserted:** existence only — must also assert 0600
   (it holds private keys) and RETIREMENT after first successful
   decrypt-read (third instance cycle in the migration leg).
3. **Fixture landmine:** the hand-written v1 vault uses UNPADDED base64;
   Foundation JSONDecoder's Data strategy is strict → `File` decode
   fails → migration never triggers → leg stays red after green looking
   like a product bug. Pad the fixture strings.

## Thread state at freeze

- **pk3 (workspace:40, kimi/opencode):** P1b green implementation
  mid-flight — uncommitted edits to `WebAuthnAuthenticator.swift` +
  `webauthn-smoke.sh` are THEIRS (ownership split recorded in the GAPS
  passkeys row, commit `b0e3ded135`); deliberately not committed by me.
  Their contract: envelope + key provider (gnome-keyring host / Secret
  portal flatpak), migration, honest fallback; ledger 16.
- **cmux desk (workspace:9):** holds the flatpak config-resolution row
  (`adce6eedc8`) — hias's approval for prefer-$HOME/.config-under-
  FLATPAK_ID was parked in their prompt box — and the #7939 two-part
  fix (row 41). P1b's settings flip is blocked on the former.
- **Adopted this evening, not yet in any repo doc:** the attribution
  contract of `~/olmo/WORKFLOW.md` §1 for cmux desks — all agent output
  marked `[loop-nudge:<agent>]` (mine `claude-passkey`, pk3
  `kimi-pk3`), pane-sends must be marked, nudge shape
  `✨ [loop-nudge:<agent>] HH:MM <msg>`. Candidate for a bullet in
  skills/cmux-feed once hias confirms it is contract, not convention.
- **Protocol refinements banked in skills/cmux-feed (`fab54f1013`):**
  doorbell needs an EMPTY input box; and (memory-only, not yet in the
  skill) an opencode pane's `esc interrupt` footer means ACTIVE turn
  even with a stable screen.

## Expensive-to-rederive conclusions already committed (pointers only)

WebKitGTK ships WebAuthn machinery but exposes none (P0, PROGRESS);
polyfill client + software authenticator is the only path; wire
protocol deliberately identical to macOS's bridge; signCount 0 and
attestation `none` are decisions, not omissions; port 8443 squatter,
session-restore surface ghosts, replaceItemAt-needs-destination,
manifest type-checker budget — all in PROGRESS 2026-09-01.

## Resume

`claude --resume 01DkBexMVHSdtcD34THJd437` (or `claude --continue` in
workspace:38 `passkey-cmux`). Mid-way through: awaiting pk3's green
push to review (their ring will be a marked nudge); no other work in
flight. Uncommitted-by-design: pk3's two files, see above.
