#!/usr/bin/env bash
# Runs as root INSIDE the Ubuntu 26.04 VM (vm.sh provision copies it there).
# Idempotent: re-running converges. Mirrors the adminvm devbox "minimal GNOME"
# shape (no Ubuntu desktop metapackage, no recommends, no snap), then adds the
# mobile path: gnome-remote-desktop headless sessions per user + the spike
# flatpak as that session's autostart app.
#
# Env: MOBILE_USERS (space-separated), HEADLESS_PASS, HEADLESS_PORT_BASE.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

MOBILE_USERS="${MOBILE_USERS:-mobile}"
HEADLESS_PASS="${HEADLESS_PASS:-mobile}"
HEADLESS_PORT_BASE="${HEADLESS_PORT_BASE:-3390}"
BUNDLE="${BUNDLE:-/tmp/mobile-spike.flatpak}"
APP_ID=com.manaflow.cmux.mobile
RUNTIME=org.gnome.Platform//49

log() { echo "[provision $(date +%H:%M:%S)] $*"; }

log "apt: minimal GNOME (devbox shape) + gnome-remote-desktop"
apt-get update -q
apt-get install -y -q --no-install-recommends \
    gdm3 gnome-shell gnome-session gnome-settings-daemon gnome-control-center \
    gnome-console nautilus xwayland dbus-user-session polkitd pkexec \
    fonts-ubuntu fonts-noto-color-emoji adwaita-icon-theme flatpak curl \
    gnome-remote-desktop openssl ca-certificates python3-gi
systemctl set-default graphical.target >/dev/null
systemctl enable gdm >/dev/null 2>&1 || true

log "versions: $(dpkg-query -W -f='${Package} ${Version}\n' gnome-shell gnome-remote-desktop | tr '\n' ' ')"
log "drm: $(ls /dev/dri 2>/dev/null | tr '\n' ' ')"

log "flatpak: flathub + $RUNTIME (system scope, shared by all users)"
flatpak remote-add --if-not-exists --system flathub https://dl.flathub.org/repo/flathub.flatpakrepo
RUNTIME_BUNDLE="${RUNTIME_BUNDLE:-/tmp/org.gnome.Platform-49.flatpak}"
if ! flatpak info --system "$RUNTIME" >/dev/null 2>&1; then
    if [ -f "$RUNTIME_BUNDLE" ]; then
        log "flatpak: runtime from host bundle $RUNTIME_BUNDLE (flathub is ≈230 KB/s from here)"
        flatpak install --system -y --noninteractive "$RUNTIME_BUNDLE" >/dev/null
    else
        log "flatpak: runtime from flathub (slow; vm.sh runtime ships a bundle instead)"
        flatpak install --system -y --noninteractive flathub "$RUNTIME" >/dev/null
    fi
fi
if [ -f "$BUNDLE" ]; then
    log "flatpak: install bundle $BUNDLE"
    flatpak install --system -y --noninteractive --reinstall "$BUNDLE" >/dev/null
else
    log "WARN: no bundle at $BUNDLE — spike not installed"
fi
flatpak info "$APP_ID" >/dev/null 2>&1 && log "flatpak: $APP_ID installed" || log "WARN: $APP_ID missing"

# scale pinning (see the script's docstring): mutter picks 100 % for small
# phones; this re-applies MOBILE_SCALE (default 2) on every monitor change.
install -Dm755 /tmp/cmux-mobile-scale.py /usr/local/bin/cmux-mobile-scale

HEADLESS_UNIT=/usr/lib/systemd/system/gnome-headless-session@.service
[ -f "$HEADLESS_UNIT" ] || HEADLESS_UNIT=/lib/systemd/system/gnome-headless-session@.service
if [ ! -f "$HEADLESS_UNIT" ]; then
    log "WARN: gnome-headless-session@.service not shipped by this gnome-remote-desktop — writing one"
    cat > /etc/systemd/system/gnome-headless-session@.service <<'EOF'
[Unit]
Description=GNOME headless session for %i
After=network.target
[Service]
Type=simple
User=%i
PAMName=login
Environment=XDG_SESSION_TYPE=wayland
Environment=XDG_SESSION_CLASS=user
ExecStart=/usr/bin/gnome-session --headless
Restart=on-failure
[Install]
WantedBy=graphical.target
EOF
    systemctl daemon-reload
fi

# Ubuntu packages GDM as gdm3 with its private bus under /run/gdm3 (root:root,
# drwx--x--x); the stock unit runs gdm-new-session as a DynamicUser in group gdm
# and dies with "The connection is closed" (verified 2026-11-05; as root it
# works). DEV-ONLY drop-in until the packaging agrees with itself.
mkdir -p /etc/systemd/system/gnome-headless-session@.service.d
# Restart=always: when the session ends (gnome-shell crash) gdm-new-session
# exits 0 and the stock Restart=on-failure leaves :339x dead.
printf '[Service]\nDynamicUser=no\nUser=root\nRestart=always\nRestartSec=3\n' > /etc/systemd/system/gnome-headless-session@.service.d/ubuntu-gdm3.conf
systemctl daemon-reload
# gdm must be up before gdm-new-session can ask it for a session
systemctl start gdm; sleep 3

i=0
for u in $MOBILE_USERS; do
    port=$((HEADLESS_PORT_BASE + i)); i=$((i + 1))
    log "user $u: headless RDP on :$port"
    id "$u" >/dev/null 2>&1 || useradd -m -s /bin/bash "$u"
    uid=$(id -u "$u")
    loginctl enable-linger "$u"
    # user manager must run for grdctl (dconf over the session bus) and systemctl --user
    for _ in 1 2 3 4 5; do [ -S "/run/user/$uid/bus" ] && break; sleep 1; done
    asuser() { sudo -u "$u" env XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" HOME="/home/$u" "$@"; }
    certdir="/home/$u/.local/share/gnome-remote-desktop/certificates"
    if [ ! -f "$certdir/rdp-tls.crt" ]; then
        asuser mkdir -p "$certdir"
        asuser openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$(hostname)-$u" \
            -keyout "$certdir/rdp-tls.key" -out "$certdir/rdp-tls.crt" 2>/dev/null
    fi
    asuser grdctl --headless rdp set-tls-key "$certdir/rdp-tls.key"
    asuser grdctl --headless rdp set-tls-cert "$certdir/rdp-tls.crt"
    asuser grdctl --headless rdp set-port "$port"
    asuser grdctl --headless rdp disable-port-negotiation 2>/dev/null || true
    asuser grdctl --headless rdp set-credentials "$u" "$HEADLESS_PASS"
    asuser grdctl --headless rdp enable
    # A headless session locks itself after the idle delay and the lock screen
    # looks like a GDM greeter from Guacamole ("user mobile to choose") — with
    # a password-less account nobody can unlock it (2026-11-05). No lock, no
    # idle, and a DEV-ONLY password as the fallback key.
    asuser gsettings set org.gnome.desktop.screensaver lock-enabled false
    asuser gsettings set org.gnome.desktop.session idle-delay 0
    asuser gsettings set org.gnome.desktop.lockdown disable-lock-screen true
    # Double-tap on a title bar (maximize) crashes mutter 50.1 over libei touch
    # (segfault in libmutter after "ei_touch_up: device is not emulating",
    # reproduced twice 2026-11-05). Take the gesture away; the spike starts
    # fullscreen anyway.
    asuser gsettings set org.gnome.desktop.wm.preferences action-double-click-titlebar none
    # Fractional scaling: without it mutter offers 200 % only when the
    # reported size halves to integers AND the logical area stays >= 640x480;
    # a phone reporting 1124x1857 (odd) got [1.0] only (2026-11-05).
    asuser gsettings set org.gnome.mutter experimental-features "['scale-monitor-framebuffer']"
    echo "$u:$HEADLESS_PASS" | chpasswd
    # the spike as the session's autostart app
    asuser mkdir -p "/home/$u/.config/autostart"
    asuser tee "/home/$u/.config/autostart/$APP_ID.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=cmux mobile spike
Exec=flatpak run $APP_ID
X-GNOME-Autostart-enabled=true
EOF
    asuser tee "/home/$u/.config/autostart/cmux-mobile-scale.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=cmux mobile scale pin
Exec=/usr/local/bin/cmux-mobile-scale
X-GNOME-Autostart-enabled=true
EOF
    asuser systemctl --user enable gnome-remote-desktop-headless.service >/dev/null 2>&1 || log "WARN: user unit gnome-remote-desktop-headless.service missing for $u"
    systemctl reset-failed "gnome-headless-session@$u.service" 2>/dev/null || true
    systemctl enable "gnome-headless-session@$u.service" >/dev/null 2>&1
    systemctl restart "gnome-headless-session@$u.service"   # picks up a new bundle / settings
    sleep 8
    systemctl is-active "gnome-headless-session@$u.service" >/dev/null && log "user $u: headless session active" || log "WARN: headless session for $u not active (journalctl -u gnome-headless-session@$u)"
done

log "listeners:"; ss -ltn | awk 'NR>1 {print "   " $4}' | grep -E ":(3389|339[0-9])" || log "WARN: no RDP listener yet"
log "done"
