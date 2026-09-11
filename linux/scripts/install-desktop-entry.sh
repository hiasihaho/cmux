#!/usr/bin/env bash
# Installs a per-user .desktop entry for the Linux port. GNOME requires this
# for GNotification desktop notifications to be displayed, and it gives the
# app launcher presence.
set -euo pipefail

BINARY="${1:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/cmux-adw}"
START="$(cd "$(dirname "$0")" && pwd)/start.sh"
DIR="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$DIR"

cat > "$DIR/com.manaflow.cmux.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=cmux
Comment=Terminal for AI coding agents (Linux port)
Exec=$BINARY
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
StartupNotify=true
EOF

# A second launcher for the SAME productive daily line, but with browser
# passkeys/WebAuthn switched on (CMUX_WEBAUTHN=1 — the injected
# navigator.credentials + software authenticator, off by default). It goes
# through start.sh daily so the double-daily guard and backend selection
# still apply: it will refuse to start a second daily, so quit the normal
# `cmux` first, then launch this. One line, one at a time. Until the flag
# graduates to a cmux.json setting (pk3 lane), this is the click-to-dogfood
# path on the host daily.
cat > "$DIR/com.manaflow.cmux.pk.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=cmux_pk
Comment=cmux daily with browser passkeys enabled (CMUX_WEBAUTHN=1) — same productive line as cmux; quit cmux first, run one at a time
Exec=env CMUX_WEBAUTHN=1 $START daily
Icon=utilities-terminal
Terminal=false
Categories=System;TerminalEmulator;
StartupNotify=true
EOF

update-desktop-database "$DIR" 2>/dev/null || true
echo "Installed $DIR/com.manaflow.cmux.desktop (Exec=$BINARY)"
echo "Installed $DIR/com.manaflow.cmux.pk.desktop (Exec=env CMUX_WEBAUTHN=1 $START daily)"
