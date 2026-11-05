#!/usr/bin/env bash
# Native cmux-adw build INSIDE the test VM (no flatpak) for fast mobile-mode
# iteration. The VM is a real GNOME 50 compositor (mutter), so fullscreen,
# touch and the headless RDP path behave for real — much faster to iterate
# than rebuilding a flatpak each change. Flatpak packaging stays a separate,
# final step.
#
#   dev-build.sh setup   # one-time: toolchain + build dirs readable by the session user
#   dev-build.sh sync    # rsync the worktree's linux/ to the VM (minus build dirs)
#   dev-build.sh build   # swift build --product cmux-adw in the VM (VTE, no ghostty)
#   dev-build.sh run     # (re)launch native cmux-adw in the mobile headless session
#   dev-build.sh iter    # sync + build + run
#   dev-build.sh logs    # tail the app's stderr
#
# Model: build as `ubuntu` (owns the swiftly toolchain) into a world-readable
# /var/tmp dir; run as the session user `mobile` with LD_LIBRARY_PATH pointing
# at the (readable) Swift runtime. Reuses the mobile headless session, its
# Guacamole connection, scaling and menu-hint from the main harness.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$(dirname "$HERE")"
SSHKEY="${VM_SSHKEY:-$HOME/.ssh/adminvm_ed25519}"
KNOWN="${HOME}/.cache/cmux-mobile-vm/known_hosts"
ADMIN=ubuntu
SESSION_USER="${MOBILE_USER:-mobile}"
# Pin the SAME Swift the project is validated against (host = 6.2). The newer
# 6.4.x rejects the codebase's GConnectFlags(0) OptionSet init (wants
# rawValue:), so build with 6.2, not swiftly's latest.
SWIFT_TOOLCHAIN_VERSION="${SWIFT_TOOLCHAIN_VERSION:-6.2}"
TOOLCHAIN="/home/ubuntu/.local/share/swiftly/toolchains/$SWIFT_TOOLCHAIN_VERSION"
SWIFT="$TOOLCHAIN/usr/bin/swift"
SWIFT_RT="$TOOLCHAIN/usr/lib/swift/linux"
# swift.org ships no Ubuntu-26.04 build for 6.3.x, so we run the 24.04 toolchain
# on 26.04. Its tools (and the binaries it produces) need 24.04's libxml2.so.2
# and libicu*.so.74, which 26.04 replaced with newer sonames. We stage those few
# .so files here (see `setup`) and put the dir on the library path for build+run.
COMPAT=/opt/swift-compat
SRC=/var/tmp/cmux-linux            # synced source (ubuntu-owned, a+rX)
APP_ID=com.manaflow.cmux.mobiledev

die() { echo "dev-build: $*" >&2; exit 1; }
VM_IP() { "$HERE/vm.sh" ip; }
ssh_vm() {
    local ip; ip="$(VM_IP)"; [ -n "$ip" ] || die "no VM ip"
    ssh -i "$SSHKEY" -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN" "$ADMIN@$ip" "$@"
}

cmd_setup() {
    [ -x "$SWIFT" ] || { ssh_vm "test -x $SWIFT" || die "Swift toolchain missing at $SWIFT (install swiftly first)"; }
    echo "== stage 24.04 compat libs (libxml2.so.2, libicu*.so.74) for the 6.3.x toolchain on 26.04"
    ssh_vm 'test -e /opt/swift-compat/libxml2.so.2 && test -e /opt/swift-compat/libicuuc.so.74 || (
        set -e; cd /tmp
        curl -fsSL -o /tmp/libxml2.deb "http://archive.ubuntu.com/ubuntu/pool/main/libx/libxml2/libxml2_2.9.14+dfsg-1.3ubuntu3_amd64.deb"
        curl -fsSL -o /tmp/icu.deb "http://archive.ubuntu.com/ubuntu/pool/main/i/icu/libicu74_74.2-1ubuntu3_amd64.deb"
        dpkg-deb -x /tmp/libxml2.deb /tmp/xc; dpkg-deb -x /tmp/icu.deb /tmp/xc
        sudo mkdir -p /opt/swift-compat
        sudo cp -a /tmp/xc/usr/lib/x86_64-linux-gnu/libxml2.so.2* /tmp/xc/usr/lib/x86_64-linux-gnu/libicu*.so.74* /opt/swift-compat/
        sudo chmod -R a+rX /opt/swift-compat; rm -rf /tmp/xc /tmp/libxml2.deb /tmp/icu.deb
    )'
    echo "== make the Swift runtime readable by the session user"
    # The native binary loads the Swift runtime from ubuntu's toolchain; the
    # session user must be able to traverse to it. Throwaway dev VM only.
    # The session user loads the Swift runtime from ubuntu's toolchain, so every
    # directory from /home/ubuntu down to the runtime must be traversable, and
    # the runtime readable. Throwaway dev VM only.
    ssh_vm "chmod a+x /home/ubuntu ~/.local ~/.local/share ~/.local/share/swiftly ~/.local/share/swiftly/toolchains && chmod -R a+rX '$TOOLCHAIN/usr' && sudo mkdir -p $SRC && sudo chown $ADMIN:$ADMIN $SRC"
    echo "setup ok"
}

cmd_sync() {
    local ip; ip="$(VM_IP)"; [ -n "$ip" ] || die "no VM ip"
    local repo; repo="$(dirname "$LINUX_DIR")"
    local rsh="ssh -i $SSHKEY -o BatchMode=yes -o UserKnownHostsFile=$KNOWN"
    echo "== rsync linux/ → $ip:$SRC"
    rsync -az --delete \
        --exclude '.build' --exclude '.build-gnome50' --exclude '.flatpak-build' \
        --exclude '.flatpak-deps-cache' --exclude '.swiftpm' --exclude 'tests' \
        --exclude 'poc/*/.build' \
        -e "$rsh" "$LINUX_DIR/" "$ADMIN@$ip:$SRC/"
    # linux/Package.swift references ../Packages/macOS/* (CmuxFoundation etc.);
    # mirror the repo's Packages/ at the sibling path the relative deps expect.
    echo "== rsync Packages/ → $ip:/var/tmp/Packages"
    ssh_vm "mkdir -p /var/tmp/Packages"
    rsync -az --delete --exclude '.build' --exclude '.swiftpm' \
        -e "$rsh" "$repo/Packages/" "$ADMIN@$ip:/var/tmp/Packages/"
    # CmuxCLI's sources are symlinks into the repo root (../../../Sources, CLI);
    # they break on the VM. Dereference them (-L) into real files so the `cmux`
    # product's target is not empty (we build cmux-adw, but SwiftPM validates
    # the whole manifest). Only ~3 MB.
    echo "== rsync -L Sources/CmuxCLI (dereference symlinks)"
    rsync -aL --delete -e "$rsh" \
        "$LINUX_DIR/Sources/CmuxCLI/" "$ADMIN@$ip:$SRC/Sources/CmuxCLI/"
    ubuntu_compat
    ssh_vm "chmod -R a+rX $SRC /var/tmp/Packages"
}

# Ubuntu's GObject/GTK headers import some C types more strictly than Fedora's,
# so a few constructs the codebase uses on Fedora do not compile as-is on the
# VM. We rewrite them on the SYNCED COPY only (the committed source stays on the
# Fedora convention) until these are fixed upstream for the Ubuntu/Hetzner
# target. Each entry is a discovered, mechanical portability delta.
ubuntu_compat() {
    echo "== apply Ubuntu-compat transforms to the synced copy"
    ssh_vm "cd $SRC && find Sources Package.swift /var/tmp/Packages -name '*.swift' -print0 2>/dev/null | xargs -0 sed -i \
        -e 's/GConnectFlags(0)/GConnectFlags(rawValue: 0)/g' \
        -e 's/VTE_PTY_DEFAULT/VtePtyFlags(rawValue: 0)/g' \
        -e 's/G_SPAWN_DEFAULT/GSpawnFlags(rawValue: 0)/g' \
        -e 's/GTK_ORIENTATION_HORIZONTAL/GtkOrientation(rawValue: 0)/g' \
        -e 's/GTK_ORIENTATION_VERTICAL/GtkOrientation(rawValue: 1)/g' \
        -e 's/GTK_ALIGN_FILL/GtkAlign(rawValue: 0)/g' \
        -e 's/GTK_ALIGN_START/GtkAlign(rawValue: 1)/g' \
        -e 's/GTK_ALIGN_END/GtkAlign(rawValue: 2)/g' \
        -e 's/GTK_ALIGN_CENTER/GtkAlign(rawValue: 3)/g' \
        -e 's/GTK_POS_BOTTOM/GtkPositionType(rawValue: 3)/g' \
    "
}

cmd_build() {
    echo "== swift build --product cmux-adw (VTE, no ghostty) on the VM"
    # No CMUX_GHOSTTY → the package uses VTE terminals (ghostty shim is a
    # later concern). The toolchain path carries its own runtime.
    ssh_vm "cd $SRC && LD_LIBRARY_PATH=$COMPAT $SWIFT build --product cmux-adw > /tmp/cmux-build.log 2>&1; rc=\$?; chmod -R a+rX $SRC/.build 2>/dev/null; if [ \$rc = 0 ]; then tail -1 /tmp/cmux-build.log; else echo '--- errors ---'; grep -E 'error:' /tmp/cmux-build.log | sed 's|/var/tmp/cmux-linux/||' | sort -u | head -30; fi; exit \$rc"
}

cmd_run() {
    local bin="$SRC/.build/debug/cmux-adw"
    ssh_vm "test -x $bin" || die "no binary at $bin — run build first"
    echo "== (re)launch native cmux-adw in $SESSION_USER's headless session"
    # Kill whatever the session runs now (spike flatpak or a previous native
    # build), then launch the native binary into the live Wayland session with
    # isolated ids and the Swift runtime on the library path.
    ssh_vm "sudo bash -c '
        uid=\$(id -u $SESSION_USER)
        run() { sudo -u $SESSION_USER env XDG_RUNTIME_DIR=/run/user/\$uid DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/\$uid/bus HOME=/home/$SESSION_USER \"\$@\"; }
        run flatpak kill com.manaflow.cmux.mobile 2>/dev/null || true
        run systemctl --user stop cmux-adw-dev.service 2>/dev/null || true
        run systemctl --user reset-failed cmux-adw-dev.service 2>/dev/null || true
        pkill -u $SESSION_USER -x cmux-adw 2>/dev/null || true
        sleep 1
        run systemd-run --user --collect --quiet --unit=cmux-adw-dev --setenv=WAYLAND_DISPLAY=wayland-0 --setenv=LD_LIBRARY_PATH=$SWIFT_RT:$COMPAT --setenv=CMUX_APP_ID=$APP_ID --setenv=CMUX_SOCKET_PATH=/run/user/\$uid/cmux-dev.sock --setenv=CMUX_SESSION_PATH=/home/$SESSION_USER/.local/state/cmux-dev-session.json --setenv=CMUX_DEBUG_UI=1 $bin
    '"
    sleep 3
    ssh_vm "pgrep -u $SESSION_USER -x cmux-adw >/dev/null && echo 'cmux-adw running in the session' || echo 'WARN: cmux-adw not running — dev-build.sh logs'"
}

cmd_logs() {
    ssh_vm "sudo -u $SESSION_USER journalctl --user -u cmux-adw-dev -n 40 --no-pager 2>/dev/null || true"
}

case "${1:-}" in
    setup) cmd_setup ;;
    sync)  cmd_sync ;;
    build) cmd_build ;;
    run)   cmd_run ;;
    iter)  cmd_sync; cmd_build; cmd_run ;;
    logs)  cmd_logs ;;
    *)     sed -n '2,16p' "$0"; exit 2 ;;
esac
