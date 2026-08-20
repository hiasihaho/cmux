#!/usr/bin/env bash
# Installs a per-user .desktop entry for the Linux port. GNOME requires this
# for GNotification desktop notifications to be displayed, and it gives the
# app launcher presence.
set -euo pipefail

BINARY="${1:-$(cd "$(dirname "$0")/.." && pwd)/.build/debug/cmux-adw}"
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

update-desktop-database "$DIR" 2>/dev/null || true
echo "Installed $DIR/com.manaflow.cmux.desktop (Exec=$BINARY)"
