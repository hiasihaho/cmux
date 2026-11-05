#!/usr/bin/env bash
# cmux mobile test VM — a reproducible Ubuntu 26.04 / GNOME 50 VM on the
# Fedora host (libvirt), provisioned to the adminvm "minimal GNOME" shape, with
# the mobile spike installed as a flatpak and one headless gnome-remote-desktop
# session per test user. Guacamole on the host points at those sessions.
#
#   vm.sh image            # fetch + verify the cloud image, upload to pool 'default'
#   vm.sh create           # overlay disk + cloud-init + virt-install, waits for ssh
#   vm.sh flatpak          # build linux/flatpak/com.manaflow.cmux.mobile.yml → bundle
#   vm.sh runtime          # export org.gnome.Platform//49 from the host as a bundle (flathub is slow)
#   vm.sh provision        # scp provision.sh + bundle, run as root (idempotent)
#   vm.sh guac             # Guacamole pod on the host (binds all interfaces)
#   vm.sh url              # current reachable Guacamole URL(s) — after an IP change
#   vm.sh ip | ssh [cmd] | start | stop | status | destroy
#   vm.sh all              # image → create → flatpak → provision → guac
#
# Everything version-shaped is pinned HERE or in the manifest. Passwords here
# are DEV-ONLY test values for a LAN-only VM; the Hetzner harness owns real ones.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$(dirname "$HERE")"

# ---- pinned inputs --------------------------------------------------------
NAME="${VM_NAME:-cmux-mobile-vm}"
POOL="${VM_POOL:-default}"
IMAGE_URL="${VM_IMAGE_URL:-https://cloud-images.ubuntu.com/resolute/current/resolute-server-cloudimg-amd64.img}"
IMAGE_CACHE="${VM_IMAGE_CACHE:-$HOME/.cache/cmux-mobile-vm}"
BASE_VOL="cmux-mobile-base-resolute.qcow2"
MEM="${VM_MEM:-4096}"
VCPUS="${VM_VCPUS:-4}"
DISK_GB="${VM_DISK_GB:-20}"
SSHKEY="${VM_SSHKEY:-$HOME/.ssh/adminvm_ed25519}"
ADMIN="${VM_ADMIN:-ubuntu}"                 # cloud-init sudo user (ssh key)
MOBILE_USERS="${MOBILE_USERS:-mobile}"      # space-separated; headless session each
HEADLESS_PASS="${HEADLESS_PASS:-mobile}"    # DEV-ONLY RDP password for all of them
HEADLESS_PORT_BASE="${HEADLESS_PORT_BASE:-3390}"   # user i listens on BASE+i
BUNDLE="$LINUX_DIR/.flatpak-build/mobile/mobile-spike.flatpak"
RUNTIME_BUNDLE="$IMAGE_CACHE/org.gnome.Platform-49.flatpak"   # exported from the host (vm.sh runtime)
# --------------------------------------------------------------------------

V() { virsh -c qemu:///system "$@"; }
die() { echo "vm.sh: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing tool: $1"; }

# The VM's address on libvirt's NAT is stable, but the DHCP lease TABLE is
# cleared when dnsmasq restarts (host network change / a VM pause-resume on a
# laptop that moved location — hias 2026-11-05). So: try the lease table, then
# the guest agent, then the host ARP cache keyed by the VM's own MAC.
vm_ip() {
    local ip mac
    # Each probe is wrapped so a failing virsh (e.g. guest agent not answering)
    # does not trip `set -e` and abort the whole script.
    ip="$( { V net-dhcp-leases default 2>/dev/null || true; } | awk -v h="$NAME" '$0 ~ h {print $5}' | cut -d/ -f1 | head -1)"
    [ -n "$ip" ] && { echo "$ip"; return; }
    ip="$( { V domifaddr "$NAME" --source agent 2>/dev/null || true; } | awk '/ipv4/ && $4 !~ /^127\./ {print $4}' | cut -d/ -f1 | head -1)"
    [ -n "$ip" ] && { echo "$ip"; return; }
    mac="$( { V domiflist "$NAME" 2>/dev/null || true; } | awk '/network/ {print $5; exit}')"
    [ -n "$mac" ] && { ip neigh show dev virbr0 2>/dev/null || true; } | awk -v m="$mac" 'tolower($0) ~ tolower(m) {print $1; exit}'
    return 0
}
ssh_vm() {
    local ip; ip="$(vm_ip)"; [ -n "$ip" ] || die "no DHCP lease for $NAME"
    ssh -i "$SSHKEY" -o BatchMode=yes -o ConnectTimeout=6 -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$IMAGE_CACHE/known_hosts" "$ADMIN@$ip" "$@"
}
scp_vm() {
    local ip; ip="$(vm_ip)"; [ -n "$ip" ] || die "no DHCP lease for $NAME"
    scp -q -i "$SSHKEY" -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$IMAGE_CACHE/known_hosts" "$@"
}

cmd_image() {
    need curl; need qemu-img
    mkdir -p "$IMAGE_CACHE"
    local img="$IMAGE_CACHE/$(basename "$IMAGE_URL")"
    if [ ! -f "$img" ]; then
        echo "== download $(basename "$IMAGE_URL")"
        curl -sS -L -o "$img.part" "$IMAGE_URL" && mv "$img.part" "$img"
        curl -sS -L -o "$IMAGE_CACHE/SHA256SUMS" "$(dirname "$IMAGE_URL")/SHA256SUMS"
        (cd "$IMAGE_CACHE" && grep "$(basename "$img")" SHA256SUMS | sha256sum -c -) || die "checksum mismatch"
    fi
    if ! V vol-info --pool "$POOL" "$BASE_VOL" >/dev/null 2>&1; then
        echo "== upload base image to pool $POOL as $BASE_VOL"
        local size; size=$(qemu-img info --output=json "$img" | python3 -c 'import sys,json; print(json.load(sys.stdin)["virtual-size"])')
        V vol-create-as "$POOL" "$BASE_VOL" "$size" --format qcow2 >/dev/null
        V vol-upload --pool "$POOL" "$BASE_VOL" "$img"
    fi
    echo "base image ready: $BASE_VOL"
}

cmd_create() {
    need virt-install
    [ -f "$SSHKEY.pub" ] || die "no ssh key at $SSHKEY.pub (set VM_SSHKEY)"
    V dominfo "$NAME" >/dev/null 2>&1 && die "$NAME exists — vm.sh destroy first"
    cmd_image >/dev/null
    mkdir -p "$IMAGE_CACHE"
    echo "== overlay disk ${DISK_GB}G backed by $BASE_VOL"
    V vol-create-as "$POOL" "$NAME.qcow2" "${DISK_GB}G" --format qcow2 \
        --backing-vol "$BASE_VOL" --backing-vol-format qcow2 >/dev/null
    local ud="$IMAGE_CACHE/$NAME-user-data.yaml"
    cat > "$ud" <<EOF
#cloud-config
hostname: $NAME
users:
  - name: $ADMIN
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    ssh_authorized_keys: [ "$(cat "$SSHKEY.pub")" ]
# the raw image lacks these; provision.sh needs them and the spec (devbox) notes it
packages: [ git, xz-utils ]
growpart: { mode: auto, devices: ["/"] }
EOF
    echo "== virt-install $NAME ($MEM MiB, $VCPUS vcpu, virtio-gpu)"
    virt-install --connect qemu:///system --name "$NAME" \
        --osinfo detect=on,require=off --memory "$MEM" --vcpus "$VCPUS" --cpu host-passthrough \
        --events on_reboot=restart \
        --disk "vol=$POOL/$NAME.qcow2,bus=virtio" \
        --network network=default,model=virtio --graphics spice --video virtio \
        --channel unix,target_type=virtio,name=org.qemu.guest_agent.0 \
        --cloud-init "user-data=$ud" --import --noautoconsole >/dev/null
    echo "== wait for ssh"
    local i ip=""
    for i in $(seq 1 60); do
        ip="$(vm_ip)"
        if [ -n "$ip" ] && ssh_vm true 2>/dev/null; then break; fi
        sleep 4
    done
    [ -n "$ip" ] && ssh_vm true 2>/dev/null || die "ssh never came up (virsh console $NAME)"
    echo "$NAME ready at $ip ($ADMIN@, key $SSHKEY)"
}

cmd_flatpak() {
    need flatpak-builder
    local out="$LINUX_DIR/.flatpak-build/mobile"
    mkdir -p "$out"
    echo "== flatpak-builder com.manaflow.cmux.mobile (log: $out/build.log)"
    # ostree refuses to write below min-free-space-percent (3 % of the volume,
    # 45 GB on a 1.5 TB disk) — a full-disk host then fails the EXPORT after a
    # complete build (2026-11-05). Local throwaway repo: no reserve.
    [ -d "$out/repo/objects" ] || ostree init --repo="$out/repo" --mode=archive
    ostree config --repo="$out/repo" set core.min-free-space-percent 0
    flatpak-builder --user --force-clean --disable-cache --state-dir="$out/state" \
        --repo="$out/repo" "$out/build" "$LINUX_DIR/flatpak/com.manaflow.cmux.mobile.yml" \
        > "$out/build.log" 2>&1 || die "build failed, see $out/build.log"
    flatpak build-bundle "$out/repo" "$BUNDLE" com.manaflow.cmux.mobile >> "$out/build.log" 2>&1
    ls -la "$BUNDLE"
}

# Flathub is slow from here (≈230 KB/s measured 2026-11-05, host and VM
# alike, while the Ubuntu archive does 9 MB/s). The host already has the
# runtime, so ship it as a bundle over virtio instead of downloading 1 GB.
cmd_runtime() {
    [ -f "$RUNTIME_BUNDLE" ] && { echo "runtime bundle ready: $RUNTIME_BUNDLE"; return; }
    local repo
    for repo in "$HOME/.local/share/flatpak/repo" /var/lib/flatpak/repo; do
        if [ -d "$repo/refs/heads/runtime/org.gnome.Platform/x86_64/49" ]; then
            echo "== export org.gnome.Platform//49 from $repo (≈1 GB, a minute)"
            flatpak build-bundle --runtime "$repo" "$RUNTIME_BUNDLE" org.gnome.Platform 49
            ls -la "$RUNTIME_BUNDLE"; return
        fi
    done
    echo "no org.gnome.Platform//49 in a host flatpak repo — provision will download it from flathub" >&2
}

cmd_provision() {
    [ -f "$BUNDLE" ] || die "no bundle at $BUNDLE — vm.sh flatpak first"
    local ip; ip="$(vm_ip)"
    echo "== copy provision.sh + bundle(s) to $ip"
    scp_vm "$HERE/provision.sh" "$HERE/cmux-mobile-scale.py" "$BUNDLE" "$ADMIN@$ip:/tmp/"
    [ -f "$RUNTIME_BUNDLE" ] && scp_vm "$RUNTIME_BUNDLE" "$ADMIN@$ip:/tmp/"
    echo "== run provision.sh (root, idempotent; log also in /var/log/cmux-mobile-provision.log)"
    ssh_vm "sudo env MOBILE_USERS='$MOBILE_USERS' HEADLESS_PASS='$HEADLESS_PASS' HEADLESS_PORT_BASE='$HEADLESS_PORT_BASE' bash /tmp/provision.sh 2>&1 | tee -a /var/log/cmux-mobile-provision.log"
}

cmd_guac() {
    local ip; ip="$(vm_ip)"; [ -n "$ip" ] || die "no DHCP lease for $NAME"
    VM_IP="$ip" MOBILE_USERS="$MOBILE_USERS" HEADLESS_PASS="$HEADLESS_PASS" \
        HEADLESS_PORT_BASE="$HEADLESS_PORT_BASE" bash "$HERE/guac.sh"
}

# Current reachable Guacamole URL(s) — the pod binds all interfaces, so this
# just reads the host's live global IPs (no restart on an IP change).
cmd_url() {
    local port="${GUAC_PORT:-8080}"
    ip -4 -o addr show scope global | awk '!/virbr|podman|docker|lxd/ {sub(/\/.*/,"",$4); print "http://" $4 ":'"$port"'/guacamole"}'
}

cmd_status() {
    V dominfo "$NAME" 2>/dev/null | grep -E "^(Name|State|CPU\(s\)|Max memory)" || echo "$NAME: not defined"
    echo "ip: $(vm_ip)"
    echo "guac url(s):"; cmd_url | sed 's/^/  /'
    [ -f "$BUNDLE" ] && echo "bundle: $BUNDLE ($(du -h "$BUNDLE" | cut -f1))" || echo "bundle: none"
    podman pod ps --filter name=cmux-mobile-guac --format '{{.Name}}: {{.Status}}' 2>/dev/null
}

cmd_destroy() {
    V destroy "$NAME" >/dev/null 2>&1 || true
    V undefine "$NAME" --remove-all-storage >/dev/null 2>&1 || true
    sed -i "/$(vm_ip | sed 's/\./\\./g')/d" "$IMAGE_CACHE/known_hosts" 2>/dev/null || true
    echo "$NAME destroyed (base image kept)"
}

case "${1:-}" in
    image)     cmd_image ;;
    create)    cmd_create ;;
    flatpak)   cmd_flatpak ;;
    runtime)   cmd_runtime ;;
    provision) cmd_provision ;;
    guac)      cmd_guac ;;
    url)       cmd_url ;;
    ip)        vm_ip ;;
    ssh)       shift; ssh_vm "$@" ;;
    start)     V start "$NAME" ;;
    stop)      V shutdown "$NAME" ;;
    status)    cmd_status ;;
    destroy)   cmd_destroy ;;
    all)       cmd_image; cmd_create; [ -f "$BUNDLE" ] || cmd_flatpak; cmd_runtime || true; cmd_provision; cmd_guac ;;
    *)         sed -n 2,16p "$0"; exit 2 ;;
esac
