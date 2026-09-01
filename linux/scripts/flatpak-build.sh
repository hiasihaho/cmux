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
# Extra args after build/install go to flatpak-builder verbatim. TRAP
# (2026-08-20): the `type: dir` app module can be served from the
# state-dir MODULE CACHE even with --force-clean — an edit-rebuild-test
# loop then tests a stale binary. Pass --disable-cache when app sources
# changed, and after installing VERIFY the change reached /app/bin
# (grep a new symbol/string) before trusting any probe result.
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

# Stamp the build so the shipped artifact can say what it is. The manifest
# installs this next to the binary; the app serves it as `system.build`.
# Written here because the source copy skips .git on purpose.
stamp_build_info() {
    local out="$LINUX_DIR/flatpak/build-info.json"
    python3 - "$out" "$(git -C "$LINUX_DIR/.." rev-parse HEAD 2>/dev/null || echo unknown)" \
        "$(git -C "$LINUX_DIR/.." rev-parse --short HEAD 2>/dev/null || echo unknown)" \
        "$(git -C "$LINUX_DIR/../ghostty" rev-parse --short HEAD 2>/dev/null || echo unknown)" \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(git -C "$LINUX_DIR/.." status --porcelain 2>/dev/null | grep -vc '^??' || echo 0)" <<'PYEOF'
import json, sys
out, sha, short, ghostty, built, dirty = sys.argv[1:7]
# A stamp that hides uncommitted work is worse than none: it names a commit
# the binary does not actually contain.
modified = int(dirty or 0)
json.dump({
    "build": short + ("+dirty" if modified else ""),
    "git_sha": sha,
    "ghostty_sha": ghostty,
    "built_at": built,
    "uncommitted_files": modified,
    "flavor": "flatpak",
}, open(out, "w"), indent=1)
print("  build stamp: %s%s (ghostty %s) at %s" % (
    short, " +%d uncommitted" % modified if modified else "", ghostty, built))
PYEOF
}

build() {
    local extra=("$@")
    stamp_build_info
    mkdir -p "$(dirname "$BUILD_DIR")"
    flatpak-builder --user --force-clean \
        --state-dir="$STATE_DIR" \
        "${extra[@]}" \
        "$BUILD_DIR" "$MANIFEST"
}

case "$cmd" in
    deps) deps ;;
    deps-cache)
        # Refresh the local SwiftPM bare-repo mirrors the manifest's
        # set-mirror loop builds from. Source of truth: the host
        # .build/repositories a normal `swift build` maintains. Cuts the
        # build's dependency on aparoksha.dev uptime. Each mirror dir is
        # named EXACTLY like the upstream repo (URL basename minus .git):
        # SwiftPM derives package identity from the mirror URL basename,
        # so fingerprint-suffixed names corrupt identities and resolution
        # fails with nonsense tools-version errors (2026-08-20).
        [ -d "$LINUX_DIR/.build/repositories" ] || die "run a host swift build first"
        CACHE="$LINUX_DIR/.flatpak-deps-cache/repositories"
        rm -rf "$CACHE"; mkdir -p "$CACHE"
        for r in "$LINUX_DIR"/.build/repositories/*/; do
            url=$(git -C "$r" config remote.origin.url 2>/dev/null) || continue
            base=$(basename "$url" .git)
            cp -a "$r" "$CACHE/$base"
        done
        ls "$CACHE"; du -sh "$LINUX_DIR/.flatpak-deps-cache" ;;
    build) build "${@:2}" ;;
    install) build --install "${@:2}" ;;
    run)
        # Since round 2 the app's own in-flatpak defaults are safe
        # (socket in XDG_RUNTIME_DIR/app/<id>/, session in its own
        # cmux-flatpak dir). Only the GApplication id still needs an
        # override on a host that also runs the daily cmux-adw — same
        # session bus, same default id.
        echo "socket: ${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/app/$APP_ID/cmux.sock"
        # flatpak run FORWARDS the caller's ambient environment into the
        # sandbox — launched from a cmux pane, the app would inherit that
        # pane's CMUX_* identity (socket path included) and bind its
        # socket on a private tmpfs path. Scrub first, same reason the
        # test suites' cx() scrubs.
        env -u CMUX_SOCKET_PATH -u CMUX_SOCKET_PASSWORD \
            -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID \
            -u CMUX_TAB_ID -u CMUX_PANEL_ID -u CMUX_SESSION_PATH \
            flatpak run --user \
            --env=CMUX_APP_ID=com.manaflow.cmux.flatpak \
            "$APP_ID" ;;
    verify)
        flatpak info --user "$APP_ID" >/dev/null || die "$APP_ID not installed"
        flatpak run --user --command=sh "$APP_ID" -c \
            'test -x /app/bin/cmux-adw && /app/bin/cmux --help >/dev/null 2>&1 && echo "verify: binaries ok"' \
            || die "verify failed"
        ;;
    *) die "unknown subcommand: $cmd" ;;
esac
