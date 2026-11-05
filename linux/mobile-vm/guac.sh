#!/usr/bin/env bash
# Guacamole on the HOST for the mobile test VM: guacd + guacamole in a rootless
# podman pod, file auth, one RDP connection per MOBILE_USER straight into that
# user's headless gnome-remote-desktop session (no GDM), enable-touch on, and
# the menu-hint extension (☰ tab that opens the Guacamole menu — phones have
# no Ctrl+Alt+Shift and the edge swipe fights Android's back gesture).
#
#   VM_IP=<vm ip> bash guac.sh          # vm.sh guac fills the env
#   phone (same WLAN): http://<LAN_IP>:8080/guacamole   login poc / poc
#
# LAN-bound and poc/poc-gated: a DEV-ONLY test surface, take it down after.
# Tear down: podman pod rm -f cmux-mobile-guac
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
VM_IP="${VM_IP:?VM_IP required}"
MOBILE_USERS="${MOBILE_USERS:-mobile}"
HEADLESS_PASS="${HEADLESS_PASS:-mobile}"
HEADLESS_PORT_BASE="${HEADLESS_PORT_BASE:-3390}"
TAG="${GUAC_TAG:-1.6.0}"
PORT="${GUAC_PORT:-8080}"
BIND_IP="${BIND_IP:-$(ip -4 -o addr show scope global | awk '!/virbr|podman|docker|lxd/ {sub(/\/.*/,"",$4); print $4; exit}')}"
POD=cmux-mobile-guac
HOME_DIR="${GUAC_HOME_DIR:-$HOME/.cache/cmux-mobile-vm/guac-home}"

podman pod rm -f "$POD" >/dev/null 2>&1 || true   # our own previous run must not trip the port check
if ss -ltn "( sport = :${PORT} )" | grep -q ":${PORT} "; then
    echo "port ${PORT} busy (GUAC_PORT=<n> to move):" >&2; ss -ltnp "( sport = :${PORT} )" >&2; exit 1
fi
firewall-cmd --query-port="${PORT}/tcp" >/dev/null 2>&1 || \
    echo "warning: firewalld does not allow ${PORT}/tcp — phone needs: sudo firewall-cmd --add-port=${PORT}/tcp" >&2

mkdir -p "$HOME_DIR/extensions"
( cd "$HERE/menu-hint" && python3 - "$HOME_DIR/extensions/menu-hint.jar" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], 'w', zipfile.ZIP_DEFLATED) as z:
    for f in ['guac-manifest.json', 'html/menu-button.html', 'css/menu-button.css']:
        z.write(f, f)
PY
)
chmod 755 "$HOME_DIR/extensions"; chmod 644 "$HOME_DIR/extensions/menu-hint.jar"

cat > "$HOME_DIR/guacamole.properties" <<EOF
guacd-hostname: 127.0.0.1
guacd-port: 4822
EOF
{
    echo '<user-mapping>'
    echo '    <authorize username="poc" password="poc">'
    i=0
    for u in $MOBILE_USERS; do
        port=$((HEADLESS_PORT_BASE + i)); i=$((i + 1))
        cat <<EOF
        <connection name="$u (cmux mobile, touch)">
            <protocol>rdp</protocol>
            <param name="hostname">${VM_IP}</param>
            <param name="port">${port}</param>
            <param name="username">${u}</param>
            <param name="password">${HEADLESS_PASS}</param>
            <param name="security">any</param>
            <param name="ignore-cert">true</param>
            <param name="resize-method">display-update</param>
            <param name="enable-touch">true</param>
            <param name="enable-wallpaper">false</param>
            <param name="enable-theming">false</param>
            <param name="enable-menu-animations">false</param>
        </connection>
        <!-- mouse-emulation twin: the same session without RDPEI, for when
             the touch path misbehaves (GNOME 50.1 mutter segfault on a
             touch-up via libei, 2026-11-05) -->
        <connection name="$u (cmux mobile, mouse)">
            <protocol>rdp</protocol>
            <param name="hostname">${VM_IP}</param>
            <param name="port">${port}</param>
            <param name="username">${u}</param>
            <param name="password">${HEADLESS_PASS}</param>
            <param name="security">any</param>
            <param name="ignore-cert">true</param>
            <param name="resize-method">display-update</param>
            <param name="enable-wallpaper">false</param>
            <param name="enable-theming">false</param>
            <param name="enable-menu-animations">false</param>
        </connection>
EOF
    done
    echo '    </authorize>'
    echo '</user-mapping>'
} > "$HOME_DIR/user-mapping.xml"
chmod 644 "$HOME_DIR/user-mapping.xml"   # Tomcat user inside the container must read it

podman pod rm -f "$POD" >/dev/null 2>&1 || true
podman pod create --name "$POD" -p "${BIND_IP}:${PORT}:8080" >/dev/null
podman run -d --pod "$POD" --name "$POD-guacd" -e GUACD_LOG_LEVEL=info \
    docker.io/guacamole/guacd:${TAG} >/dev/null
podman run -d --pod "$POD" --name "$POD-web" \
    -e GUACAMOLE_HOME=/etc/guacamole -e GUACD_HOSTNAME=127.0.0.1 -e GUACD_PORT=4822 \
    -v "$HOME_DIR":/etc/guacamole:Z docker.io/guacamole/guacamole:${TAG} >/dev/null

echo "Guacamole up (give it ~15 s): http://${BIND_IP}:${PORT}/guacamole   login poc / poc"
echo "Connections: $(for u in $MOBILE_USERS; do printf '%s ' "$u"; done)→ $VM_IP headless sessions"
echo "Logs: podman logs -f $POD-guacd | podman logs -f $POD-web    Stop: podman pod rm -f $POD"
