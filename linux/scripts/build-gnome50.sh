#!/usr/bin/env bash
# Build cmux-adw against the GNOME 50 stack (GTK 4.22 / libadwaita 1.9) in a
# Fedora 44 podman container, without touching the host toolchain.
# Artifacts land in linux/.build-gnome50/.
set -euo pipefail

cd "$(dirname "$0")/.."

podman build -t cmux-gnome50-builder -f containers/gnome50.Containerfile containers

exec podman run --rm \
    --userns=keep-id \
    -v "$PWD:/src:Z" \
    -w /src \
    -e HOME=/tmp \
    -e CMUX_GNOME=50 \
    cmux-gnome50-builder \
    swift build --scratch-path .build-gnome50 "$@"
