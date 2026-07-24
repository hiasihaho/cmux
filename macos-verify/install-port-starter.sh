#!/bin/sh
# Run ON the Mac. Creates /Applications/cmux-PORT.app — a Finder-clickable
# starter for the port-branch cmux build (POC-0003). Launches the Debug app
# from ~/cmux-derived with CMUX_TAG=port, so it gets its own socket
# (/tmp/cmux-debug-port.sock) and never collides with other tagged
# instances. The UI renders in software; terminal panes stay blank until
# the null renderer lands (no Metal in the VM) — everything else is real.
set -eu
APP=/Applications/cmux-PORT.app
BIN="$HOME/cmux-derived/Build/Products/Debug/cmux DEV.app/Contents/MacOS/cmux DEV"

[ -x "$BIN" ] || { echo "error: built app not found at $BIN — run build-app.sh first" >&2; exit 1; }

mkdir -p "$APP/Contents/MacOS"
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>cmux-PORT</string>
    <key>CFBundleDisplayName</key><string>cmux-PORT</string>
    <key>CFBundleExecutable</key><string>cmux-PORT</string>
    <key>CFBundleIdentifier</key><string>com.cmuxterm.port.starter</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
</dict>
</plist>
PLIST
cat > "$APP/Contents/MacOS/cmux-PORT" << SCRIPT
#!/bin/sh
exec env CMUX_TAG=port "$BIN"
SCRIPT
chmod +x "$APP/Contents/MacOS/cmux-PORT"
echo "installed: $APP (tag 'port', socket /tmp/cmux-debug-port.sock)"
