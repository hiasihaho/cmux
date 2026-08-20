#!/usr/bin/env bash
# Reproducible Flatpak build driver for the cmux Linux port. Every input a
# future automated harness needs is pinned HERE (and only here): runtime
# branch, SDK-extension branch, manifest path. The feature doc
# (docs/linux-port/features/15-flatpak-packaging.md) documents WHY each
# pin is what it is; this script is the executable half of that contract.
#
#   flatpak-build.sh deps      # install/refresh pinned runtimes (user scope)
#   flatpak-build.sh build     # flatpak-builder into linux/.flatpak-build/
#   flatpak-build.sh install   # build + install into the user installation
#   flatpak-build.sh run       # launch the installed flatpak
#   flatpak-build.sh verify    # smoke: binaries exist in the sandbox + CLI runs
#
# Exit: 0 ok, 1 step failed, 2 missing tooling.
set -euo pipefail

# ---- pinned inputs (the harness contract) --------------------------------
RUNTIME_BRANCH=49                 # org.gnome.Platform/Sdk branch
SWIFT_EXT=org.freedesktop.Sdk.Extension.swift6
SWIFT_EXT_BRANCH=25.08            # freedesktop base of GNOME 49
APP_ID=com.manaflow.cmux
# --------------------------------------------------------------------------

HERE="$(cd "$(dirname "$0")" && pwd)"
LINUX_DIR="$(dirname "$HERE")"
MANIFEST="$LINUX_DIR/flatpak/$APP_ID.yml"
BUILD_DIR="$LINUX_DIR/.flatpak-build/build"
STATE_DIR="$LINUX_DIR/.flatpak-build/state"

die() { echo "flatpak-build: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || { echo "missing: $1" >&2; exit 2; }; }
need flatpak; need flatpak-builder
[ -f "$MANIFEST" ] || die "no manifest at $MANIFEST"

cmd="${1:-build}"

deps() {
    flatpak install --user -y --noninteractive flathub \
        "org.gnome.Platform//$RUNTIME_BRANCH" \
        "org.gnome.Sdk//$RUNTIME_BRANCH" \
        "$SWIFT_EXT//$SWIFT_EXT_BRANCH"
}

build() {
    local extra=("$@")
    mkdir -p "$(dirname "$BUILD_DIR")"
    flatpak-builder --user --force-clean \
        --state-dir="$STATE_DIR" \
        "${extra[@]}" \
        "$BUILD_DIR" "$MANIFEST"
}

case "$cmd" in
    deps) deps ;;
    build) build ;;
    install) build --install ;;
    run)
        # Instance isolation is MANDATORY while the sandbox shares the
        # real home (--filesystem=home): an unisolated launch would
        # register the daily's GApplication id AND write the daily's
        # session store — and dirname(session)/scrollback is pruned on
        # every save (the 2026-07-22 trap). Own id, own session DIR, and
        # a socket in XDG_RUNTIME_DIR/app/<id>/ — the one sandbox path
        # the HOST can reach, so host-side CLI/agents can talk to it.
        mkdir -p "$HOME/.local/state/cmux-flatpak"
        flatpak run --user \
            --env=CMUX_APP_ID=com.manaflow.cmux.flatpak \
            --env=CMUX_SOCKET_PATH="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/app/$APP_ID/flatpak.sock" \
            --env=CMUX_SESSION_PATH="$HOME/.local/state/cmux-flatpak/session.json" \
            "$APP_ID" ;;
    verify)
        flatpak info --user "$APP_ID" >/dev/null || die "$APP_ID not installed"
        flatpak run --user --command=sh "$APP_ID" -c \
            'test -x /app/bin/cmux-adw && /app/bin/cmux --help >/dev/null 2>&1 && echo "verify: binaries ok"' \
            || die "verify failed"
        ;;
    *) die "unknown subcommand: $cmd" ;;
esac
