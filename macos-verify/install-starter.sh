#!/bin/sh
# Run ON the Mac. Installs a user-level starter for the macos-verify build:
#   ~/bin/cmux        symlink to the debug binary (survives rebuilds — the
#                     .build/debug path is SwiftPM's stable symlink)
#   ~/bin/cmux-build  rebuild helper: swift build --package-path <here>
# Ensures ~/bin is on PATH for login shells via ~/.zprofile.
set -eu
ROOT="$(cd "$(dirname "$0")" && pwd)"
BIN="$HOME/bin"

mkdir -p "$BIN"
ln -sfn "$ROOT/.build/debug/cmux" "$BIN/cmux"

cat > "$BIN/cmux-build" <<EOF
#!/bin/sh
exec swift build --package-path "$ROOT" "\$@"
EOF
chmod +x "$BIN/cmux-build"

if ! grep -qs 'HOME/bin' "$HOME/.zprofile" 2>/dev/null; then
    printf '\nexport PATH="$HOME/bin:$PATH"\n' >> "$HOME/.zprofile"
fi

echo "installed: $BIN/cmux -> $ROOT/.build/debug/cmux"
echo "installed: $BIN/cmux-build"
